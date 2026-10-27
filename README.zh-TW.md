# AuraLyrics

<p align="center">
  <img src="AuraLyrics/Resources/AppIcon-Preview.png" alt="AuraLyrics App Icon" width="128" height="128" />
</p>

<p align="center">
  <a href="https://auralyrics.dpdns.org"><b>🌐 官方網站</b></a> &nbsp;|&nbsp;
  <a href="README.md">English</a> &nbsp;|&nbsp;
  <b>繁體中文</b>
</p>

> 專為 iOS 設計的動態歌詞應用程式，支援 Apple Music 播放追蹤、子母畫面 (PiP) 懸浮視窗與動態島即時動態（Live Activity）。
>> 這個倉庫中的大部分內容由AI代理建立
>
> 🌐 **官方網站：** [https://auralyrics.dpdns.org](https://auralyrics.dpdns.org)

---

## 核心功能

### 1. App 內歌詞介面
- **Apple Music 風格視覺**：聚焦目前播放中的歌詞行，非焦點行自動模糊弱化，並具備動態漸層背景。
- **逐字動態歌詞**：支援網易雲音樂 (YRC/KRC)、Musixmatch (Richsync) 與 LRCLIB (Enhanced LRC) 逐字時間軸，提供平滑逐字填色效果。
- **雙語歌詞對照**：支援雙語翻譯合併顯示，可於介面隨時切換。

### 2. 桌面與跨 App 歌詞顯示
- **子母畫面 (PiP) 懸浮視窗**：將 App 退至背景或切換至其他應用時，透過原生 `AVPictureInPictureController` 持續懸浮顯示即時更新的歌詞。
- **多種懸浮版型**：提供「動態島膠囊風」、「標準雙行卡片（原文＋翻譯）」與「簡約單行」三種版型切換。
- **動態島與即時動態 (Live Activity)**：支援鎖定畫面與 iPhone 動態島（緊湊 / 展開模式），快速瀏覽當前播放段落（需系統 Widget 支援）。

### 3. 多來源整合與自訂設定
- **多來源搜尋優先權**：整合網易雲音樂、Musixmatch 與 LRCLIB，可自由調整搜尋順序，並獨立啟用或停用個別來源與逐字 / 逐行模式。
- **手動搜尋與時間軸校準**：支援即時線上搜尋與切換歌詞版本；針對個別歌曲提供 ±0.1 秒時間軸手動調整，系統會自動儲存個別偏好。
- **本地快取與自訂匯入**：支援離線快取儲存，並提供手動匯入本機 `.lrc` 歌詞檔案功能。

### 4. 純客戶端運作與智慧背景保活
- **純客戶端架構**：本機直接連結系統 `MPMusicPlayerController` 讀取播放狀態，無需 API 金鑰或自建伺服器。
- **智慧背景保活架構 (`BackgroundKeepAliveManager`)**：
  - **即時動態模式**：採用低耗電定位追蹤搭配 `BGTaskScheduler` 標準排程，確保背景穩定運作。
  - **PiP 模式**：採用合規的低音量音訊混音保活機制（無任何非公開 API），確保子母畫面懸浮視窗在背景持續流暢更新。
  - **終止清理與權限一致性**：強化終止清理時的併發安全性，並確保權限描述字串（InfoPlist.xcstrings）完整一致。

---

## 運行環境相容性

AuraLyrics 具備環境偵測機制（`RuntimeEnvironmentDetector`），統一透過單一套件 **`AuraLyrics-<版本號>.ipa`** 發布：

| 環境 / 安裝方式 | 動態島 / 鎖定畫面 (`ActivityKit`) | 子母畫面懸浮歌詞 (`PiP`) | 機制說明 | 建議安裝包 |
| :--- | :---: | :---: | :--- | :--- |
| **LiveContainer** | ❌ (Guest App 未支援 Extension) | ✅ 支援 | 自動停用 Extension 呼叫並採用主程式 PiP 引擎 | `AuraLyrics-0.9.0-beta.ipa` |
| **SideStore / AltStore** | ✅ 支援 (需一併簽名 Extension Target) | ✅ 支援 | 獨立側載環境，可同時啟用動態島與 PiP | `AuraLyrics-0.9.0-beta.ipa` |
| **個人 Apple ID 側載** | ⚠️ (視簽名工具之 Extension 支援度而定) | ✅ 支援 | 可正常使用 PiP 與背景保活 | `AuraLyrics-0.9.0-beta.ipa` |

---

## 🛠️ 建置與打包指南

專案採用 **XcodeGen (`project.yml`)** 與 **GitHub Actions** 自動化 CI 工作流，可在雲端或本機產出安裝套件 `.ipa`。

### 方式 A：透過 GitHub Actions 自動打包（推薦，無需本機 Mac）
1. 將本專案推送到個人的 GitHub 儲存庫：
   ```bash
   git init
   git add .
   git commit -m "[feat]: initial commit for AuraLyrics"
   git remote add origin https://github.com/<你的使用者名稱>/AuraLyrics.git
   git push -u origin main
   ```
2. 進入 GitHub 儲存庫的 **Actions** 頁面。
3. 觸發或等待 `Build AuraLyrics IPA` 工作流完成編譯。
4. 下載 `AuraLyrics-IPA.zip` 取得安裝套件。

### 方式 B：在 macOS 本機使用 Xcode 編譯
```bash
# 安裝 xcodegen（若尚未安裝）
brew install xcodegen

# 產生 Xcode 專案檔案
xcodegen generate

# 開啟專案進行除錯或簽名打包
open AuraLyrics.xcodeproj
```

---

## 安裝與使用指南

### 在 LiveContainer 中使用
1. 下載並取得 `AuraLyrics-0.9.0-beta.ipa`。
2. 在 iPhone 上開啟 **LiveContainer**，匯入該 IPA。
3. 進入 LiveContainer 設定，確保開啟「Fix Background Audio」或允許音訊背景執行。
4. 啟動 AuraLyrics，App 會自動偵測環境並啟用 PiP 懸浮顯示。

### 側載工具（SideStore / AltStore / TrollStore / Feather 等）
1. 使用側載工具安裝 `AuraLyrics-0.9.0-beta.ipa`。
2. 啟動 App 並允許相關權限。
3. 播放音樂時，可使用頂部 **動態島 / 鎖定畫面即時動態** 或 **PiP 懸浮視窗** 檢視歌詞。

---

## 專案目錄結構

```text
├── .github/workflows/
│   └── build-ipa.yml             # GitHub Actions 自動編譯 IPA 工作流
├── AuraLyrics/
│   ├── AuraLyricsApp.swift       # SwiftUI 程式進入點
│   ├── Info.plist                # 主程式權限、Background Modes、LiveActivities 配置
│   ├── Resources/
│   │   └── InfoPlist.xcstrings   # 權限描述多語系字串
│   ├── Services/
│   │   ├── AppleMusicMonitor.swift          # MPMusicPlayerController 播放狀態追蹤
│   │   ├── ArtworkColorExtractor.swift      # 專輯封面主色調提取
│   │   ├── BackgroundKeepAliveManager.swift # 智慧背景保活管理（低耗電定位 + 混音保活）
│   │   ├── LRCParser.swift                  # LRC 解析與逐字時間軸處理
│   │   ├── LyricsProviderService.swift      # 多歌詞源與快取
│   │   └── RuntimeEnvironmentDetector.swift # 容器與側載環境自動偵測
│   ├── Engines/
│   │   ├── PiPLyricsEngine.swift            # AVPictureInPicture 子母畫面懸浮歌詞核心
│   │   └── LiveActivityLyricsEngine.swift   # ActivityKit 即時動態核心
│   └── Views/
│   ...
├── AuraLyricsWidget/
│   └── AuraLyricsLiveActivityWidget.swift   # 動態島與鎖定畫面 Widget
├── Shared/
│   └── ...                                  # 共用模型與屬性
├── project.yml                              # XcodeGen 專案配置描述
└── README.md                                # 專案說明文件
```

---

## 版權聲明與免責聲明 (Copyright & Disclaimer)

- **歌詞、翻譯與專輯封面**：本專案所展示之歌詞、翻譯內容及專輯封面圖片，其版權與商標權均歸原創作者、詞曲作者、發行商及唱片公司所有。
- **音樂商標**：Apple Music 及相關商標為 Apple Inc. 之註冊商標。
- **性質宣告**：本專案（AuraLyrics）為純粹出於學習、研究與輔助用途的**非商業開源輔助工具**，未內建任何付費內容解鎖，亦未授權任何商業營利行為。

---

## 開源授權 (License)

Copyright (c) 2026 ckieking and AuraLyrics Contributors.

本專案採 [Mozilla Public License 2.0 (MPL-2.0)](./LICENSE) 授權條款開源發布。
