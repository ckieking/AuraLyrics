import SwiftUI
import ActivityKit

/// 設定與環境診斷視圖（Apple HIG 實時 PiP 預覽卡與多維度無障礙診斷）
struct SettingsView: View {
    @ObservedObject var envDetector = RuntimeEnvironmentDetector.shared
    @ObservedObject var pipEngine = PiPLyricsEngine.shared
    @ObservedObject var keepAlive = BackgroundKeepAliveManager.shared
    @ObservedObject var pipVM = PiPLyricsViewModel.shared
    @ObservedObject var musicMonitor = AppleMusicMonitor.shared

    @State private var showResetCacheAlert = false
    @State private var cacheClearedToast = false
    @AppStorage("enableLyricDefocusBlur") private var enableLyricDefocusBlur = true

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - 懸浮歌詞 (PiP) 實時預覽與開關
                Section {
                    // 1:1 實時 PiP 預覽視窗卡
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("懸浮動態島膠囊預覽")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("支援深淺色自適應")
                                .font(.caption2)
                                .foregroundColor(.secondary.opacity(0.8))
                        }

                        // 模擬真實懸浮視窗比例 (寬高比 ~ 3.5:1，高度 80pt)
                        PiPLyricsView(viewModel: pipVM)
                            .frame(height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .shadow(color: Color.black.opacity(0.15), radius: 10, y: 4)
                    }
                    .padding(.vertical, 6)

                    Toggle("啟用懸浮歌詞", isOn: Binding(
                        get: { pipEngine.isPiPEnabled },
                        set: { enable in
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            if enable {
                                pipEngine.startPiP()
                            } else {
                                pipEngine.stopPiP()
                            }
                        }
                    ))
                } header: {
                    Text("畫中畫 (PiP) 懸浮視窗")
                } footer: {
                    Text("切換至主畫面或其他 App 時，將自動顯示微縮懸浮動態島歌詞視窗；可隨時拖曳與縮放。")
                }

                // MARK: - 即時動態與動態島
                Section {
                    NavigationLink {
                        LiveActivitySettingsView()
                    } label: {
                        HStack {
                            Label("即時動態與動態島設定", systemImage: "waveform.badge.magnifyingglass")
                            Spacer()
                            Text(LiveActivityLyricsEngine.shared.isEnabled ? "已開啟" : "已關閉")
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("即時動態 (Live Activities)")
                } footer: {
                    Text("自訂鎖定畫面與動態島顯示樣式、次要行資訊、暫停與自動恢復行為。")
                }

                // MARK: - 歌詞視覺效果
                Section {
                    Toggle("未播放歌詞景深模糊", isOn: $enableLyricDefocusBlur)
                } header: {
                    Text("歌詞視覺效果")
                } footer: {
                    Text("開啟後未播放的歌詞將呈現 Apple Music 原生景深模糊質感（單層級失焦），聚焦當前播放行；關閉可完全消除模糊運算以達到極致省電。")
                }

                // MARK: - 歌詞同步時間微調（全域共用）
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("目前全域延遲微調")
                                .font(.subheadline)
                            Spacer()
                            Text(String(format: "%+.1f 秒", Double(musicMonitor.globalOffsetMs) / 1000.0))
                                .font(.system(.subheadline, design: .monospaced).weight(.bold))
                                .foregroundColor(musicMonitor.globalOffsetMs == 0 ? .secondary : .pink)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color(.tertiarySystemFill))
                                .clipShape(Capsule())
                        }

                        HStack(spacing: 10) {
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                musicMonitor.adjustGlobalOffset(byMs: -100)
                            } label: {
                                Text("-0.1s")
                                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 38)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("所有歌曲歌詞延後 0.1 秒")

                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                musicMonitor.resetGlobalOffset()
                            } label: {
                                Text("重設歸零")
                                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 38)
                            }
                            .buttonStyle(.bordered)
                            .tint(.secondary)
                            .accessibilityLabel("重設全域歌詞延遲為零秒")

                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                musicMonitor.adjustGlobalOffset(byMs: 100)
                            } label: {
                                Text("+0.1s")
                                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 38)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("所有歌曲歌詞提前 0.1 秒")
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("歌詞同步時間微調（全域共用）")
                } footer: {
                    Text("所有歌曲共用此微調時間，正值代表歌詞提前唱出、負值代表延後；無須為每首歌分別微調。")
                }

                // MARK: - 系統與環境診斷（圖示形狀 + 狀態文字 + 色彩，符合無障礙規範）
                Section {
                    // 執行環境
                    HStack {
                        Label {
                            Text("執行環境")
                        } icon: {
                            Image(systemName: envDetector.isLiveContainer ? "shippingbox.fill" : "iphone.gen3")
                                .foregroundColor(.pink)
                        }
                        Spacer()
                        HStack(spacing: 5) {
                            Image(systemName: envDetector.isLiveContainer ? "info.circle.fill" : "checkmark.seal.fill")
                                .foregroundColor(envDetector.isLiveContainer ? .orange : .green)
                            Text(envDetector.isLiveContainer ? "LiveContainer 沙盒" : "原生側載環境")
                                .fontWeight(.medium)
                                .foregroundColor(envDetector.isLiveContainer ? .orange : .green)
                        }
                        .font(.subheadline)
                    }

                    // 即時動態 (ActivityKit)
                    HStack {
                        Label {
                            Text("即時動態 (ActivityKit)")
                        } icon: {
                            Image(systemName: "waveform")
                                .foregroundColor(.pink)
                        }
                        Spacer()
                        HStack(spacing: 5) {
                            Image(systemName: envDetector.areLiveActivitiesAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(envDetector.areLiveActivitiesAvailable ? .green : .orange)
                            Text(envDetector.areLiveActivitiesAvailable ? "正常支援" : "受限或不支援")
                                .fontWeight(.medium)
                                .foregroundColor(envDetector.areLiveActivitiesAvailable ? .green : .orange)
                        }
                        .font(.subheadline)
                    }

                    // 畫中畫懸浮窗 (PiP)
                    HStack {
                        Label {
                            Text("畫中畫 (PiP) 支援")
                        } icon: {
                            Image(systemName: "pip")
                                .foregroundColor(.pink)
                        }
                        Spacer()
                        HStack(spacing: 5) {
                            Image(systemName: pipEngine.isPiPPossible ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(pipEngine.isPiPPossible ? .green : .red)
                            Text(pipEngine.isPiPPossible ? "正常支援" : "無法使用")
                                .fontWeight(.medium)
                                .foregroundColor(pipEngine.isPiPPossible ? .green : .red)
                        }
                        .font(.subheadline)
                    }

                    // 背景保活狀態
                    HStack {
                        Label {
                            Text("背景保活狀態")
                        } icon: {
                            Image(systemName: "bolt.shield.fill")
                                .foregroundColor(.pink)
                        }
                        Spacer()
                        HStack(spacing: 5) {
                            Image(systemName: keepAlive.isRunning ? "checkmark.circle.fill" : "pause.circle.fill")
                                .foregroundColor(keepAlive.isRunning ? .green : .secondary)
                            Text(keepAlive.isRunning ? "運作中 (.mixWithOthers)" : "已暫停")
                                .fontWeight(.medium)
                                .foregroundColor(keepAlive.isRunning ? .green : .secondary)
                        }
                        .font(.subheadline)
                    }
                } header: {
                    Text("運行環境與相容性診斷")
                } footer: {
                    Text("若處於 LiveContainer 環境中，iOS 系統可能限制 WidgetKit / ActivityKit 擴展程序的註冊；此時畫中畫 (PiP) 將作為核心主力懸浮引擎。")
                }

                // MARK: - 背景保活管理
                Section {
                    Toggle("背景無縫持續運作", isOn: Binding(
                        get: { keepAlive.isRunning },
                        set: { enable in
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            if enable {
                                keepAlive.startKeepAlive()
                            } else {
                                keepAlive.stopKeepAlive()
                            }
                        }
                    ))
                } header: {
                    Text("背景保活機制")
                } footer: {
                    Text("使用極低 CPU 負擔之無聲混音串流，確保在鎖定畫面、桌面或通訊軟體中，歌詞與進度仍可持續精準同步，絕不降低或中斷 Apple Music 音樂播放。")
                }

                // MARK: - 快取管理
                Section {
                    Button(role: .destructive) {
                        showResetCacheAlert = true
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text("清除所有已下載歌詞快取")
                        }
                        .frame(minHeight: 36)
                    }
                } header: {
                    Text("儲存空間與快取")
                }

                // MARK: - 關於與開源說明
                Section {
                    HStack {
                        Text("應用程式版本")
                        Spacer()
                        Text(appVersionString)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("歌詞檢索架構")
                        Spacer()
                        Text("LRCLIB / 網易雲公開 API")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("關於 AuraLyrics")
                }
            }
            .navigationTitle("設定")
            .alert("確定清除所有歌詞快取？", isPresented: $showResetCacheAlert) {
                Button("取消", role: .cancel) {}
                Button("確定清除", role: .destructive) {
                    clearAllCache()
                }
            } message: {
                Text("此操作將刪除本機儲存的所有歌詞 JSON 快取，後續播放時將重新自線上檢索。")
            }
            .overlay(alignment: .bottom) {
                if cacheClearedToast {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("已成功清除本機歌詞快取")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .liquidGlassCapsule()
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: cacheClearedToast)
        }
    }

    private func clearAllCache() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        LyricsProviderService.shared.clearAllCache()
        cacheClearedToast = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            cacheClearedToast = false
        }
    }

    /// 動態讀取 App 系統版本與內部建置號
    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (Build \(build))"
    }
}
