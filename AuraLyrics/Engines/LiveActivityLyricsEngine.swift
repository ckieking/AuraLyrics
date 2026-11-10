import Foundation
import ActivityKit
import BackgroundTasks
import Combine
import UIKit

/// Native Live Activity and Dynamic Island lyrics engine supporting both ActivityKit and BGContinuedProcessingTask.
@MainActor
public final class LiveActivityLyricsEngine: ObservableObject {
    public static let shared = LiveActivityLyricsEngine()

    // MARK: - Channel B (BGContinuedProcessingTask) Identifiers & State
    public static let continuedTaskIdentifier = "com.auralyrics.app.bgtask.lyrics"

    private var currentContinuedTask: BGContinuedProcessingTask?
    private var isContinuedTaskRegistered: Bool = false
    private var isSubmittingContinuedTask: Bool = false
    private var lastContinuedSubmissionTimestamp: Date? = nil
    private var pendingForegroundSubmission: Bool = false

    // Channel B (BGContinuedProcessingTask) Progress state variables
    private let unitsPerTrack: Int64 = 1000
    private var lastReportedCompletedUnits: Int64 = 0
    private var lastTrackKey: String = ""

    // User dismissal state (X button clicked on dynamic island)
    private var isDismissedUntilNextTrigger: Bool = false
    private var dismissedTrackKey: String = ""

    // Pause heartbeat timer for Channel B
    private var pauseHeartbeatTimer: Timer?

    // Debounce cache for Channel B updates
    private var lastSentContinuedTitle: String?
    private var lastSentContinuedSubtitle: String?
    private var lastSentContinuedIsPlaying: Bool = true

    // MARK: - User Preferences
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

    // MARK: - Runtime State
    @Published public private(set) var isActivityActive: Bool = false
    @Published public private(set) var lastErrorMessage: String? = nil

    private var currentActivity: Activity<LyricsActivityAttributes>?
    private var lastSentState: LyricsActivityAttributes.ContentState?
    private var updateTask: Task<Void, Never>?
    private var pauseTimer: Timer?
    private var currentCachedArtworkPath: String?
    private var currentCachedMicroArtworkData: Data?

    /// Returns whether the system interface style is currently light mode.
    private var isSystemLightMode: Bool {
        if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }) as? UIWindowScene,
           let window = scene.windows.first {
            return window.traitCollection.userInterfaceStyle == .light
        }
        return UITraitCollection.current.userInterfaceStyle == .light
    }

    /// Determines whether the engine should utilize the BGContinuedProcessingTask channel.
    private var shouldUseContinuedProcessing: Bool {
        if #available(iOS 26.0, *) {
            let detector = RuntimeEnvironmentDetector.shared
            return detector.isUsingContinuedProcessingLiveActivity || detector.isLiveContainer
        }
        return false
    }

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

        // Register BGContinuedProcessingTask handler during startup.
        registerContinuedProcessingTask()

        // Register foreground notification observer to resume pending submissions.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { @MainActor [weak self] _ in
            self?.handleAppDidBecomeActive()
        }
    }

    /// Pre-registers the background continued processing task before application launch completes.
    public func registerContinuedProcessingTask() {
        guard #available(iOS 26.0, *), !isContinuedTaskRegistered else { return }
        guard LCBackgroundTaskRuntimeBridge.shared.canRegisterTask(withIdentifier: Self.continuedTaskIdentifier) else {
            print("[LiveActivityLyricsEngine] 任務識別碼 \(Self.continuedTaskIdentifier) 尚未獲系統許可，略過註冊以策安全")
            return
        }
        isContinuedTaskRegistered = true

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.continuedTaskIdentifier,
            using: .main
        ) { [weak self] task in
            guard let continuedTask = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: true)
                return
            }
            self?.handleContinuedProcessingTaskLaunch(continuedTask)
        }
    }

    private func handleAppDidBecomeActive() {
        guard pendingForegroundSubmission, isEnabled else { return }
        pendingForegroundSubmission = false
        startActivity(track: AppleMusicMonitor.shared.currentTrack)
    }

    // MARK: - Start Live Activity
    public func startActivity(
        track: TrackInfo,
        initialLine: String? = nil,
        initialSecondary: String? = nil
    ) {
        guard isEnabled else { return }

        // Route to Channel B (BGContinuedProcessingTask) when running under LiveContainer.
        if shouldUseContinuedProcessing {
            if !isSubmittingContinuedTask {
                startContinuedProcessingTask(track: track, initialLine: initialLine, initialSecondary: initialSecondary)
            }
            return
        }

        if RuntimeEnvironmentDetector.shared.isLiveContainer {
            lastErrorMessage = String(localized: "LiveContainer 虛擬環境需 iOS 26+ 方可使用免 Extension 即時動態，請改用子母畫面 (PiP) 懸浮視窗")
            return
        }

        // Channel A: Native ActivityKit
        guard #available(iOS 16.2, *) else {
            lastErrorMessage = String(localized: "此 iOS 版本不支援即時動態")
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            lastErrorMessage = String(localized: "系統「即時動態」權限未開啟，請至 iOS 設定中允許")
            return
        }

        let artworkPath = cacheArtwork(from: track.artworkData)
        self.currentCachedArtworkPath = artworkPath
        let microArtwork = compressMicroArtwork(from: track.artworkData)
        self.currentCachedMicroArtworkData = microArtwork

        let lineText: String
        if let initial = initialLine, !initial.isEmpty {
            lineText = initial
        } else {
            lineText = (track.title == TrackInfo.placeholder.title) ? String(localized: "AuraLyrics 即時歌詞") : track.title
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
            artworkData: microArtwork,
            compactStyle: compactStyle.rawValue,
            isLightMode: isSystemLightMode
        )

        // Update existing activity in place to prevent animation flickering.
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
            self.lastErrorMessage = String(format: String(localized: "啟動即時動態失敗: %@"), error.localizedDescription)
            self.isActivityActive = false
        }
    }

    /// Submits a BGContinuedProcessingTask request with foreground guards and monotonic progress initialization.
    private func startContinuedProcessingTask(
        track: TrackInfo,
        initialLine: String?,
        initialSecondary: String?
    ) {
        guard #available(iOS 26.0, *) else { return }

        let lineText = (initialLine?.isEmpty == false) ? initialLine! :
            ((track.title == TrackInfo.placeholder.title) ? String(localized: "AuraLyrics 即時歌詞") : track.title)
        let secondaryText = initialSecondary ?? (track.artist.isEmpty ? nil : track.artist)

        // If a task is already active, update its titles and progress in place.
        if let task = currentContinuedTask {
            task.updateTitle(lineText, subtitle: secondaryText ?? "")
            self.lastSentContinuedTitle = lineText
            self.lastSentContinuedSubtitle = secondaryText
            self.lastSentContinuedIsPlaying = true
            self.isActivityActive = true
            self.lastErrorMessage = nil
            BackgroundKeepAliveManager.shared.refreshKeepAliveMode()
            return
        }

        // Guard against duplicate in-flight submission during 150ms tick loop with 30s timeout reset.
        if isSubmittingContinuedTask {
            if let lastTime = lastContinuedSubmissionTimestamp, Date().timeIntervalSince(lastTime) > 30 {
                isSubmittingContinuedTask = false
            } else {
                return
            }
        }

        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.continuedTaskIdentifier,
            title: lineText,
            subtitle: secondaryText ?? ""
        )

        self.isSubmittingContinuedTask = true
        self.lastContinuedSubmissionTimestamp = Date()
        do {
            try BGTaskScheduler.shared.submit(request)
            self.pendingForegroundSubmission = false
            self.isActivityActive = true
            self.lastErrorMessage = nil
            self.lastSentContinuedTitle = lineText
            self.lastSentContinuedSubtitle = secondaryText
            self.lastSentContinuedIsPlaying = true
            BackgroundKeepAliveManager.shared.refreshKeepAliveMode()
        } catch {
            self.isSubmittingContinuedTask = false
            if UIApplication.shared.applicationState != .active {
                // Background submission was deferred by system; queue for foreground completion.
                self.pendingForegroundSubmission = true
            } else {
                self.lastErrorMessage = String(format: String(localized: "啟動免擴充動態島失敗: %@"), error.localizedDescription)
            }
            self.isActivityActive = false
        }
    }

    /// Handles launch callback from BGTaskScheduler for a continued processing task.
    private func handleContinuedProcessingTaskLaunch(_ task: BGContinuedProcessingTask) {
        task.expirationHandler = { [weak self] in
            let wasCancelledByUser = task.progress.isCancelled
            // Ensure completed unit count reaches total before marking success
            // so SpringBoard sees 100% finished and avoids "Task Failed" fault banner.
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: true)

            Task { @MainActor [weak self] in
                self?.handleContinuedTaskExpired(task, wasCancelledByUser: wasCancelledByUser)
            }
        }

        self.isSubmittingContinuedTask = false
        self.currentContinuedTask = task
        self.isActivityActive = true
        self.lastErrorMessage = nil

        // Initialize progress counters ensuring completed strictly < total.
        task.progress.totalUnitCount = unitsPerTrack
        task.progress.completedUnitCount = 0
        lastReportedCompletedUnits = 0

        // Immediately apply current track state if available.
        let track = AppleMusicMonitor.shared.currentTrack
        let title = (track.title == TrackInfo.placeholder.title) ? String(localized: "AuraLyrics 即時歌詞") : track.title
        let subtitle = track.artist.isEmpty ? nil : track.artist
        task.updateTitle(title, subtitle: subtitle ?? "")
        self.lastSentContinuedTitle = title
        self.lastSentContinuedSubtitle = subtitle

        BackgroundKeepAliveManager.shared.refreshKeepAliveMode()
    }

    /// Handles system task expiration by updating state and scheduling recovery.
    private func handleContinuedTaskExpired(_ task: BGContinuedProcessingTask, wasCancelledByUser: Bool) {
        pauseHeartbeatTimer?.invalidate()
        pauseHeartbeatTimer = nil

        if currentContinuedTask === task {
            currentContinuedTask = nil
        }
        self.isSubmittingContinuedTask = false
        self.isActivityActive = false

        if wasCancelledByUser {
            // User explicitly tapped the X button on Dynamic Island.
            self.isDismissedUntilNextTrigger = true
            self.dismissedTrackKey = lastTrackKey
        } else {
            // System timeout or rollover while in background: do not mark user-dismissed
            // so next tick or track update can automatically renew the task.
            self.isDismissedUntilNextTrigger = false
            self.dismissedTrackKey = ""
        }

        BackgroundKeepAliveManager.shared.refreshKeepAliveMode()
    }

    // MARK: - Update Lyrics State
    public func updateLyrics(
        line: String,
        secondaryLine: String?,
        track: TrackInfo,
        isPlaying: Bool,
        progress: Double,
        nextLineIntervalSec: TimeInterval? = nil
    ) {
        guard isEnabled else { return }

        // Route to Channel B when active or indicated.
        if shouldUseContinuedProcessing || currentContinuedTask != nil {
            updateContinuedProcessingLyrics(
                line: line,
                secondaryLine: secondaryLine,
                track: track,
                isPlaying: isPlaying,
                progress: progress
            )
            return
        }

        // Channel A (ActivityKit) execution
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

        let isTrackChanged = (lastSentState?.trackTitle != track.title || lastSentState?.artistName != track.artist)
        let artworkPath: String?
        let microArtwork: Data?
        if isTrackChanged {
            artworkPath = cacheArtwork(from: track.artworkData)
            currentCachedArtworkPath = artworkPath
            microArtwork = compressMicroArtwork(from: track.artworkData)
            currentCachedMicroArtworkData = microArtwork
        } else {
            artworkPath = currentCachedArtworkPath ?? cacheArtwork(from: track.artworkData)
            if currentCachedArtworkPath == nil { currentCachedArtworkPath = artworkPath }
            microArtwork = currentCachedMicroArtworkData ?? compressMicroArtwork(from: track.artworkData)
            if currentCachedMicroArtworkData == nil { currentCachedMicroArtworkData = microArtwork }
        }
        let currentLight = isSystemLightMode

        // Skip redundant IPC updates if state payload is unchanged.
        if let last = lastSentState,
           last.currentLine == line,
           last.secondaryLine == resolvedSecondary,
           last.trackTitle == track.title,
           last.artistName == track.artist,
           last.isPlaying == isPlaying,
           last.compactStyle == compactStyle.rawValue,
           last.isLightMode == currentLight {
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
            artworkData: microArtwork,
            compactStyle: compactStyle.rawValue,
            isLightMode: currentLight
        )
        lastSentState = updatedState

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

    /// Dispatches title, subtitle, and monotonic progress updates to BGContinuedProcessingTask.
    private func updateContinuedProcessingLyrics(
        line: String,
        secondaryLine: String?,
        track: TrackInfo,
        isPlaying: Bool,
        progress: Double
    ) {
        let trackKey = "\(track.title)_\(track.artist)"

        // If user tapped X, wait until track changes or loops before reviving dynamic island.
        if isDismissedUntilNextTrigger {
            let isTrackChanged = !dismissedTrackKey.isEmpty && dismissedTrackKey != trackKey
            let isTrackLoop = !isTrackChanged && progress < 0.05 && lastReportedCompletedUnits > 800
            if isTrackChanged || isTrackLoop {
                isDismissedUntilNextTrigger = false
                dismissedTrackKey = ""
            } else {
                return
            }
        }

        guard let task = currentContinuedTask else {
            if isPlaying && !isSubmittingContinuedTask {
                startContinuedProcessingTask(track: track, initialLine: line, initialSecondary: secondaryLine)
            }
            return
        }

        let resolvedSecondary: String?
        switch secondaryMode {
        case .bilingualOrNext, .bilingualOnly, .nextOnly:
            resolvedSecondary = secondaryLine ?? (track.artist.isEmpty ? nil : track.artist)
        case .none:
            resolvedSecondary = track.artist.isEmpty ? nil : track.artist
        }

        // Debounce title & subtitle updates to reduce cross-process IPC.
        let isContentChanged = (lastSentContinuedTitle != line ||
                                lastSentContinuedSubtitle != resolvedSecondary ||
                                lastSentContinuedIsPlaying != isPlaying)

        if isContentChanged {
            task.updateTitle(line, subtitle: resolvedSecondary ?? "")
            lastSentContinuedTitle = line
            lastSentContinuedSubtitle = resolvedSecondary
            lastSentContinuedIsPlaying = isPlaying
        }

        let clampedProgress = min(max(progress, 0.0), 1.0)
        let isTrackChanged = !lastTrackKey.isEmpty && lastTrackKey != trackKey
        let isTrackLoop = !isTrackChanged && clampedProgress < 0.05 && lastReportedCompletedUnits > 800

        let targetCompleted = max(0, min(990, Int64(clampedProgress * 990.0)))
        let isSeekBackward = targetCompleted + 50 < lastReportedCompletedUnits

        if isTrackChanged || isTrackLoop || isSeekBackward {
            lastReportedCompletedUnits = targetCompleted
            task.progress.totalUnitCount = unitsPerTrack
            task.progress.completedUnitCount = targetCompleted
        }
        lastTrackKey = trackKey

        let newCompleted = max(targetCompleted, lastReportedCompletedUnits)
        task.progress.totalUnitCount = unitsPerTrack
        task.progress.completedUnitCount = newCompleted
        lastReportedCompletedUnits = newCompleted
    }

    // MARK: - Heartbeat for Long Instrumental Breaks
    public func sendHeartbeat(track: TrackInfo) {
        guard isActivityActive else { return }

        // Channel B: Nudge progress forward slightly to prevent system reclamation.
        if let task = currentContinuedTask {
            if lastReportedCompletedUnits < unitsPerTrack - 1 {
                let bumped = lastReportedCompletedUnits + 1
                task.progress.completedUnitCount = bumped
                lastReportedCompletedUnits = bumped
            }
            return
        }

        // Channel A: Extend ActivityKit staleDate.
        guard let activity = currentActivity, let last = lastSentState else { return }
        let nextStale = Date().addingTimeInterval(8)
        updateTask?.cancel()
        updateTask = Task {
            await activity.update(ActivityContent(state: last, staleDate: nextStale))
        }
    }

    // MARK: - Playback State Changes
    public func handlePlaybackPaused() {
        guard isActivityActive else { return }

        startPauseHeartbeatIfNeeded()

        switch pausePolicy {
        case .dismissImmediately:
            pauseHeartbeatTimer?.invalidate()
            pauseHeartbeatTimer = nil
            endActivity()

        case .keepActiveWithTimeout:
            if let task = currentContinuedTask {
                task.updateTitle(lastSentContinuedTitle ?? "", subtitle: String(localized: "已暫停"))
                lastSentContinuedIsPlaying = false
            } else if var state = lastSentState, let activity = currentActivity {
                state.isPlaying = false
                lastSentState = state
                updateTask?.cancel()
                updateTask = Task {
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
            if let task = currentContinuedTask {
                task.updateTitle(lastSentContinuedTitle ?? "", subtitle: String(localized: "已暫停"))
                lastSentContinuedIsPlaying = false
            } else if var state = lastSentState, let activity = currentActivity {
                state.isPlaying = false
                lastSentState = state
                updateTask?.cancel()
                updateTask = Task {
                    await activity.update(ActivityContent(state: state, staleDate: nil))
                }
            }
        }
    }

    private func startPauseHeartbeatIfNeeded() {
        pauseHeartbeatTimer?.invalidate()
        guard currentContinuedTask != nil else { return }
        pauseHeartbeatTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sendPauseHeartbeat()
            }
        }
    }

    private func sendPauseHeartbeat() {
        guard let task = currentContinuedTask, isActivityActive else {
            pauseHeartbeatTimer?.invalidate()
            pauseHeartbeatTimer = nil
            return
        }
        let currentCompleted = task.progress.completedUnitCount
        let currentTotal = task.progress.totalUnitCount
        if currentCompleted < currentTotal - 1 {
            let bumped = currentCompleted + 1
            task.progress.completedUnitCount = bumped
            lastReportedCompletedUnits = bumped
        }
    }

    public func handlePlaybackResumed(track: TrackInfo) {
        pauseTimer?.invalidate()
        pauseTimer = nil
        pauseHeartbeatTimer?.invalidate()
        pauseHeartbeatTimer = nil

        // Reset user dismissal when playback resumes so dynamic island can recover.
        isDismissedUntilNextTrigger = false
        dismissedTrackKey = ""

        guard isEnabled else { return }

        if currentActivity == nil && currentContinuedTask == nil {
            if resumePolicy == .autoResume {
                startActivity(track: track)
            }
        } else if let task = currentContinuedTask {
            lastSentContinuedIsPlaying = true
            task.updateTitle(lastSentContinuedTitle ?? track.title, subtitle: lastSentContinuedSubtitle ?? track.artist)
        } else if var state = lastSentState, let activity = currentActivity {
            state.isPlaying = true
            lastSentState = state
            updateTask?.cancel()
            updateTask = Task {
                await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(8)))
            }
        }
    }

    // MARK: - Toggle State
    public func toggleLiveActivity(track: TrackInfo) {
        if isEnabled {
            isEnabled = false
        } else {
            isEnabled = true
            startActivity(track: track)
        }
    }

    // MARK: - End Live Activity
    public func endActivity() {
        pauseTimer?.invalidate()
        pauseTimer = nil
        pauseHeartbeatTimer?.invalidate()
        pauseHeartbeatTimer = nil
        updateTask?.cancel()
        updateTask = nil
        lastSentState = nil
        currentCachedArtworkPath = nil
        currentCachedMicroArtworkData = nil
        pendingForegroundSubmission = false
        isSubmittingContinuedTask = false
        isDismissedUntilNextTrigger = false
        dismissedTrackKey = ""

        // Tear down Channel B continued processing task.
        if let task = currentContinuedTask {
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: true)
            self.currentContinuedTask = nil
        }
        if isContinuedTaskRegistered {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.continuedTaskIdentifier)
        }

        // Reset tracking for fresh sessions.
        lastReportedCompletedUnits = 0
        lastTrackKey = ""
        lastSentContinuedTitle = nil
        lastSentContinuedSubtitle = nil

        // Tear down Channel A ActivityKit.
        if let activity = currentActivity {
            self.currentActivity = nil
            Task {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        } else if !RuntimeEnvironmentDetector.shared.isLiveContainer {
            Task {
                for act in Activity<LyricsActivityAttributes>.activities {
                    await act.end(nil, dismissalPolicy: .immediate)
                }
            }
        }

        self.isActivityActive = false
        BackgroundKeepAliveManager.shared.refreshKeepAliveMode()
    }

    // MARK: - Synchronous Termination Cleanup
    public nonisolated func cleanUpAllActivitiesSync() {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                LiveActivityLyricsEngine.shared.endActivity()
            }
        }

        final class TaskHolder: @unchecked Sendable {
            var id: UIBackgroundTaskIdentifier = .invalid
        }
        let holder = TaskHolder()
        holder.id = UIApplication.shared.beginBackgroundTask(withName: "com.auralyrics.cleanup.term") {
            let taskID = holder.id
            if taskID != .invalid {
                holder.id = .invalid
                UIApplication.shared.endBackgroundTask(taskID)
            }
        }

        Task.detached {
            let isLiveContainer = await MainActor.run { RuntimeEnvironmentDetector.shared.isLiveContainer }
            if isLiveContainer {
                await MainActor.run {
                    LiveActivityLyricsEngine.shared.endActivity()
                }
            } else {
                for activity in Activity<LyricsActivityAttributes>.activities {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
            }
            let taskID = holder.id
            if taskID != .invalid {
                holder.id = .invalid
                await MainActor.run {
                    UIApplication.shared.endBackgroundTask(taskID)
                }
            }
        }

        // Pump the main RunLoop briefly to flush pending Mach port messages.
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
    }

    // MARK: - Clean Up Orphaned Activities
    public func cleanUpOrphanedActivities() {
        isSubmittingContinuedTask = false
        if isContinuedTaskRegistered {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.continuedTaskIdentifier)
        }
        guard !RuntimeEnvironmentDetector.shared.isLiveContainer else { return }
        Task {
            for activity in Activity<LyricsActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    // MARK: - Settings Refresh
    private func triggerStateRefresh() {
        guard var state = lastSentState, let activity = currentActivity else { return }
        state.compactStyle = compactStyle.rawValue
        lastSentState = state
        Task {
            await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(8)))
        }
    }

    // MARK: - Cache Artwork Thumbnail To Disk
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

    // MARK: - Micro Artwork Thumbnail Compression (< 1.5 KB)
    /// Compresses artwork into an ultra-compact JPEG thumbnail (target size: 40x40, <= 1.5 KB)
    /// to strictly comply with Apple's ActivityKit 4KB ContentState payload limit.
    private func compressMicroArtwork(from data: Data?) -> Data? {
        guard let data = data, let image = UIImage(data: data) else { return nil }

        let targetSize = CGSize(width: 40, height: 40)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let scaledImage = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        // Target: <= 1500 bytes (leaving > 2.5 KB payload headroom for lyrics text & metadata)
        let maxAllowedBytes = 1500

        // Pass 1: Standard micro compression (quality 0.5)
        if let jpegData = scaledImage.jpegData(compressionQuality: 0.5), jpegData.count <= maxAllowedBytes {
            return jpegData
        }

        // Pass 2: High compression (quality 0.3)
        if let jpegData = scaledImage.jpegData(compressionQuality: 0.3), jpegData.count <= maxAllowedBytes {
            return jpegData
        }

        // Pass 3: Ultra-compact downscale (32x32, quality 0.3) if image content is unusually complex
        let minSize = CGSize(width: 32, height: 32)
        let minRenderer = UIGraphicsImageRenderer(size: minSize)
        let minImage = minRenderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: minSize))
        }
        if let fallbackData = minImage.jpegData(compressionQuality: 0.3), fallbackData.count <= maxAllowedBytes {
            return fallbackData
        }

        return nil
    }
}
