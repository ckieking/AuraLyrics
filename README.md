# AuraLyrics

> 專為 iOS 設計的動態歌詞應用程式，支援 Apple Music 播放追蹤、子母畫面 (PiP) 懸浮視窗與動態島即時動態（Live Activity）。

---

## 核心功能

### 1. App 內歌詞介面
- **Apple Music 風格視覺**：聚焦目前播放中的歌詞行，非焦點行自動模糊弱化，並具備動態漸層背景。
- **逐字動態歌詞**：支援網易雲音樂 (YRC/KRC)、Musixmatch (Richsync) 與 LRCLIB (Enhanced LRC) 逐字時間軸，提供平滑逐字填色效果。
- **雙語歌詞對照**：支援雙語翻譯合併顯示，可於介面隨時切換。

### 2. 桌面與跨 App 歌詞顯示
- **子母畫面 (PiP) 懸浮視窗**：將 App 退至背景或切換至其他應用時，透過原生 `AVPictureInPictureController` 持續懸浮顯示即時更新的歌詞，無黑屏或控制條干擾。
- **多種懸浮版型**：提供「動態島膠囊風」、「標準雙行卡片（原文＋翻譯）」與「簡約單行」三種版型切換。
- **動態島與即時動態 (Live Activity)**：支援鎖定畫面與 iPhone 動態島（緊湊 / 展開模式），快速瀏覽當前播放段落（需系統 Widget 支援）。

### 3. 多來源整合與自訂設定
- **多來源搜尋優先權**：整合網易雲音樂、Musixmatch 與 LRCLIB，可自由調整搜尋順序，並獨立啟用或停用個別來源與逐字 / 逐行模式。
- **手動搜尋與時間軸校準**：支援即時線上搜尋與切換歌詞版本；針對個別歌曲提供 ±0.1 秒時間軸手動調整，系統會自動儲存個別偏好。
- **本地快取與自訂匯入**：支援離線快取儲存，並提供手動匯入本機 `.lrc` 歌詞檔案功能。

### 4. 客戶端原生運作與背景同步
- **純客戶端架構**：本機直接連結系統 `MPMusicPlayerController` 讀取播放狀態，無需 API 金鑰或自建伺服器。
- **背景音訊混音保活**：採用 `AVAudioSession` 混音模式搭配無聲循環機制，在背景穩定維持歌詞同步追蹤，不中斷或干擾音樂播放。

---

## 運行環境相容性

AuraLyrics 具備環境偵測機制（`RuntimeEnvironmentDetector`），統一透過單一套件 **`AuraLyrics-<版本號>.ipa`** 發布。偵測是否有完整的權限執行操作：

| 環境 / 安裝方式 | 動態島 / 鎖定畫面 (`ActivityKit`) | 子母畫面懸浮歌詞 (`PiP`) | 機制說明 | 建議安裝包 |
| :--- | :---: | :---: | :--- | :--- |
| **LiveContainer** | ❌ (Guest App 未支援 Extension) | ✅ 支援 | 偵測到容器環境，自動停用 Extension 呼叫並採用主程式 PiP 引擎 | `AuraLyrics-0.1.0.ipa` |
| **SideStore / AltStore** | ✅ 支援 (需一併簽名 Extension Target) | ✅ 支援 | 獨立側載環境，可同時啟用動態島與 PiP | `AuraLyrics-0.1.0.ipa` |
| **個人 Apple ID 側載** | ⚠️ (視簽名工具之 Extension 支援度而定) | ✅ 支援 | 可正常使用 PiP 與背景保活 | `AuraLyrics-0.1.0.ipa` |

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
4. 建置完成後，於該次 Run 的 **Artifacts** 區下載 `AuraLyrics-IPA.zip`，解壓縮後即可取得安裝套件：
   - `AuraLyrics-0.1.0.ipa`：包含動態島 Extension 與 PiP 引擎，自動適配各種安裝環境。

### 方式 B：在 macOS 本機使用 Xcode 編譯

若你有 Mac 環境，可於終端機執行：
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
1. 下載並取得 `AuraLyrics-0.1.0.ipa`。
2. 在 iPhone 上開啟 **LiveContainer**，點擊右上角 `+` 號匯入該 IPA。
3. 進入 LiveContainer 設定，確保開啟「Fix Background Audio」或允許音訊背景執行。
4. 啟動 AuraLyrics，App 會自動偵測為 LiveContainer 環境。
5. 在 Apple Music 開始播放音樂，回到 AuraLyrics 點擊右上角 **子母畫面圖示 (PiP)**（或在設定中開啟「啟用子母畫面 (PiP)」），返回桌面即可懸浮顯示。

### 側載工具（SideStore / AltStore / TrollStore / Feather 等）
1. 使用側載工具安裝 `AuraLyrics-0.1.0.ipa`。
2. 啟動 App 並允許「媒體與 Apple Music」讀取權限。
3. 播放音樂時，可使用頂部 **動態島 / 鎖定畫面即時動態** 或 **PiP 懸浮視窗** 檢視歌詞。

### 常用操作
- **時間軸偏差？** 在正在播放畫面點擊 `-0.5s` 或 `+0.5s`，App 會自動儲存此歌曲專屬的時間偏移值。
- **歌詞不符？** 點擊右上角 `...` > `線上搜尋歌詞`，可手動搜尋並切換來源版本。
- **無網路使用？** 點擊 `匯入本地 .lrc` 即可載入自行準備的歌詞檔案。

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
│   │   ├── BackgroundKeepAliveManager.swift # 無聲 PCM 混音背景保活
│   │   ├── LRCParser.swift                  # LRC 解析與逐字時間軸處理
│   │   ├── LyricsProviderService.swift      # 多歌詞源 (網易雲/Musixmatch/LRCLIB) 與快取
│   │   └── RuntimeEnvironmentDetector.swift # 容器與側載環境自動偵測
│   ├── Engines/
│   │   ├── PiPLyricsEngine.swift            # AVPictureInPicture 子母畫面懸浮歌詞核心
│   │   └── LiveActivityLyricsEngine.swift   # ActivityKit 即時動態核心
│   └── Views/
│       ├── MainTabView.swift                # 主分頁導覽
│       ├── NowPlayingView.swift             # 正在播放主介面與操作控制項
│       ├── LyricsSearchSheet.swift          # 線上搜尋歌詞模態視窗
│       ├── LyricsSourcePriorityView.swift   # 歌詞來源優先權排序介面
│       ├── LiveActivitySettingsView.swift   # 即時動態外觀設定
│       ├── LibraryView.swift                # 歌詞庫與離線快取管理
│       ├── SettingsView.swift               # 環境診斷與外觀設定
│       └── Components/
│           ├── AmbientGradientBackground.swift # 動態漸層背景
│           ├── AppleMusicKaraokeText.swift    # 逐字平滑填色文字元件
│           └── LiquidGlass.swift               # 玻璃材質視覺效果
├── AuraLyricsWidget/
│   ├── AuraLyricsLiveActivityWidget.swift   # 動態島 (Compact/Expanded/Minimal) 與鎖定畫面 Widget
│   └── Info.plist                           # Widget Extension 配置
├── Shared/
│   ├── LiveActivityConfig.swift             # 即時動態配置模型
│   ├── LyricsActivityAttributes.swift       # ActivityKit Attributes 定義
│   ├── LyricsModels.swift                   # 歌詞、曲目與優先權共用模型
│   └── Resources/
│       └── Localizable.xcstrings            # 本地化多語系資源
├── project.yml                              # XcodeGen 專案配置描述
└── README.md                                # 專案說明文件
```

---

## 開源授權

本專案採 MIT 授權條款開源發布。  
所有歌詞資料由各公開 API 與來源提供，版權歸原權利人所有。
