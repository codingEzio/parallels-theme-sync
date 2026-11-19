# parallels-theme-sync

[English](README.md) · [简体中文](README.zh-Hans.md) · [繁體中文](README.zh-Hant.md)

讓 Parallels Desktop 中的 Windows 11 虛擬機器跟隨 Mac 的淺色或深色外觀。淺色套用內建的 Sunrise 佈景主題，深色套用 Windows（深色）佈景主題。兩者都會切換桌布。

## 建置與執行

在 macOS 上使用 Nim 和 Apple 命令列工具建置。虛擬機器需要 Windows 11、Parallels Tools 和已登入的 Windows 桌面。Parallels Desktop 必須支援 `prlctl exec --current-user --use-advanced-terminal`。[標準版不支援此 CLI](https://kb.parallels.com/en/123296)。

```sh
nim c -d:release --hints:off --out:./parallels-theme-sync parallels_theme_sync.nim
./parallels-theme-sync --sync "你的虛擬機器名稱"
```

可指定 Parallels 虛擬機器名稱或 UUID。建置會內嵌 Windows 指令碼。裝好建置工具和 Parallels Tools 後，可離線執行。

## 登入後自動同步

從固定路徑執行檔案。替換執行檔或更換虛擬機器後，重新執行安裝指令。

```sh
install -d "$HOME/.local/bin"
install -m 755 ./parallels-theme-sync "$HOME/.local/bin/parallels-theme-sync"
"$HOME/.local/bin/parallels-theme-sync" --install "你的虛擬機器名稱"
```

目前 Mac 使用者的 LaunchAgent 儲存在 `~/Library/LaunchAgents/local.parallels-theme-sync.plist`。背景工作每半秒讀取一次 Mac 外觀，每分鐘檢查一次虛擬機器佈景主題。虛擬機器暫停、關機或啟動中時會重試，並使用 Mac 的最新外觀。手動變更的 Windows 佈景主題可能在下次檢查時被覆寫。

若要暫停同步並跨登入生效，停用並卸載背景工作。

```sh
service="gui/$(id -u)/local.parallels-theme-sync"
launchctl disable "$service"
launchctl bootout "$service"
```

恢復時執行 `launchctl enable "$service"`，再執行安裝指令。若要移除背景工作，先停用並卸載，再刪除其 plist。

## 讀取結果

`--sync` 輸出 `applied`（已套用）、`matched`（已符合）或 `skipped`（已跳過）。結束代碼 0 表示 Windows 已確認佈景主題及兩項色彩設定，3 表示虛擬機器或 Windows 桌面無法使用，1 表示操作失敗，2 表示引數無效。背景工作以 `local.parallels-theme-sync` 為標記，將變更與失敗寫入 Mac 系統日誌。

## 相容性

已在 Apple Silicon、macOS 27.3、Parallels Desktop 27.1.0 和 Windows 11 上驗證手動及自動同步。測試期間沒有終端機視窗彈出或取得焦點。重新啟動後登入及其他版本組合仍待驗證。Windows 端使用未公開的 `IThemeManager2` 介面，Windows 更新可能影響相容性。

## 授權

[MIT](LICENSE)。請參閱[第三方聲明](THIRD_PARTY_NOTICES.md)。
