import SwiftUI
import ActivityKit

/// 設定與環境診斷視圖（Apple HIG 實時 PiP 預覽卡與多維度無障礙診斷）
struct SettingsView: View {
    @ObservedObject var envDetector = RuntimeEnvironmentDetector.shared
    @ObservedObject var pipEngine = PiPLyricsEngine.shared
    @ObservedObject var keepAlive = BackgroundKeepAliveManager.shared
    @ObservedObject var pipVM = PiPLyricsViewModel.shared
    @ObservedObject var musicMonitor = AppleMusicMonitor.shared
    @ObservedObject var lyricsProvider = LyricsProviderService.shared

    @State private var showResetCacheAlert = false
    @State private var cacheClearedToast = false
    @AppStorage("enableLyricDefocusBlur") private var enableLyricDefocusBlur = true
    @AppStorage("inactiveLyricOpacity") private var inactiveLyricOpacity = 0.10

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - 子母畫面 (PiP) 實時預覽與開關
                Section {
                    // 1:1 實時 PiP 預覽視窗卡
                    VStack(alignment: .leading, spacing: 10) {
                        Text("子母畫面預覽")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)

                        // 模擬真實懸浮視窗比例 (寬高比 ~ 3.5:1，高度 80pt)
                        PiPLyricsView(viewModel: pipVM)
                            .frame(height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .shadow(color: Color.black.opacity(0.15), radius: 10, y: 4)
                    }
                    .padding(.vertical, 6)

                    Toggle("啟用子母畫面 (PiP)", isOn: Binding(
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
                    Text("子母畫面 (PiP)")
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
                    Text("即時動態")
                }

                // MARK: - 歌詞來源與搜尋順位
                Section {
                    NavigationLink {
                        LyricsSourcePriorityView()
                    } label: {
                        Label("自動搜尋歌詞順位", systemImage: "arrow.up.arrow.down.square")
                    }
                } header: {
                    Text("歌詞來源")
                } footer: {
                    Text("可自訂 Musixmatch、網易雲音樂、LRCLIB 與 PetitLyrics 的搜尋順位，並區分逐字時間軸與普通逐行歌詞。")
                }

                // MARK: - 歌詞視覺效果
                Section {
                    Toggle("非焦點歌詞模糊效果", isOn: $enableLyricDefocusBlur)
                    InactiveLyricOpacitySlider(
                        opacity: $inactiveLyricOpacity,
                        isEnabled: enableLyricDefocusBlur
                    )
                } header: {
                    Text("歌詞視覺效果")
                }

                // MARK: - 歌詞同步時間微調（全域共用）
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("歌詞延遲微調")
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
                            .accessibilityLabel(String(localized: "所有歌曲歌詞延後 0.1 秒"))

                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                musicMonitor.resetGlobalOffset()
                            } label: {
                                Text("重設")
                                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 38)
                            }
                            .buttonStyle(.bordered)
                            .tint(.secondary)
                            .accessibilityLabel(String(localized: "重設全域歌詞延遲為零秒"))

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
                            .accessibilityLabel(String(localized: "所有歌曲歌詞提前 0.1 秒"))
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("歌詞顯示延遲微調")
                } footer: {
                    Text("所有歌曲共用此微調時間，正值代表歌詞提前唱出、負值代表延後。")
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
                            Text(envDetector.isLiveContainer ? String(localized: "LiveContainer 沙盒") : String(localized: "原生側載"))
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
                            Text(envDetector.areLiveActivitiesAvailable ? String(localized: "支援") : String(localized: "受限或不支援"))
                                .fontWeight(.medium)
                                .foregroundColor(envDetector.areLiveActivitiesAvailable ? .green : .orange)
                        }
                        .font(.subheadline)
                    }

                    // 子母畫面 (PiP)
                    HStack {
                        Label {
                            Text("子母畫面 (PiP)")
                        } icon: {
                            Image(systemName: "pip")
                                .foregroundColor(.pink)
                        }
                        Spacer()
                        HStack(spacing: 5) {
                            Image(systemName: pipEngine.isPiPPossible ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(pipEngine.isPiPPossible ? .green : .red)
                            Text(pipEngine.isPiPPossible ? String(localized: "支援") : String(localized: "受限或不支援"))
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
                            Text(keepAlive.isRunning ? String(localized: "運作中") : String(localized: "已暫停"))
                                .fontWeight(.medium)
                                .foregroundColor(keepAlive.isRunning ? .green : .secondary)
                        }
                        .font(.subheadline)
                    }
                } header: {
                    Text("運行環境與相容性診斷")
                } footer: {
                    Text("若處於 LiveContainer 環境中，iOS 系統可能限制 WidgetKit / ActivityKit 擴展程序的註冊。")
                }

                // MARK: - 背景保活管理
                Section {
                    Toggle("啟用背景保活", isOn: Binding(
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
                    Text("背景保活")
                }

                // MARK: - 快取管理
                Section {
                    Button(role: .destructive) {
                        showResetCacheAlert = true
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text("清除所有歌詞快取")
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
                        Text("歌詞來源")
                        Spacer()
                        Text("Musixmatch / 網易雲 (NetEase) / LRCLIB / PetitLyrics")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("開源授權")
                        Spacer()
                        Text("MPL-2.0")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("關於 AuraLyrics")
                } footer: {
                    Text("版權聲明：本應用程式為開源第三方歌詞輔助工具。所有歌詞、翻譯、音訊元資料與專輯封面之版權與商標均屬原詞曲創作者、歌手、製作人及其相應唱片公司或版權方所有。")
                }
            }
            .navigationTitle("設定")
            .alert("確定清除所有歌詞快取？", isPresented: $showResetCacheAlert) {
                Button("取消", role: .cancel) {}
                Button("確定", role: .destructive) {
                    clearAllCache()
                }
            } message: {
                Text("此操作將刪除本機儲存的所有歌詞快取，再次播放將自動重新下載。")
            }
            .overlay(alignment: .bottom) {
                if cacheClearedToast {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("成功清除本機歌詞快取")
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
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.9.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) Beta (Build \(build))"
    }
}

// MARK: - 非焦點歌詞透明度無極調節滑桿（具備預設值吸附與刻度標記）
private struct InactiveLyricOpacitySlider: View {
    @Binding var opacity: Double
    let isEnabled: Bool

    private let defaultValue: Double = 0.10
    private let range: ClosedRange<Double> = 0.05...0.60
    private let snapRange: ClosedRange<Double> = 0.088...0.112

    @State private var isSnapped: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("非焦點歌詞透明度")
                Spacer()
                if abs(opacity - defaultValue) < 0.003 {
                    Text(String(localized: "預設 10%"))
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundColor(isEnabled ? .pink : .secondary)
                } else {
                    Text("\(Int(round(opacity * 100)))%")
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            GeometryReader { geo in
                let trackWidth = max(0, geo.size.width - 28)
                let defaultRatio = (defaultValue - range.lowerBound) / (range.upperBound - range.lowerBound)
                let markX = 14 + trackWidth * CGFloat(defaultRatio)

                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(isEnabled ? (abs(opacity - defaultValue) < 0.003 ? Color.pink : Color.secondary.opacity(0.35)) : Color.secondary.opacity(0.2))
                        .frame(width: 2, height: 12)
                        .cornerRadius(1)
                        .position(x: markX, y: geo.size.height / 2)
                        .allowsHitTesting(false)

                    Slider(
                        value: Binding(
                            get: { opacity },
                            set: { newVal in
                                if snapRange.contains(newVal) {
                                    if !isSnapped {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        isSnapped = true
                                    }
                                    opacity = defaultValue
                                } else {
                                    isSnapped = false
                                    opacity = newVal
                                }
                            }
                        ),
                        in: range
                    )
                    .tint(.pink)
                }
            }
            .frame(height: 32)

            HStack {
                Text("5%")
                Spacer()
                Text("60%")
            }
            .font(.caption2)
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.45)
    }
}
