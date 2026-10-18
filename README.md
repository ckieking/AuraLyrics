# AuraLyrics (靈動歌詞)

> 專為 iOS 打造、完全於裝置端執行（無須自建後端伺服器）、完美支援 **側載 (SideStore / AltStore / TrollStore)** 與 **LiveContainer** 虛擬容器環境的即時動態與懸浮歌詞應用程式。

---

## 🌟 核心特色

1. **雙引擎顯示架構 (Dual-Engine Display Architecture)**
   - **原生動態島與即時動態 (`ActivityKit` + `WidgetKit`)**：在直接側載安裝時，提供 iPhone 動態島（Dynamic Island 緊湊/展開）、鎖定畫面與 StandBy 待機模式毫秒級同步歌詞。
   - **PiP 畫中畫懸浮歌詞膠囊 (`AVPictureInPictureController` + `AVSampleBufferDisplayLayer`)**：完全在主程式執行檔內渲染，不依賴獨立 App Extension。在 **LiveContainer** 環境中自動啟用，跨 App、主畫面懸浮顯示，隨手掌握歌詞。
2. **Apple Human Interface Guidelines (HIG) 原生設計標準**
   - 雙層材質紀律（功能導覽層 Liquid Glass 與邊緣捲動模糊；內容層採用原生動態語義色彩）。
   - SF Pro 動態字級 (`Dynamic Type`)、高對比度文字與 WCAG AA 無障礙標準支援。
   - 任務導向就近控制（時間軸微調、雙語翻譯開關即時切換）。
3. **無須後端伺服器 (100% Client-Side)**
   - 原生連線 **Apple Music** 系統播放器 (`MPMusicPlayerController.systemMusicPlayer`)，免任何 API 金鑰。
   - 整合 **LRCLIB** 與 **網易雲音樂公開 API** 雙歌詞源，支援華語、日語、韓語及歐美曲目，提供雙語對照歌詞。
   - 本地離線快取儲存，支援直接匯入外部 `.lrc` 檔案。
4. **無聲混音背景保活 (`AVAudioSession`)**
   - 動態 PCM 無聲迴圈搭配 `.playback` 與 `.mixWithOthers`，在背景持續追蹤歌詞，**絕不中斷或壓低 Apple Music 音量**。

---

## 📱 LiveContainer 與側載環境支援矩陣

| 環境 / 安裝方式 | 動態島 / 鎖定畫面 (`ActivityKit`) | 畫中畫懸浮歌詞 (`PiP`) | 背景保活 | 推薦 IPA 檔案 |
| :--- | :---: | :---: | :---: | :--- |
| **LiveContainer** | ❌ (iOS 系統不允許 Guest App 載入 Extension) | ✅ **完美支援** (自動預設啟動) | ✅ 支援 | `AuraLyrics-LiveContainer.ipa` |
| **SideStore / AltStore** | ✅ 支援 (需簽名 Extension Target) | ✅ 支援 | ✅ 支援 | `AuraLyrics-Full.ipa` |
| **TrollStore** | ✅ **完全支援** | ✅ **完全支援** | ✅ 支援 | `AuraLyrics-Full.ipa` |
| **免付費 Apple ID 側載** | ⚠️ (若 App ID 不足可使用免 Extension 版) | ✅ 支援 | ✅ 支援 | `AuraLyrics-LiveContainer.ipa` |

---

## 🛠️ 自動化建置與打包指南

專案採用 **XcodeGen (`project.yml`)** 與 **GitHub Actions** 自動化 CI 工作流，即使在 Linux 或 Windows 開發環境下，也能輕鬆在雲端產出可用於手機安裝的 `.ipa`。

### 方式 A：透過 GitHub Actions 自動打包（最推薦，無需 Mac）

1. 將本專案推送到你個人的 GitHub 儲存庫：
   ```bash
   git init
   git add .
   git commit -m "feat: initial commit for AuraLyrics"
   git remote add origin https://github.com/<你的用戶名>/AuraLyrics.git
   git push -u origin main
   ```
2. 進入 GitHub 儲存庫的 **Actions** 分頁。
3. 工作流 `Build AuraLyrics IPA` 會自動在 `macos-15` runner 上編譯。
4. 建置完成後，於 Run 的 **Artifacts** 區下載 `AuraLyrics-IPAs.zip`，解壓縮後即可取得：
   - `AuraLyrics-Full.ipa`：包含完整動態島 Extension + PiP 引擎。
   - `AuraLyrics-LiveContainer.ipa`：純主程式單體包（無 Extension，免佔用額外 App ID，極度純淨）。

### 方式 B：在 macOS 本機使用 Xcode 編譯

若你有 Mac 電腦，可直接在終端機執行：
```bash
# 安裝 xcodegen (若尚未安裝)
brew install xcodegen

# 產生 Xcode 專案檔案
xcodegen generate

# 開啟專案進行除錯或簽名打包
open AuraLyrics.xcodeproj
```

---

## 🚀 安裝與使用指南

### 在 LiveContainer 中使用
1. 下載 `AuraLyrics-LiveContainer.ipa`（或 `AuraLyrics-Full.ipa`）。
2. 在 iPhone 上開啟 **LiveContainer**，點擊右上角 `+` 號匯入該 IPA。
3. 進入 LiveContainer 設定，確保開啟「Fix Background Audio」或允許音訊背景執行。
4. 點擊圖示啟動 AuraLyrics，App 會自動辨識為 LiveContainer 環境。
5. 在 Apple Music 開始播放音樂，回到 AuraLyrics 點擊右上角 **畫中畫圖示 (PiP)**，再滑動返回桌面，懸浮歌詞膠囊即刻啟動！

### 直接側載（SideStore / AltStore / Feather）
1. 使用側載工具安裝 `AuraLyrics-Full.ipa`。
2. 啟動 App 並同意「媒體與 Apple Music」讀取權限。
3. 播放音樂時，可同時享受頂部 **動態島** 實時滾動歌詞與 **PiP 懸浮窗**。

### 手動微調與離線使用
- **時間軸偏差？** 在正在播放畫面點擊 `-0.5s` 或 `+0.5s`，App 會立即記憶此歌曲專屬的時間偏移值。
- **歌詞不準？** 點擊右上角 `...` > `線上搜尋歌詞`，可即時切換網易雲或 LRCLIB 來源。
- **無網路使用？** 點擊 `匯入本地 .lrc` 即可載入你自己的歌詞檔案。

---

## 📄 專案目錄結構

```text
├── .github/workflows/
│   └── build-ipa.yml             # GitHub Actions 自動編譯雙版本 IPA 工作流
├── AuraLyrics/
│   ├── AuraLyricsApp.swift       # SwiftUI 程式進入點
│   ├── Info.plist                # 主程式權限、Background Modes、LiveActivities 配置
│   ├── Services/
│   │   ├── RuntimeEnvironmentDetector.swift # LiveContainer 環境自動偵測
│   │   ├── AppleMusicMonitor.swift          # MPMusicPlayerController 毫秒級時間軸追蹤
│   │   ├── BackgroundKeepAliveManager.swift # 零干擾無聲 PCM 混音保活
│   │   ├── LRCParser.swift                  # LRC 解析與中日韓雙語翻譯合併
│   │   └── LyricsProviderService.swift      # LRCLIB + 網易雲 API 直連與本地快取
│   ├── Engines/
│   │   ├── PiPLyricsEngine.swift            # AVPictureInPicture 畫中畫懸浮歌詞核心
│   │   └── LiveActivityLyricsEngine.swift   # ActivityKit 即時動態核心
│   └── Views/
│       ├── MainTabView.swift                # Apple HIG 三標籤主導覽
│       ├── NowPlayingView.swift             # 正在播放主介面與就近控制項
│       ├── LyricsSearchSheet.swift          # 線上搜尋歌詞模態視窗
│       ├── LibraryView.swift                # 歌詞庫與離線快取管理
│       └── SettingsView.swift               # 環境診斷與外觀設定
├── AuraLyricsWidget/
│   ├── AuraLyricsLiveActivityWidget.swift   # 動態島 (Compact/Expanded/Minimal) & 鎖定畫面
│   └── Info.plist                           # Widget Extension 描述
├── Shared/
│   ├── LyricsModels.swift                   # TrackInfo, LyricLine, SyncedLyrics 共用模型
│   └── LyricsActivityAttributes.swift       # ActivityKit Attributes
├── project.yml                              # XcodeGen 專案配置描述
└── README.md                                # 專案說明文件
```

---

## ⚖️ 開源授權

本專案採 MIT 授權條款開源發布。
所有歌詞資料由 LRCLIB 與網易雲公開 API 提供，版權歸原權利人所有。
