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
                Text("開啟後，當 Apple Music 播放音樂時，鎖定畫面與動態島將自動同步呈現即時滾動歌詞。")
            }

            // MARK: - 動態島緊湊樣式設定
            Section {
                Picker("動態島緊湊顯示樣式", selection: $liveActivityEngine.compactStyle) {
                    ForEach(DynamicIslandCompactStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.navigationLink)
            } header: {
                Text("動態島外觀")
            } footer: {
                Text(liveActivityEngine.compactStyle.description)
            }

            // MARK: - 次要行（副行）顯示設定
            Section {
                Picker("副行顯示模式", selection: $liveActivityEngine.secondaryMode) {
                    ForEach(LiveActivitySecondaryMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.navigationLink)
            } header: {
                Text("副行資訊")
            } footer: {
                Text("決定主歌詞下方或展開視圖中顯示雙語翻譯或是下一句歌詞預覽。")
            }

            // MARK: - 暫停與繼續播放策略
            Section {
                Picker("音樂暫停時處理方式", selection: $liveActivityEngine.pausePolicy) {
                    ForEach(LiveActivityPausePolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                .pickerStyle(.navigationLink)

                Picker("音樂繼續播放時處理方式", selection: $liveActivityEngine.resumePolicy) {
                    ForEach(LiveActivityResumePolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                .pickerStyle(.navigationLink)
            } header: {
                Text("暫停與恢復行為")
            } footer: {
                Text("即時訊息被關閉後可能需要重新開啟此App來恢復")
            }

            // MARK: - 背景同步與權限提示
            Section {
                HStack {
                    Text("背景同步狀態")
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
                    Button("至系統設定授予定位權限") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .foregroundColor(.pink)
                }
            } header: {
                Text("系統後台運作")
            } footer: {
                Text("iOS 系統禁止背景音訊行程更新即時動態。AuraLyrics 透過極低耗電之粗略定位保活與背景任務維持即時歌詞刷新，絕不收集或上傳任何位置資料。")
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
            return "使用期間允許 (正常)"
        case .authorizedAlways:
            return "永遠允許 (最佳)"
        case .denied, .restricted:
            return "已拒絕 (背景將無法更新)"
        case .notDetermined:
            return "尚未要求授權"
        @unknown default:
            return "未知狀態"
        }
    }
}
