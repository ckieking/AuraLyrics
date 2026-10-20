import SwiftUI
import CoreLocation

/// 即時動態與動態島專屬設定頁面
public struct LiveActivitySettingsView: View {
    @ObservedObject private var liveActivityEngine = LiveActivityLyricsEngine.shared
    @ObservedObject private var monitor = AppleMusicMonitor.shared
    @ObservedObject private var keepAlive = BackgroundKeepAliveManager.shared

    public init() {}

    public var body: some View {
        Form {
            // MARK: - 主功能開關
            Section {
                Toggle("啟用即時動態與動態島歌詞", isOn: $liveActivityEngine.isEnabled)
                    .onChange(of: liveActivityEngine.isEnabled) { _, newValue in
                        if newValue {
                            liveActivityEngine.startActivity(track: monitor.currentTrack)
                            monitor.syncExternalEngines()
                        }
                    }

                if let error = liveActivityEngine.lastErrorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundColor(.red)
                }
            } header: {
                Text("功能啟用")
            } footer: {
                Text("開啟後，當 Apple Music 播放音樂時，動態島與即時動態將同步呈現即時滾動歌詞。")
            }

            // MARK: - 動態島緊湊樣式設定
            Section {
                NavigationLink {
                    DynamicIslandCompactStyleSettingsView(selectedStyle: $liveActivityEngine.compactStyle)
                } label: {
                    HStack {
                        Text("動態島顯示樣式")
                        Spacer()
                        Text(liveActivityEngine.compactStyle.title)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("動態島外觀")
            }

            // MARK: - 次要行（副行）顯示設定
            Section {
                NavigationLink {
                    SecondaryModeSettingsView(selectedMode: $liveActivityEngine.secondaryMode)
                } label: {
                    HStack {
                        Text("副行顯示模式")
                        Spacer()
                        Text(liveActivityEngine.secondaryMode.title)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("副行資訊")
            }

            // MARK: - 暫停與繼續播放策略
            Section {
                NavigationLink {
                    PausePolicySettingsView(selectedPolicy: $liveActivityEngine.pausePolicy)
                } label: {
                    HStack {
                        Text("音樂暫停時處理方式")
                        Spacer()
                        Text(liveActivityEngine.pausePolicy.title)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                NavigationLink {
                    ResumePolicySettingsView(selectedPolicy: $liveActivityEngine.resumePolicy)
                } label: {
                    HStack {
                        Text("音樂繼續播放時處理方式")
                        Spacer()
                        Text(liveActivityEngine.resumePolicy.title)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("暫停與恢復行為")
            } footer: {
                Text("即時訊息被關閉後可能需要重新開啟此 App 來恢復")
            }

            // MARK: - 背景同步與權限提示
            Section {
                HStack {
                    Text("背景保活狀態")
                    Spacer()
                    Text(keepAlive.isRunning ? "運作中" : "待命中")
                        .foregroundColor(keepAlive.isRunning ? .green : .secondary)
                }

                HStack {
                    Text("背景定位保活授權")
                    Spacer()
                    Text(locationStatusDescription(keepAlive.locationAuthorizationStatus))
                        .foregroundColor(isLocationAuthorized ? .primary : .orange)
                }

                if !isLocationAuthorized {
                    Button("權限設定") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .foregroundColor(.pink)
                }
            } header: {
                Text("系統後台運作")
            } footer: {
                Text("iOS 系統禁止背景音訊行程更新即時動態。AuraLyrics 透過粗略定位保活與背景任務維持即時歌詞刷新，不會收集你的隱私及資訊。")
            }
        }
        .navigationTitle("即時動態與動態島")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var isLocationAuthorized: Bool {
        keepAlive.locationAuthorizationStatus == .authorizedWhenInUse ||
        keepAlive.locationAuthorizationStatus == .authorizedAlways
    }

    private func locationStatusDescription(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .authorizedWhenInUse:
            return "僅使用期間允許"
        case .authorizedAlways:
            return "永遠允許 (最佳)"
        case .denied, .restricted:
            return "從不 (無法背景更新)"
        case .notDetermined:
            return "尚未要求授權"
        @unknown default:
            return "未知狀態"
        }
    }
}

// MARK: - 動態島樣式即時預覽元件
private struct DynamicIslandCompactPreview: View {
    let style: DynamicIslandCompactStyle
    @ObservedObject private var monitor = AppleMusicMonitor.shared

    private var sampleLyric: String {
        if let idx = monitor.currentLineIndex, idx < monitor.currentLyrics.lines.count {
            let line = monitor.currentLyrics.lines[idx].text
            if !line.isEmpty { return line }
        }
        if !monitor.currentTrack.title.isEmpty && monitor.currentTrack.title != "尚未播放音樂" {
            return monitor.currentTrack.title
        }
        return "AuraLyrics 即時滾動歌詞"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                switch style {
                case .artworkAndText:
                    if let artworkData = monitor.currentTrack.artworkData,
                       let uiImage = UIImage(data: artworkData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 18, height: 18)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    } else {
                        ZStack {
                            LinearGradient(
                                colors: [Color.pink.opacity(0.8), Color.purple.opacity(0.8)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            Image(systemName: "music.note")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                        }
                        .frame(width: 18, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                case .iconAndText:
                    Image(systemName: "music.note")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.pink)
                case .textOnly:
                    EmptyView()
                }

                Spacer(minLength: 12)

                Text(sampleLyric)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Color.black)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.6)
            )
            .shadow(color: Color.black.opacity(0.18), radius: 6, x: 0, y: 3)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: style)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }
}

// MARK: - 動態島緊湊顯示樣式設定子頁面
private struct DynamicIslandCompactStyleSettingsView: View {
    @Binding var selectedStyle: DynamicIslandCompactStyle

    var body: some View {
        Form {
            Section {
                DynamicIslandCompactPreview(style: selectedStyle)
            } header: {
                Text("預覽畫面")
            }

            Section {
                ForEach(DynamicIslandCompactStyle.allCases) { style in
                    Button {
                        selectedStyle = style
                    } label: {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(style.title)
                                    .font(.body)
                                    .foregroundColor(.primary)
                                Text(style.description)
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if selectedStyle == style {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.pink)
                                    .fontWeight(.semibold)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("動態島顯示樣式")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 副行顯示模式設定子頁面
private struct SecondaryModeSettingsView: View {
    @Binding var selectedMode: LiveActivitySecondaryMode

    var body: some View {
        Form {
            Section {
                ForEach(LiveActivitySecondaryMode.allCases) { mode in
                    Button {
                        selectedMode = mode
                    } label: {
                        HStack(alignment: .center, spacing: 12) {
                            Text(mode.title)
                                .font(.body)
                                .foregroundColor(.primary)
                            Spacer()
                            if selectedMode == mode {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.pink)
                                    .fontWeight(.semibold)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("副行顯示設定")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 音樂暫停處理方式設定子頁面
private struct PausePolicySettingsView: View {
    @Binding var selectedPolicy: LiveActivityPausePolicy

    var body: some View {
        Form {
            Section {
                ForEach(LiveActivityPausePolicy.allCases) { policy in
                    Button {
                        selectedPolicy = policy
                    } label: {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(policy.title)
                                    .font(.body)
                                    .foregroundColor(.primary)
                                Text(policy.description)
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if selectedPolicy == policy {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.pink)
                                    .fontWeight(.semibold)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("音樂暫停時處理方式")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 音樂繼續播放處理方式設定子頁面
private struct ResumePolicySettingsView: View {
    @Binding var selectedPolicy: LiveActivityResumePolicy

    var body: some View {
        Form {
            Section {
                ForEach(LiveActivityResumePolicy.allCases) { policy in
                    Button {
                        selectedPolicy = policy
                    } label: {
                        HStack(alignment: .center, spacing: 12) {
                            Text(policy.title)
                                .font(.body)
                                .foregroundColor(.primary)
                            Spacer()
                            if selectedPolicy == policy {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.pink)
                                    .fontWeight(.semibold)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("音樂繼續播放時處理方式")
        .navigationBarTitleDisplayMode(.inline)
    }
}
