## One-way macOS appearance sync for a Windows 11 Parallels VM.
import std/[monotimes, os, osproc, streams, strutils, tempfiles, times]
import posix

{.passL: "-framework CoreFoundation".}

const
  label = "local.parallels-theme-sync"
  launchctl = "/bin/launchctl"
  managedMarker = "<!-- Managed by parallels-theme-sync -->"
  usage = """Usage:
  parallels-theme-sync --sync <VM name or UUID>
  parallels-theme-sync --install <VM name or UUID>
  parallels-theme-sync --help

--sync    Apply the current Mac appearance to a logged-in Windows desktop.
--install Start automatic sync for the current macOS user and at future logins.
Exit codes: 0 success, 1 error, 2 invalid arguments, 3 guest unavailable."""
  reconcileSeconds = 60
  appearancePollMs = 500
  fastRetryMs = 500
  fastRetryWindowMs = 12_000
  pausedRetryMs = 1000
  idleRetryMs = 2500
  commandTimeoutMs = 15_000
  guestScript = staticRead("windows-theme.ps1")
  # An uncompressed UTF-16 EncodedCommand exceeds the Parallels guest argument
  # limit. Keep the script readable and pack it into one short ASCII argument.
  packedGuest = staticExec("set -o pipefail; /usr/bin/gzip -nc | /usr/bin/base64", guestScript).strip()

static:
  doAssert packedGuest.len > 0, "Could not pack the Windows theme script"

type
  SyncState = enum matched, applied, paused, unavailable
  SyncResult = tuple[message: string, state: SyncState]

let anyApplication {.importc: "kCFPreferencesAnyApplication".}: pointer
let currentUser {.importc: "kCFPreferencesCurrentUser".}: pointer
let anyHost {.importc: "kCFPreferencesAnyHost".}: pointer
proc CFStringCreateWithCString(allocator: pointer; text: cstring; encoding: uint32): pointer {.importc.}
proc CFRelease(value: pointer) {.importc.}
proc CFEqual(first, second: pointer): uint8 {.importc.}
proc CFPreferencesSynchronize(application, user, host: pointer): uint8 {.importc.}
proc CFPreferencesCopyValue(key, application, user, host: pointer): pointer {.importc.}
proc flock(fd, operation: cint): cint {.importc, header: "<sys/file.h>".}
var LOCK_EX {.importc, header: "<sys/file.h>".}: cint
var LOCK_NB {.importc, header: "<sys/file.h>".}: cint
var O_NOFOLLOW {.importc, header: "<fcntl.h>".}: cint

proc run(program: string; args: openArray[string]): tuple[code: int, output: string] =
  let process = startProcess(program, args = args, options = {poStdErrToStdOut})
  defer: process.close()
  let code = process.waitForExit(commandTimeoutMs)
  if code == -1:
    process.kill()
    discard process.waitForExit()
    raise newException(IOError, program & " timed out")
  (code, process.outputStream.readAll().strip())

proc checked(program: string; args: openArray[string]): string =
  let response = run(program, args)
  if response.code != 0:
    raise newException(IOError, program & " failed: " & response.output)
  response.output

proc findPrlctl(): string =
  # The Parallels wrapper selects the tool by the name used to invoke it.
  let fromPath = findExe("prlctl", followSymlinks = false)
  if fromPath.len > 0: return absolutePath(fromPath)
  for path in ["/usr/local/bin/prlctl", "/Applications/Parallels Desktop.app/Contents/MacOS/prlctl"]:
    if access(path.cstring, X_OK) == 0: return path
  raise newException(IOError, "prlctl was not found. Install a Parallels Desktop edition with CLI support.")

proc macAppearance(key, dark: pointer): string =
  if CFPreferencesSynchronize(anyApplication, currentUser, anyHost) == 0:
    raise newException(IOError, "Cannot refresh the macOS appearance preference")
  let value = CFPreferencesCopyValue(key, anyApplication, currentUser, anyHost)
  if value == nil: return "Light"
  defer: CFRelease(value)
  if CFEqual(value, dark) != 0: "Dark" else: "Light"

proc terminalText(output: string): string =
  # Parallels' advanced terminal wraps stdout in cursor/formatting (CSI)
  # and window title (OSC) sequences, including on command failures.
  var i = 0
  while i < output.len:
    if output.continuesWith("\e[", i):
      i += 2
      while i < output.len and output[i] notin {'@'..'~'}: inc i
      inc i
    elif output.continuesWith("\e]", i):
      i += 2
      while i < output.len and output[i] != '\a' and not output.continuesWith("\e\\", i):
        inc i
      i += (if output.continuesWith("\e\\", i): 2 else: 1)
    else:
      result.add(output[i])
      inc i
  result = result.strip()

proc syncTheme(prlctl, vm, appearance: string): SyncResult =
  let status = checked(prlctl, ["list", "-a", "-H", "-o", "status", vm])
  if status != "running":
    return ("skipped: " & vm & " state is " & status, if status == "paused": paused else: unavailable)
  let command = "$appearance='" & appearance &
    "'; $stream=[IO.MemoryStream]::new([Convert]::FromBase64String('" & packedGuest &
    "')); $gzip=[IO.Compression.GZipStream]::new($stream,[IO.Compression.CompressionMode]::Decompress);" &
    " & ([ScriptBlock]::Create([IO.StreamReader]::new($gzip).ReadToEnd()))"
  let response = run(prlctl, ["exec", vm, "--current-user", "--use-advanced-terminal",
    "powershell.exe", "-NoProfile", "-NonInteractive", "-STA", "-OutputFormat", "Text",
    "-Command", command])
  let reply = terminalText(response.output)
  if response.code != 0:
    raise newException(IOError, "Windows theme command failed (" & $response.code & "): " & reply)
  let outcome =
    if reply.startsWith("applied: "): applied
    elif reply.startsWith("matched: "): matched
    elif reply.startsWith("skipped: "): unavailable
    else: raise newException(IOError, "Unexpected Windows response: " & reply)
  ("macOS " & appearance & " -> " & reply, outcome)

proc log(message: string) =
  discard run("/usr/bin/logger", ["-t", label, message])

proc watch(prlctl, vm: string; key, dark: pointer) =
  var previousAppearance = ""
  var state = matched
  var pendingSince = getMonoTime()
  var nextAttempt = pendingSince
  var lastDiagnostic = ""
  while true:
    let now = getMonoTime()
    var diagnostic = ""
    try:
      let appearance = macAppearance(key, dark)
      if appearance != previousAppearance:
        previousAppearance = appearance
        nextAttempt = now
        state = matched
      if now < nextAttempt:
        sleep(appearancePollMs)
        continue
      if state in {matched, applied}: pendingSince = now
      let result = syncTheme(prlctl, vm, appearance)
      state = result.state
      if state == applied: log(result.message)
      if state in {paused, unavailable}: diagnostic = result.message
    except CatchableError as error:
      state = unavailable
      diagnostic = error.msg
    if diagnostic != lastDiagnostic and diagnostic.len > 0:
      log(diagnostic)
    lastDiagnostic = diagnostic

    let delayMs =
      if state in {matched, applied}: reconcileSeconds * 1000
      elif (getMonoTime() - pendingSince).inMilliseconds < fastRetryWindowMs: fastRetryMs
      elif state == paused: pausedRetryMs
      else: idleRetryMs
    nextAttempt = getMonoTime() + initDuration(milliseconds = delayMs)
    sleep(appearancePollMs)

proc xmlText(value: string): string =
  value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

proc launchConfig(executable, vm, prlctl: string): string =
  """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
""" & managedMarker & """

<plist version="1.0"><dict>
  <key>Label</key><string>""" & label & """</string>
  <key>ProgramArguments</key><array>
    <string>""" & xmlText(executable) & """</string>
    <string>--watch</string>
    <string>""" & xmlText(vm) & """</string>
    <string>""" & xmlText(prlctl) & """</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Background</string>
</dict></plist>
"""

proc install(prlctl, vm: string) =
  discard checked(prlctl, ["list", "-a", "-H", "-o", "status", vm])
  let executable = getAppFilename()
  let domain = "gui/" & $getuid()
  let service = domain & "/" & label
  let plist = getHomeDir() / "Library/LaunchAgents" / (label & ".plist")
  createDir(plist.parentDir)
  let lockPath = plist.parentDir / ("." & label & ".lock")
  let lockFd = posix.open(lockPath.cstring, O_CREAT or O_RDWR or O_NOFOLLOW, Mode(0o600))
  if lockFd < 0: raiseOSError(osLastError(), "Cannot open the installation lock")
  defer: discard posix.close(lockFd)
  if flock(lockFd, LOCK_EX or LOCK_NB) != 0:
    raiseOSError(osLastError(), "Cannot lock the installation")

  let current = run(launchctl, ["print", service])
  let loaded = current.code == 0
  if symlinkExists(plist) or dirExists(plist):
    raise newException(IOError, "Unexpected LaunchAgent file type: " & plist)
  let hasPlist = fileExists(plist)
  let previous = if hasPlist: readFile(plist) else: ""
  if (hasPlist and not previous.contains(managedMarker)) or
      (loaded and (not hasPlist or not current.output.contains("path = " & plist & "\n"))):
    raise newException(IOError, "LaunchAgent is not owned by this installation: " & plist)

  let config = launchConfig(executable, vm, prlctl)
  let (file, staged) = createTempFile(label & ".", ".plist.tmp", plist.parentDir)
  defer:
    if fileExists(staged): removeFile(staged)
  try:
    file.write(config)
  finally:
    file.close()
  discard checked("/usr/bin/plutil", ["-lint", staged])
  # Reload even when the plist is identical. A rebuilt binary has a new code hash.
  if loaded: discard checked(launchctl, ["bootout", service])
  var replaced = false
  try:
    if config != previous:
      moveFile(staged, plist)
      replaced = true
    discard checked(launchctl, ["bootstrap", domain, plist])
  except CatchableError as installError:
    try:
      if replaced:
        if hasPlist:
          writeFile(staged, previous)
          moveFile(staged, plist)
        else:
          removeFile(plist)
      if loaded: discard checked(launchctl, ["bootstrap", domain, plist])
    except CatchableError as recoveryError:
      raise newException(IOError, installError.msg & "\nLaunchAgent recovery failed: " & recoveryError.msg)
    raise
  discard checked(launchctl, ["print", service])
  echo "Installed ", label, " for ", vm, ": ", plist

let args = commandLineParams()
if args.len == 0 or args == @["--help"] or args == @["-h"]:
  echo usage
  quit(0)
let action = args[0]
let validAction =
  (args.len == 2 and action in ["--sync", "--install"]) or
  (args.len == 3 and action == "--watch" and args[2].isAbsolute)
if not validAction or args[1].strip().len == 0 or args[1].startsWith("-"):
  stderr.writeLine(usage)
  quit(2)
let vm = args[1]
try:
  let prlctl = if action == "--watch": args[2] else: findPrlctl()
  case action
  of "--install": install(prlctl, vm)
  of "--sync", "--watch":
    const cfUtf8 = 0x08000100'u32
    let key = CFStringCreateWithCString(nil, "AppleInterfaceStyle", cfUtf8)
    let dark = CFStringCreateWithCString(nil, "Dark", cfUtf8)
    defer:
      CFRelease(key)
      CFRelease(dark)
    if action == "--watch":
      watch(prlctl, vm, key, dark)
    else:
      let result = syncTheme(prlctl, vm, macAppearance(key, dark))
      echo result.message
      if result.state in {paused, unavailable}: quit(3)
  else: discard
except CatchableError as error:
  if action == "--watch": log(error.msg)
  stderr.writeLine(error.msg)
  quit(1)
