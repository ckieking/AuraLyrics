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

    @Published public var progressEngine: LiveActivityProgressEngine {
        didSet {
            UserDefaults.standard.set(progressEngine.rawValue, forKey: "liveActivityProgressEngine")
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
            ?? LiveActivityPausePolicy.dismissImmediately.rawValue
        self.pausePolicy = LiveActivityPausePolicy(rawValue: pauseRaw) ?? .dismissImmediately

        let resumeRaw = UserDefaults.standard.string(forKey: "liveActivityResumePolicy")
            ?? LiveActivityResumePolicy.autoResume.rawValue
        self.resumePolicy = LiveActivityResumePolicy(rawValue: resumeRaw) ?? .autoResume

        let secondaryRaw = UserDefaults.standard.string(forKey: "liveActivitySecondaryMode")
            ?? LiveActivitySecondaryMode.bilingualOrNext.rawValue
        self.secondaryMode = LiveActivitySecondaryMode(rawValue: secondaryRaw) ?? .bilingualOrNext

        let progressRaw = UserDefaults.standard.string(forKey: "liveActivityProgressEngine")
            ?? LiveActivityProgressEngine.smoothTimer.rawValue
        self.progressEngine = LiveActivityProgressEngine(rawValue: progressRaw) ?? .smoothTimer
    }

    // MARK: - 啟動或無縫刷新即時動態
    public func startActivity(track: TrackInfo, currentPlaybackTimeSec: TimeInterval = 0) {
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

        let artworkPath = cacheArtwork(from: track.artworkData)
        self.currentCachedArtworkPath = artworkPath

        let startTime = Date().addingTimeInterval(-max(0, currentPlaybackTimeSec))
        let endTime = startTime.addingTimeInterval(max(1, track.duration))

        let initialContentState = LyricsActivityAttributes.ContentState(
            currentLine: track.title == TrackInfo.placeholder.title ? "AuraLyrics 靈動歌詞" : track.title,
            secondaryLine: track.artist.isEmpty ? nil : track.artist,
            trackTitle: track.title,
            artistName: track.artist,
            isPlaying: true,
            progress: track.duration > 0 ? (currentPlaybackTimeSec / track.duration) : 0,
            artworkPath: artworkPath,
            playbackStart: startTime,
            playbackEnd: endTime,
            compactStyle: compactStyle.rawValue,
            progressEngine: progressEngine.rawValue
        )

        // 若已有運行的 Activity 則直接在原 Activity 上更新，不銷毀重建以避免動態島彈跳閃爍
        if let activity = currentActivity {
            lastSentState = initialContentState
            Task {
                await activity.update(ActivityContent(state: initialContentState, staleDate: Date().addingTimeInterval(30)))
            }
            self.isActivityActive = true
            self.lastErrorMessage = nil
            return
        }

        let attributes = LyricsActivityAttributes(
            albumTitle: track.album.isEmpty ? "AuraLyrics" : track.album,
            totalDurationSec: track.duration
        )

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialContentState, staleDate: Date().addingTimeInterval(30)),
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
    public func updateLyrics(
        line: String,
        secondaryLine: String?,
        track: TrackInfo,
        isPlaying: Bool,
        progress: Double,
        currentPlaybackTimeSec: TimeInterval = 0
    ) {
        guard isEnabled else { return }

        guard let activity = currentActivity else {
            if isPlaying {
                startActivity(track: track, currentPlaybackTimeSec: currentPlaybackTimeSec)
            }
            return
        }

        let resolvedSecondary: String?
        switch secondaryMode {
        case .bilingualOrNext:
            resolvedSecondary = secondaryLine
        case .bilingualOnly:
            resolvedSecondary = secondaryLine
        case .nextOnly:
            resolvedSecondary = secondaryLine
        case .none:
            resolvedSecondary = nil
        }

        let startTime = Date().addingTimeInterval(-max(0, currentPlaybackTimeSec))
        let endTime = startTime.addingTimeInterval(max(1, track.duration))
        let artworkPath = currentCachedArtworkPath ?? cacheArtwork(from: track.artworkData)

        // 若主要歌詞、次要行、曲目、播放狀態、樣式等皆未改變，不重複發送 IPC，極致節省系統後台更新預算
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
            playbackStart: startTime,
            playbackEnd: endTime,
            compactStyle: compactStyle.rawValue,
            progressEngine: progressEngine.rawValue
        )
        lastSentState = updatedState

        updateTask?.cancel()
        updateTask = Task {
            await activity.update(
                ActivityContent(state: updatedState, staleDate: Date().addingTimeInterval(30))
            )
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

    public func handlePlaybackResumed(track: TrackInfo, currentPlaybackTimeSec: TimeInterval) {
        pauseTimer?.invalidate()
        pauseTimer = nil

        guard isEnabled else { return }

        if currentActivity == nil {
            if resumePolicy == .autoResume {
                startActivity(track: track, currentPlaybackTimeSec: currentPlaybackTimeSec)
            }
        } else {
            if var state = lastSentState, let activity = currentActivity {
                state.isPlaying = true
                let startTime = Date().addingTimeInterval(-max(0, currentPlaybackTimeSec))
                state.playbackStart = startTime
                state.playbackEnd = startTime.addingTimeInterval(max(1, track.duration))
                lastSentState = state
                Task {
                    await activity.update(ActivityContent(state: state, staleDate: nil))
                }
            }
        }
    }

    // MARK: - 快速切換開關
    public func toggleLiveActivity(track: TrackInfo, currentPlaybackTimeSec: TimeInterval = 0) {
        if isEnabled {
            isEnabled = false
        } else {
            isEnabled = true
            startActivity(track: track, currentPlaybackTimeSec: currentPlaybackTimeSec)
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
            // 同步清理可能脫鉤的孤兒 activity
            Task {
                for act in Activity<LyricsActivityAttributes>.activities {
                    await act.end(nil, dismissalPolicy: .immediate)
                }
            }
            return
        }
        self.currentActivity = nil
        self.isActivityActive = false
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    // MARK: - App 關閉/終止時同步清理所有即時動態（阻塞主執行緒短暫時間確保 IPC 抵達系統 ActivityKit）
    public nonisolated func cleanUpAllActivitiesSync() {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            for activity in Activity<LyricsActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 1.2)
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
        state.progressEngine = progressEngine.rawValue
        lastSentState = state
        Task {
            await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(30)))
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
