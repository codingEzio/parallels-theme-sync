# parallels-theme-sync

[English](README.md) · [简体中文](README.zh-Hans.md) · [繁體中文](README.zh-Hant.md)

Make a Windows 11 VM in Parallels Desktop follow the Mac's light or dark appearance. Light selects the built-in Sunrise theme. Dark selects Windows (dark). Both include their wallpapers.

## Build and run

Use macOS, Nim and Apple's Command Line Tools to build. The VM needs Windows 11, Parallels Tools and a signed-in Windows desktop. Parallels Desktop must support `prlctl exec --current-user --use-advanced-terminal`. Its Standard edition [does not support the CLI](https://kb.parallels.com/en/123296).

```sh
nim c -d:release --hints:off --out:./parallels-theme-sync parallels_theme_sync.nim
./parallels-theme-sync --sync "Your VM name"
```

Use a Parallels VM name or UUID. The build embeds the Windows script. Once the build tools and Parallels Tools are in place, it can run offline.

## Sync at login

Run the executable from a stable location. Install again after replacing the binary or to select a different VM.

```sh
install -d "$HOME/.local/bin"
install -m 755 ./parallels-theme-sync "$HOME/.local/bin/parallels-theme-sync"
"$HOME/.local/bin/parallels-theme-sync" --install "Your VM name"
```

The LaunchAgent is saved at `~/Library/LaunchAgents/local.parallels-theme-sync.plist` for the current Mac user. It samples appearance every half second and checks for guest changes once a minute. The watch retries when the VM is paused, stopped or starting, using the latest Mac appearance. Windows theme changes made by hand can be overwritten on the next check.

To pause sync across logins, disable and unload the agent.

```sh
service="gui/$(id -u)/local.parallels-theme-sync"
launchctl disable "$service"
launchctl bootout "$service"
```

To resume, run `launchctl enable "$service"` and run the install command again. To remove the agent, disable and unload it, then remove its plist.

## Read the result

`--sync` prints `applied`, `matched`, or `skipped`. Exit 0 means Windows confirmed the theme and both color settings. Exit 3 means the VM or Windows desktop was unavailable. Exit 1 means an operation failed. Exit 2 means the arguments were invalid. The watcher reports changes and failures to the Mac system log under `local.parallels-theme-sync`.

## Compatibility

Manual and automatic sync were verified on Apple Silicon with macOS 27.3, Parallels Desktop 27.1.0 and Windows 11. Neither operation opened or focused a terminal during the test. Login after reboot and other version combinations remain unverified. Windows uses the undocumented `IThemeManager2` interface, so Windows updates can affect compatibility.

## License

[MIT](LICENSE). See the [third-party notices](THIRD_PARTY_NOTICES.md).
