import Foundation
import ActivityKit
import Combine

/// 原生即時動態與動態島引擎（ActivityKit）
@MainActor
public final class LiveActivityLyricsEngine: ObservableObject {
    public static let shared = LiveActivityLyricsEngine()

    @Published public private(set) var isActivityActive: Bool = false
    @Published public private(set) var lastErrorMessage: String? = nil

    private var currentActivity: Activity<LyricsActivityAttributes>?
    private var lastSentState: LyricsActivityAttributes.ContentState?
    private var updateTask: Task<Void, Never>?

    private init() {}

    // MARK: - 啟動即時動態
    public func startActivity(track: TrackInfo) {
        guard #available(iOS 16.2, *) else {
            lastErrorMessage = "此 iOS 版本不支援即時動態"
            return
        }

        // 若在 LiveContainer 內，提示並自動切換
        if RuntimeEnvironmentDetector.shared.isLiveContainer {
            lastErrorMessage = "LiveContainer 虛擬環境無法載入 Widget Extension，請改用 PiP 懸浮膠囊"
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            lastErrorMessage = "系統「即時動態」權限未開啟，請至 iOS 設定中允許"
            return
        }

        // 若已有運行的 Activity 則結束並重建
        endActivity()

        let attributes = LyricsActivityAttributes(
            albumTitle: track.album.isEmpty ? "AuraLyrics" : track.album,
            totalDurationSec: track.duration
        )

        let initialContentState = LyricsActivityAttributes.ContentState(
            currentLine: "AuraLyrics 靈動歌詞",
            secondaryLine: "\(track.title) - \(track.artist)",
            trackTitle: track.title,
            artistName: track.artist,
            isPlaying: true,
            progress: 0.0
        )

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialContentState, staleDate: nil),
                pushType: nil
            )
            self.currentActivity = activity
            self.lastSentState = initialContentState
            self.isActivityActive = true
            self.lastErrorMessage = nil
        } catch {
            self.lastErrorMessage = "啟動即時動態失敗: \(error.localizedDescription)"
            self.isActivityActive = false
        }
    }

    // MARK: - 更新歌詞狀態
    public func updateLyrics(line: String, secondaryLine: String?, track: TrackInfo, isPlaying: Bool, progress: Double) {
        guard let activity = currentActivity else { return }

        // 若主要歌詞、雙語副行、曲目與播放狀態皆未改變，則不重複發送 IPC 更新，節省電池與系統頻寬
        if let last = lastSentState,
           last.currentLine == line,
           last.secondaryLine == secondaryLine,
           last.trackTitle == track.title,
           last.artistName == track.artist,
           last.isPlaying == isPlaying {
            return
        }

        let updatedState = LyricsActivityAttributes.ContentState(
            currentLine: line,
            secondaryLine: secondaryLine,
            trackTitle: track.title,
            artistName: track.artist,
            isPlaying: isPlaying,
            progress: progress
        )
        lastSentState = updatedState

        updateTask?.cancel()
        updateTask = Task {
            await activity.update(
                ActivityContent(state: updatedState, staleDate: nil)
            )
        }
    }

    // MARK: - 結束即時動態
    public func endActivity() {
        updateTask?.cancel()
        updateTask = nil
        lastSentState = nil
        guard let activity = currentActivity else { return }
        self.currentActivity = nil
        self.isActivityActive = false
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
