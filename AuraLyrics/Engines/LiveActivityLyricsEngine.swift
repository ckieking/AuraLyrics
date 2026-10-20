import Foundation
import ActivityKit
import Combine
import UIKit

/// 原生即時動態與動態島引擎（ActivityKit）
@MainActor
public final class LiveActivityLyricsEngine: ObservableObject {
    public static let shared = LiveActivityLyricsEngine()

    // MARK: - 使用者偏好設定
    @Published public var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "isLiveActivityEnabled")
            BackgroundKeepAliveManager.shared.refreshKeepAliveMode()
            if !isEnabled {
                endActivity()
            }
        }
    }

    @Published public var compactStyle: DynamicIslandCompactStyle {
        didSet {
            UserDefaults.standard.set(compactStyle.rawValue, forKey: "dynamicIslandCompactStyle")
            triggerStateRefresh()
        }
    }

    @Published public var pausePolicy: LiveActivityPausePolicy {
        didSet {
            UserDefaults.standard.set(pausePolicy.rawValue, forKey: "liveActivityPausePolicy")
        }
    }

    @Published public var resumePolicy: LiveActivityResumePolicy {
        didSet {
            UserDefaults.standard.set(resumePolicy.rawValue, forKey: "liveActivityResumePolicy")
        }
    }

    @Published public var secondaryMode: LiveActivitySecondaryMode {
        didSet {
            UserDefaults.standard.set(secondaryMode.rawValue, forKey: "liveActivitySecondaryMode")
            triggerStateRefresh()
        }
    }

    // MARK: - 運行狀態
    @Published public private(set) var isActivityActive: Bool = false
    @Published public private(set) var lastErrorMessage: String? = nil

    private var currentActivity: Activity<LyricsActivityAttributes>?
    private var lastSentState: LyricsActivityAttributes.ContentState?
    private var updateTask: Task<Void, Never>?
    private var pauseTimer: Timer?
    private var currentCachedArtworkPath: String?

    private init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: "isLiveActivityEnabled")

        let compactRaw = UserDefaults.standard.string(forKey: "dynamicIslandCompactStyle")
            ?? DynamicIslandCompactStyle.artworkAndText.rawValue
        self.compactStyle = DynamicIslandCompactStyle(rawValue: compactRaw) ?? .artworkAndText

        let pauseRaw = UserDefaults.standard.string(forKey: "liveActivityPausePolicy")
            ?? LiveActivityPausePolicy.keepActiveWithTimeout.rawValue
        self.pausePolicy = LiveActivityPausePolicy(rawValue: pauseRaw) ?? .keepActiveWithTimeout

        let resumeRaw = UserDefaults.standard.string(forKey: "liveActivityResumePolicy")
            ?? LiveActivityResumePolicy.autoResume.rawValue
        self.resumePolicy = LiveActivityResumePolicy(rawValue: resumeRaw) ?? .autoResume

        let secondaryRaw = UserDefaults.standard.string(forKey: "liveActivitySecondaryMode")
            ?? LiveActivitySecondaryMode.bilingualOrNext.rawValue
        self.secondaryMode = LiveActivitySecondaryMode(rawValue: secondaryRaw) ?? .bilingualOrNext
    }

    // MARK: - 啟動即時動態
    public func startActivity(
        track: TrackInfo,
        initialLine: String? = nil,
        initialSecondary: String? = nil
    ) {
        guard #available(iOS 16.2, *) else {
            lastErrorMessage = "此 iOS 版本不支援即時動態"
            return
        }

        if RuntimeEnvironmentDetector.shared.isLiveContainer {
            lastErrorMessage = "LiveContainer 虛擬環境無法載入 Widget Extension，請改用 PiP 懸浮膠囊"
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            lastErrorMessage = "系統「即時動態」權限未開啟，請至 iOS 設定中允許"
            return
        }

        let artworkPath = cacheArtwork(from: track.artworkData)
        self.currentCachedArtworkPath = artworkPath

        let lineText: String
        if let initial = initialLine, !initial.isEmpty {
            lineText = initial
        } else {
            lineText = (track.title == TrackInfo.placeholder.title) ? "AuraLyrics 靈動歌詞" : track.title
        }

        let secondaryText: String?
        if let initialSec = initialSecondary {
            secondaryText = initialSec
        } else {
            secondaryText = track.artist.isEmpty ? nil : track.artist
        }

        let initialContentState = LyricsActivityAttributes.ContentState(
            currentLine: lineText,
            secondaryLine: secondaryText,
            trackTitle: track.title,
            artistName: track.artist,
            isPlaying: true,
            progress: 0.0,
            artworkPath: artworkPath,
            compactStyle: compactStyle.rawValue
        )

        // 若已有運行的 Activity 則原地更新，避免動態島彈跳閃爍
        if let activity = currentActivity {
            lastSentState = initialContentState
            updateTask?.cancel()
            updateTask = Task {
                await activity.update(ActivityContent(state: initialContentState, staleDate: Date().addingTimeInterval(8)))
            }
            self.isActivityActive = true
            self.lastErrorMessage = nil
            BackgroundKeepAliveManager.shared.refreshKeepAliveMode()
            return
        }

        let attributes = LyricsActivityAttributes(
            albumTitle: track.album.isEmpty ? "AuraLyrics" : track.album,
            totalDurationSec: track.duration
        )

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialContentState, staleDate: Date().addingTimeInterval(8)),
                pushType: nil
            )
            self.currentActivity = activity
            self.lastSentState = initialContentState
            self.isActivityActive = true
            self.lastErrorMessage = nil
            BackgroundKeepAliveManager.shared.refreshKeepAliveMode()
        } catch {
            self.lastErrorMessage = "啟動即時動態失敗: \(error.localizedDescription)"
            self.isActivityActive = false
        }
    }

    // MARK: - 更新歌詞狀態
    public func updateLyrics(
        line: String,
        secondaryLine: String?,
        track: TrackInfo,
        isPlaying: Bool,
        progress: Double,
        nextLineIntervalSec: TimeInterval? = nil
    ) {
        guard isEnabled else { return }

        guard let activity = currentActivity else {
            if isPlaying {
                startActivity(track: track, initialLine: line, initialSecondary: secondaryLine)
            }
            return
        }

        let resolvedSecondary: String?
        switch secondaryMode {
        case .bilingualOrNext, .bilingualOnly, .nextOnly:
            resolvedSecondary = secondaryLine
        case .none:
            resolvedSecondary = nil
        }

        let artworkPath = currentCachedArtworkPath ?? cacheArtwork(from: track.artworkData)

        // 若主要歌詞、次要行、曲目、播放狀態、樣式等皆未改變，不重複發送 IPC，節省後台預算
        if let last = lastSentState,
           last.currentLine == line,
           last.secondaryLine == resolvedSecondary,
           last.trackTitle == track.title,
           last.artistName == track.artist,
           last.isPlaying == isPlaying,
           last.compactStyle == compactStyle.rawValue {
            return
        }

        let updatedState = LyricsActivityAttributes.ContentState(
            currentLine: line,
            secondaryLine: resolvedSecondary,
            trackTitle: track.title,
            artistName: track.artist,
            isPlaying: isPlaying,
            progress: progress,
            artworkPath: artworkPath,
            compactStyle: compactStyle.rawValue
        )
        lastSentState = updatedState

        // 精準動態 staleDate：下一句歌詞出現時間 + 2.5 秒，最少 4 秒，最長 12 秒
        let delta = nextLineIntervalSec ?? 8.0
        let staleTimeout = min(max(delta + 2.5, 4.0), 12.0)
        let targetStaleDate = Date().addingTimeInterval(staleTimeout)

        updateTask?.cancel()
        updateTask = Task {
            await activity.update(
                ActivityContent(state: updatedState, staleDate: targetStaleDate)
            )
        }
    }

    // MARK: - 長間奏定期心跳 (維持 staleDate 不逾期)
    public func sendHeartbeat(track: TrackInfo) {
        guard isActivityActive, let activity = currentActivity, let last = lastSentState else { return }
        let nextStale = Date().addingTimeInterval(8)
        updateTask?.cancel()
        updateTask = Task {
            await activity.update(ActivityContent(state: last, staleDate: nextStale))
        }
    }

    // MARK: - 暫停與繼續播放處理
    public func handlePlaybackPaused() {
        guard isActivityActive else { return }

        switch pausePolicy {
        case .dismissImmediately:
            endActivity()
        case .keepActiveWithTimeout:
            if var state = lastSentState, let activity = currentActivity {
                state.isPlaying = false
                lastSentState = state
                Task {
                    await activity.update(ActivityContent(state: state, staleDate: nil))
                }
            }
            pauseTimer?.invalidate()
            pauseTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.endActivity()
                }
            }
        case .keepActiveAlways:
            if var state = lastSentState, let activity = currentActivity {
                state.isPlaying = false
                lastSentState = state
                Task {
                    await activity.update(ActivityContent(state: state, staleDate: nil))
                }
            }
        }
    }

    public func handlePlaybackResumed(track: TrackInfo) {
        pauseTimer?.invalidate()
        pauseTimer = nil

        guard isEnabled else { return }

        if currentActivity == nil {
            if resumePolicy == .autoResume {
                startActivity(track: track)
            }
        } else {
            if var state = lastSentState, let activity = currentActivity {
                state.isPlaying = true
                lastSentState = state
                Task {
                    await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(8)))
                }
            }
        }
    }

    // MARK: - 快速切換開關
    public func toggleLiveActivity(track: TrackInfo) {
        if isEnabled {
            isEnabled = false
        } else {
            isEnabled = true
            startActivity(track: track)
        }
    }

    // MARK: - 結束即時動態
    public func endActivity() {
        pauseTimer?.invalidate()
        pauseTimer = nil
        updateTask?.cancel()
        updateTask = nil
        lastSentState = nil
        currentCachedArtworkPath = nil

        guard let activity = currentActivity else {
            Task {
                for act in Activity<LyricsActivityAttributes>.activities {
                    await act.end(nil, dismissalPolicy: .immediate)
                }
            }
            BackgroundKeepAliveManager.shared.refreshKeepAliveMode()
            return
        }

        self.currentActivity = nil
        self.isActivityActive = false
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        BackgroundKeepAliveManager.shared.refreshKeepAliveMode()
    }

    // MARK: - App 終止清理 (非阻塞式排空 XPC，確保 Activity.end 抵達系統 ActivityKit)
    public nonisolated func cleanUpAllActivitiesSync() {
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "com.auralyrics.cleanup.term") {
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }

        Task.detached {
            for activity in Activity<LyricsActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }

        // 旋轉主執行緒 RunLoop 0.35 秒排空 Mach port 訊息，絕不使用 Semaphore 死鎖
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
    }

    // MARK: - App 啟動時清理過往殘留之孤兒即時動態
    public func cleanUpOrphanedActivities() {
        Task {
            for activity in Activity<LyricsActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    // MARK: - 內部設定變更時刷新當前狀態
    private func triggerStateRefresh() {
        guard var state = lastSentState, let activity = currentActivity else { return }
        state.compactStyle = compactStyle.rawValue
        lastSentState = state
        Task {
            await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(8)))
        }
    }

    // MARK: - 封面縮圖快取至共享/快取檔案路徑 (避免 4KB payload 超限)
    private func cacheArtwork(from data: Data?) -> String? {
        guard let data = data, let image = UIImage(data: data) else { return nil }
        let targetSize = CGSize(width: 80, height: 80)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let scaledImage = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        guard let jpegData = scaledImage.jpegData(compressionQuality: 0.8) else { return nil }

        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.auralyrics")
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        guard let container = container else { return nil }
        let fileURL = container.appendingPathComponent("current_artwork.jpg")
        do {
            try jpegData.write(to: fileURL)
            return fileURL.path
        } catch {
            return nil
        }
    }
}
