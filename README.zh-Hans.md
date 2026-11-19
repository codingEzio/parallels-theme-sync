# parallels-theme-sync

[English](README.md) · [简体中文](README.zh-Hans.md) · [繁體中文](README.zh-Hant.md)

让 Parallels Desktop 中的 Windows 11 虚拟机跟随 Mac 的浅色或深色外观。浅色应用内置的 Sunrise 主题，深色应用 Windows（深色）主题。两者都会切换壁纸。

## 构建与运行

在 macOS 上使用 Nim 和 Apple 命令行工具构建。虚拟机需要 Windows 11、Parallels Tools 和已登录的 Windows 桌面。Parallels Desktop 需要支持 `prlctl exec --current-user --use-advanced-terminal`。[标准版不支持此 CLI](https://kb.parallels.com/en/123296)。

```sh
nim c -d:release --hints:off --out:./parallels-theme-sync parallels_theme_sync.nim
./parallels-theme-sync --sync "你的虚拟机名称"
```

可指定 Parallels 虚拟机名称或 UUID。构建会内嵌 Windows 脚本。装好构建工具和 Parallels Tools 后，可离线运行。

## 登录后自动同步

从固定路径运行可执行文件。替换可执行文件或更换虚拟机后，重新运行安装命令。

```sh
install -d "$HOME/.local/bin"
install -m 755 ./parallels-theme-sync "$HOME/.local/bin/parallels-theme-sync"
"$HOME/.local/bin/parallels-theme-sync" --install "你的虚拟机名称"
```

当前 Mac 用户的 LaunchAgent 保存在 `~/Library/LaunchAgents/local.parallels-theme-sync.plist`。后台任务每半秒读取一次 Mac 外观，每分钟检查一次虚拟机主题。虚拟机暂停、关机或启动中时会重试，并使用 Mac 的最新外观。手动更改的 Windows 主题可能在下次检查时被覆盖。

若要暂停同步并跨登录生效，禁用并卸载后台任务。

```sh
service="gui/$(id -u)/local.parallels-theme-sync"
launchctl disable "$service"
launchctl bootout "$service"
```

恢复时执行 `launchctl enable "$service"`，再运行安装命令。要移除后台任务，先禁用并卸载，再删除其 plist。

## 读取结果

`--sync` 输出 `applied`（已应用）、`matched`（已匹配）或 `skipped`（已跳过）。退出码 0 表示 Windows 已确认主题及两项颜色设置，3 表示虚拟机或 Windows 桌面不可用，1 表示操作失败，2 表示参数无效。后台任务以 `local.parallels-theme-sync` 为标记，将变更与失败写入 Mac 系统日志。

## 兼容性

已在 Apple Silicon、macOS 27.3、Parallels Desktop 27.1.0 和 Windows 11 上验证手动及自动同步。测试期间没有终端弹出或抢焦点。重启后登录及其他版本组合仍待验证。Windows 端使用未公开的 `IThemeManager2` 接口，Windows 更新可能影响兼容性。

## 许可

[MIT](LICENSE)。参见[第三方声明](THIRD_PARTY_NOTICES.md)。
