import SwiftUI
import ActivityKit

/// 設定與環境診斷視圖
struct SettingsView: View {
    @ObservedObject var envDetector = RuntimeEnvironmentDetector.shared
    @ObservedObject var pipEngine = PiPLyricsEngine.shared
    @ObservedObject var keepAlive = BackgroundKeepAliveManager.shared

    @AppStorage("preferredPiPTheme") private var storedPiPTheme: String = PiPVisualTheme.dynamicIsland.rawValue
    @State private var showResetCacheAlert = false

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - 系統與環境診斷
                Section(header: Text("運行環境與相容性診斷")) {
                    HStack {
                        Label("執行環境", systemImage: envDetector.isLiveContainer ? "shippingbox.fill" : "iphone")
                        Spacer()
                        Text(envDetector.isLiveContainer ? "LiveContainer" : "獨立側載安裝")
                            .foregroundColor(envDetector.isLiveContainer ? .orange : .green)
                            .fontWeight(.semibold)
                    }

                    HStack {
                        Label("即時動態 (ActivityKit)", systemImage: "waveform")
                        Spacer()
                        Text(envDetector.areLiveActivitiesAvailable ? "可用" : "不支援 / 受限")
                            .foregroundColor(envDetector.areLiveActivitiesAvailable ? .green : .secondary)
                    }

                    HStack {
                        Label("畫中畫懸浮窗 (PiP)", systemImage: "pip")
                        Spacer()
                        Text(pipEngine.isPiPPossible ? "正常支援" : "無法使用")
                            .foregroundColor(pipEngine.isPiPPossible ? .green : .red)
                    }

                    HStack {
                        Label("背景保活狀態", systemImage: "bolt.shield")
                        Spacer()
                        Text(keepAlive.isRunning ? "運作中 (.mixWithOthers)" : "已停止")
                            .foregroundColor(keepAlive.isRunning ? .green : .secondary)
                    }
                }

                // MARK: - 懸浮歌詞外觀偏好
                Section(
                    header: Text("畫中畫 (PiP) 懸浮視窗樣式"),
                    footer: Text("啟用後，退至背景或切換 App 時會自動跳出懸浮視窗；預設為關閉。")
                ) {
                    Toggle("啟用懸浮歌詞 (退至背景自動顯示)", isOn: Binding(
                        get: { pipEngine.isPiPEnabled },
                        set: { enable in
                            if enable {
                                pipEngine.startPiP()
                            } else {
                                pipEngine.stopPiP()
                            }
                        }
                    ))

                    Picker("視覺主題風格", selection: $storedPiPTheme) {
                        ForEach(PiPVisualTheme.allCases) { theme in
                            Text(theme.localizedTitle).tag(theme.rawValue)
                        }
                    }
                    .onChange(of: storedPiPTheme) { newValue in
                        if let theme = PiPVisualTheme(rawValue: newValue) {
                            pipEngine.currentTheme = theme
                        }
                    }
                }

                // MARK: - 背景保活管理
                Section(header: Text("背景保活設定"), footer: Text("使用極低資源之無聲 PCM 混音，確保切換至桌面或聊天 App 時歌詞持續更新，絕不壓低或干擾 Apple Music 音量。")) {
                    Toggle("啟用背景無縫保活", isOn: Binding(
                        get: { keepAlive.isRunning },
                        set: { enable in
                            if enable {
                                keepAlive.startKeepAlive()
                            } else {
                                keepAlive.stopKeepAlive()
                            }
                        }
                    ))
                }

                // MARK: - 快取管理
                Section(header: Text("儲存空間與快取")) {
                    Button(role: .destructive) {
                        showResetCacheAlert = true
                    } label: {
                        Text("清除所有已下載歌詞快取")
                    }
                }

                // MARK: - 關於與開源說明
                Section(header: Text("關於 AuraLyrics")) {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("0.1.0 (Build 1)")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("架構")
                        Spacer()
                        Text("SwiftUI + ActivityKit + AVKit")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("歌詞來源")
                        Spacer()
                        Text("LRCLIB / 網易雲公開 API")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("設定")
            .alert("確定清除所有歌詞快取？", isPresented: $showResetCacheAlert) {
                Button("取消", role: .cancel) {}
                Button("確定清除", role: .destructive) {
                    for item in LyricsProviderService.shared.listAllCachedLyrics() {
                        LyricsProviderService.shared.deleteCachedLyrics(title: item.trackTitle, artist: item.artistName)
                    }
                }
            } message: {
                Text("此操作將刪除本機儲存的所有歌詞 JSON 快取，後續播放時將重新從網路抓取。")
            }
        }
    }
}
