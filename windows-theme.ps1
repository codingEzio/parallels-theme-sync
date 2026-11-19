# Sent by parallels-theme-sync to the logged-in Windows desktop.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$session = (Get-Process -Id $PID).SessionId
if ($session -eq 0 -or -not (Get-Process explorer -ErrorAction SilentlyContinue |
    Where-Object SessionId -eq $session)) {
    'skipped: Windows desktop is not ready'
    exit 0
}

$dark = $appearance -eq 'Dark'
$themeFile = if ($dark) { 'dark.theme' } else { 'themeC.theme' }
$themePath = Join-Path $env:WINDIR "Resources\Themes\$themeFile"
$wantLight = [int](-not $dark)
$themeKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes'

function Test-Theme {
    $current = Get-ItemPropertyValue -Path $themeKey -Name CurrentTheme
    $colors = Get-ItemProperty "$themeKey\Personalize"
    $current -eq $themePath -and $colors.AppsUseLightTheme -eq $wantLight -and
        $colors.SystemUsesLightTheme -eq $wantLight
}

if (Test-Theme) {
    "matched: $themeFile"
    exit 0
}

# IThemeManager2 is an undocumented Windows interface. Apply a built-in
# theme through the desktop theme manager without opening Settings.
# See THIRD_PARTY_NOTICES.md for references and license notices.
Add-Type @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

[ComImport, Guid("26e4185f-0528-475f-acaf-abe89ba6017d")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IDesktopTheme
{
    void GetDisplayName([MarshalAs(UnmanagedType.BStr)] out string name);
}

[ComImport, Guid("c1e8c83e-845d-4d95-81db-e283fdffc000")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IDesktopThemeManager
{
    void Init(int flags);
    void InitAsync(IntPtr window, int flags);
    void Refresh();
    void RefreshAsync(IntPtr window, int flags);
    void RefreshComplete();
    void GetThemeCount(out int count);
    void GetTheme(int index, out IDesktopTheme theme);
    void IsThemeDisabled(int index, out int disabled);
    void GetCurrentTheme(out int index);
    void SetCurrentTheme(IntPtr window, int index, int applyNow, int flags, int packFlags);
}

public static class ParallelsDesktopTheme
{
    [DllImport("shlwapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int SHLoadIndirectString(
        string source, StringBuilder output, uint size, IntPtr reserved);

    public static void Apply(string path)
    {
        const string displayNameKey = "DisplayName=";
        string displayName = null;
        foreach (string line in File.ReadLines(path))
        {
            if (!line.StartsWith(displayNameKey, StringComparison.OrdinalIgnoreCase))
                continue;
            string resource = Environment.ExpandEnvironmentVariables(line.Substring(displayNameKey.Length));
            var name = new StringBuilder(256);
            Marshal.ThrowExceptionForHR(SHLoadIndirectString(resource, name, 256, IntPtr.Zero));
            displayName = name.ToString();
            break;
        }
        if (String.IsNullOrEmpty(displayName))
            throw new InvalidOperationException("Cannot resolve the built-in theme name.");

        var clsid = new Guid("9324da94-50ec-4a14-a770-e90ca03e7c8f");
        var manager = (IDesktopThemeManager)Activator.CreateInstance(Type.GetTypeFromCLSID(clsid, true));
        try
        {
            manager.Init(0);
            int count;
            manager.GetThemeCount(out count);
            int index = -1;
            for (int i = 0; i < count; i++)
            {
                IDesktopTheme theme;
                manager.GetTheme(i, out theme);
                try
                {
                    string name;
                    theme.GetDisplayName(out name);
                    if (name != displayName)
                        continue;
                    if (index != -1)
                        throw new InvalidOperationException("Windows has duplicate theme names: " + displayName);
                    index = i;
                }
                finally { Marshal.ReleaseComObject(theme); }
            }
            if (index == -1)
                throw new InvalidOperationException("Windows does not list the theme: " + displayName);
            const int noWaitCursor = 1 << 8;
            manager.SetCurrentTheme(IntPtr.Zero, index, 1, noWaitCursor, 0);
        }
        finally { Marshal.ReleaseComObject(manager); }
    }
}
'@

[ParallelsDesktopTheme]::Apply($themePath)
$timer = [Diagnostics.Stopwatch]::StartNew()
do {
    if (Test-Theme) {
        "applied: $themeFile"
        exit 0
    }
    Start-Sleep -Milliseconds 100
} while ($timer.ElapsedMilliseconds -lt 2000)
throw "Windows did not confirm the selected theme and colors: $themeFile"
