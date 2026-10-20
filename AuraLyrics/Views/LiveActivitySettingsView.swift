import SwiftUI
import ActivityKit

/// 即時訊息與動態島專屬設定視圖（Apple HIG 標準設定頁面）
struct LiveActivitySettingsView: View {
    @ObservedObject var liveEngine = LiveActivityLyricsEngine.shared
    @ObservedObject var envDetector = RuntimeEnvironmentDetector.shared
    @ObservedObject var musicMonitor = AppleMusicMonitor.shared

    var body: some View {
        Form {
            // MARK: - 動態島實時預覽與運行狀態卡片
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("動態島預覽")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                        Spacer()
                        statusBadge
                    }

                    // 模擬動態島黑膠囊預覽
                    dynamicIslandSimulationView
                        .padding(.vertical, 4)

                    if envDetector.isLiveContainer {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.footnote)
                            Text("LiveContainer 容器環境不支援載入 WidgetKit Extension。建議改用「畫中畫 (PiP) 懸浮視窗」獲得完整的動態島歌詞體驗。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.vertical, 4)

                // 主功能開關
                Toggle("啟用即時動態與動態島", isOn: Binding(
                    get: { liveEngine.isEnabled },
                    set: { newValue in
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        liveEngine.isEnabled = newValue
                        if newValue {
                            liveEngine.startActivity(
                                track: musicMonitor.currentTrack,
                                currentPlaybackTimeSec: musicMonitor.currentPlaybackTimeSec
                            )
                        }
                    }
                ))
                .disabled(envDetector.isLiveContainer)
            } header: {
                Text("即時動態與動態島 (Live Activities)")
            } footer: {
                Text("開啟後，在支援動態島的 iPhone 上將以精緻膠囊同步顯示歌詞；於鎖定畫面則以專屬即時動態卡片呈現。")
            }

            // MARK: - 動態島緊湊模式樣式 (Compact Presentation)
            Section {
                ForEach(DynamicIslandCompactStyle.allCases) { style in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(style.title)
                                .font(.body)
                                .foregroundColor(.primary)
                            Text(style.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if liveEngine.compactStyle == style {
                            Image(systemName: "checkmark")
                                .foregroundColor(.pink)
                                .font(.system(size: 14, weight: .bold))
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        liveEngine.compactStyle = style
                    }
                }
            } header: {
                Text("動態島緊湊外觀 (Compact Style)")
            } footer: {
                Text("未展開動態島黑膠囊時的預設微縮顯示樣式。預設為專輯縮圖與歌詞。")
            }

            // MARK: - 暫停與生命週期處理 (Pause & Resume Policy)
            Section {
                Picker("暫停時處理機制", selection: Binding(
                    get: { liveEngine.pausePolicy },
                    set: { newValue in
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        liveEngine.pausePolicy = newValue
                    }
                )) {
                    ForEach(LiveActivityPausePolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }

                if liveEngine.pausePolicy == .dismissImmediately {
                    Toggle("恢復播放時自動重啟", isOn: Binding(
                        get: { liveEngine.resumePolicy == .autoResume },
                        set: { enable in
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            liveEngine.resumePolicy = enable ? .autoResume : .manual
                        }
                    ))
                }
            } header: {
                Text("暫停與生命週期機制")
            } footer: {
                Text("當在 Apple Music 中暫停播放時，立即收回動態島以節省電力；恢復播放時將自動喚醒接續同步。")
            }

            // MARK: - 歌詞內容與次要行 (Content Presentation)
            Section {
                Picker("副行顯示內容", selection: Binding(
                    get: { liveEngine.secondaryMode },
                    set: { newValue in
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        liveEngine.secondaryMode = newValue
                    }
                )) {
                    ForEach(LiveActivitySecondaryMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                Picker("進度條推進引擎", selection: Binding(
                    get: { liveEngine.progressEngine },
                    set: { newValue in
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        liveEngine.progressEngine = newValue
                    }
                )) {
                    ForEach(LiveActivityProgressEngine.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
            } header: {
                Text("歌詞排版與進度條")
            } footer: {
                Text("系統原生 60fps 計時器由 iOS 本機 GPU 繪製推進，具備最高流暢度且零 IPC 傳輸負擔。")
            }
        }
        .navigationTitle("即時訊息與動態島")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 狀態標籤
    private var statusBadge: some View {
        Group {
            if liveEngine.isActivityActive {
                HStack(spacing: 4) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text("同步中")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(.green)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.green.opacity(0.12))
                .clipShape(Capsule())
            } else if liveEngine.isEnabled {
                HStack(spacing: 4) {
                    Circle().fill(Color.orange).frame(width: 6, height: 6)
                    Text("待命中")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(.orange)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.12))
                .clipShape(Capsule())
            } else {
                Text("未啟用")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(Capsule())
            }
        }
    }

    // MARK: - 模擬動態島黑膠囊視圖
    private var dynamicIslandSimulationView: some View {
        HStack {
            Spacer()
            HStack(spacing: 8) {
                // Leading
                if liveEngine.compactStyle == .artworkAndText {
                    if let data = musicMonitor.currentTrack.artworkData,
                       let uiImage = UIImage(data: data) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 20, height: 20)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.pink.opacity(0.2))
                            Image(systemName: "music.note")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.pink)
                        }
                        .frame(width: 20, height: 20)
                    }
                } else if liveEngine.compactStyle == .minimalWaveform {
                    Image(systemName: "waveform")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.pink)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.pink)
                }

                // Trailing
                if liveEngine.compactStyle == .minimalWaveform {
                    Image(systemName: "waveform")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.pink)
                } else {
                    Text(musicMonitor.currentTrack.title == TrackInfo.placeholder.title ? "AuraLyrics 靈動歌詞" : musicMonitor.currentTrack.title)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.black)
            .clipShape(Capsule())
            .shadow(color: Color.black.opacity(0.25), radius: 6, y: 3)
            Spacer()
        }
        .padding(.vertical, 6)
    }
}
