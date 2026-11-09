import Foundation
import MediaPlayer
import Combine
import UIKit

/// System music player monitor and timeline coordinator for Apple Music.
@MainActor
public final class AppleMusicMonitor: ObservableObject {
    public static let shared = AppleMusicMonitor()

    @Published public private(set) var currentTrack: TrackInfo = .placeholder
    @Published public private(set) var currentLyrics: SyncedLyrics = .empty
    @Published public var currentLineIndex: Int? = nil
    @Published public private(set) var isPlaying: Bool = false
    public private(set) var playbackProgress: Double = 0.0
    public private(set) var currentPlaybackTimeSec: TimeInterval = 0.0
    public private(set) var lastTickTimestamp: CFTimeInterval = CACurrentMediaTime()
    @Published public private(set) var isLoadingLyrics: Bool = false

    /// Global playback timing offset in milliseconds.
    @Published public var globalOffsetMs: Int {
        didSet {
            UserDefaults.standard.set(globalOffsetMs, forKey: "globalLyricsOffsetMs")
        }
    }

    private let musicPlayer = MPMusicPlayerController.systemMusicPlayer
    private let timerQueue = DispatchQueue(label: "com.auralyrics.monitor.timerQueue", qos: .userInteractive)
    private var timerSource: DispatchSourceTimer?
    private var isInBackground: Bool = false
    private var lastHeartbeatTimestamp: CFTimeInterval = 0.0

    // MARK: - Playback Timeline Clock Anchors
    private var anchorPlaybackTimeSec: TimeInterval = 0.0
    private var anchorMediaTime: CFTimeInterval = 0.0

    // MARK: - Track Change and Async Task Management
    private var lastPersistentID: MPMediaEntityPersistentID = 0
    private var lastPlaybackStoreID: String = ""
    private var lastPlaybackTimeSec: TimeInterval = 0.0
    private var lyricsFetchTask: Task<Void, Never>? = nil

    private init() {
        self.globalOffsetMs = UserDefaults.standard.integer(forKey: "globalLyricsOffsetMs")
        setupNotifications()
    }

    // MARK: - System Notifications and Lifecycle Setup
    private func setupNotifications() {
        musicPlayer.beginGeneratingPlaybackNotifications()

        NotificationCenter.default.addObserver(
            forName: .MPMusicPlayerControllerNowPlayingItemDidChange,
            object: musicPlayer,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleTrackChanged()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .MPMusicPlayerControllerPlaybackStateDidChange,
            object: musicPlayer,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePlaybackStateChanged()
            }
        }

        // Background transition: record background flag, lock timeline anchor, and sync.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.isInBackground = true
                let now = CACurrentMediaTime()
                if self.isPlaying {
                    let currentExact = self.anchorPlaybackTimeSec + max(0, now - self.anchorMediaTime)
                    self.anchorPlaybackTimeSec = currentExact
                    self.anchorMediaTime = now
                }
                self.syncExternalEngines()
            }
        }

        // Foreground transition: clear background flag and resynchronize player state.
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.isInBackground = false
                self.musicPlayer.beginGeneratingPlaybackNotifications()
                self.handleTrackChanged(force: true)
                self.handlePlaybackStateChanged()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.isInBackground = false
                self.handleTrackChanged()
                self.handlePlaybackStateChanged()
            }
        }
    }

    // MARK: - Playback Monitoring and High-Precision DispatchSourceTimer
    public func startMonitoring() {
        handleTrackChanged(force: true)
        handlePlaybackStateChanged()

        stopTimer()

        let source = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
        source.schedule(deadline: .now(), repeating: .milliseconds(150), leeway: .milliseconds(20))
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        source.resume()
        self.timerSource = source
    }

    private func stopTimer() {
        timerSource?.cancel()
        timerSource = nil
    }

    public func stopMonitoring() {
        stopTimer()
        lyricsFetchTask?.cancel()
        lyricsFetchTask = nil
        musicPlayer.endGeneratingPlaybackNotifications()
    }

    // MARK: - Track Change Handling
    private func handleTrackChanged(force: Bool = false) {
        guard let nowPlaying = musicPlayer.nowPlayingItem else {
            // Preserve current track and lyrics in background when IPC returns nil.
            if isInBackground { return }

            lyricsFetchTask?.cancel()
            lyricsFetchTask = nil
            currentTrack = .placeholder
            currentLyrics = .empty
            currentLineIndex = nil
            playbackProgress = 0.0
            anchorPlaybackTimeSec = 0
            anchorMediaTime = 0
            lastPersistentID = 0
            lastPlaybackStoreID = ""
            lastPlaybackTimeSec = 0
            syncExternalEngines()
            return
        }

        let persistentID = nowPlaying.persistentID
        let playbackStoreID = nowPlaying.playbackStoreID ?? ""
        let title = nowPlaying.title ?? String(localized: "未知曲目")
        let artist = nowPlaying.artist ?? String(localized: "未知歌手")
        let album = nowPlaying.albumTitle ?? ""
        let duration = nowPlaying.playbackDuration
        let genre = nowPlaying.genre ?? ""

        if !force && lastPersistentID != 0 && lastPersistentID == persistentID && currentTrack.title == title && currentTrack.artist == artist && (!currentLyrics.lines.isEmpty || isLoadingLyrics) {
            return
        }

        lastPersistentID = persistentID
        lastPlaybackStoreID = playbackStoreID

        var artworkData: Data? = nil
        if let artwork = nowPlaying.artwork {
            if let image = artwork.image(at: CGSize(width: 120, height: 120)) {
                artworkData = image.pngData()
            }
        }

        let newTrack = TrackInfo(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            artworkData: artworkData,
            genre: genre
        )

        currentTrack = newTrack
        currentLyrics = .empty
        currentLineIndex = nil
        playbackProgress = 0.0

        // Reset playback position if initial reading exceeds threshold on track change.
        let rawPlayTime = musicPlayer.currentPlaybackTime
        let validInitialPlayTime = (!rawPlayTime.isNaN && !rawPlayTime.isInfinite && rawPlayTime >= 0.0 && rawPlayTime < 3.0) ? rawPlayTime : 0.0

        currentPlaybackTimeSec = validInitialPlayTime
        anchorPlaybackTimeSec = validInitialPlayTime
        anchorMediaTime = CACurrentMediaTime()
        lastPlaybackTimeSec = validInitialPlayTime
        syncExternalEngines()

        lyricsFetchTask?.cancel()
        lyricsFetchTask = Task { [weak self] in
            guard let self = self else { return }
            self.isLoadingLyrics = true
            let fetched = await LyricsProviderService.shared.fetchLyrics(track: newTrack)
            guard !Task.isCancelled else { return }
            if let fetched = fetched {
                self.currentLyrics = fetched

                // Resample actual playback position after async lyrics fetching completes to realign timeline anchor.
                let nowPlayTime = self.musicPlayer.currentPlaybackTime
                if !nowPlayTime.isNaN && !nowPlayTime.isInfinite && nowPlayTime >= 0.0 && (newTrack.duration <= 0 || nowPlayTime < newTrack.duration) {
                    self.anchorPlaybackTimeSec = nowPlayTime
                    self.anchorMediaTime = CACurrentMediaTime()
                    self.currentPlaybackTimeSec = nowPlayTime
                    self.lastPlaybackTimeSec = nowPlayTime
                }
            } else {
                self.currentLyrics = SyncedLyrics.empty
            }
            self.refreshCurrentLineIndex(forceSync: true)
            self.isLoadingLyrics = false
        }
    }

    private func handlePlaybackStateChanged() {
        let newIsPlaying = (musicPlayer.playbackState == .playing)
        if isPlaying != newIsPlaying {
            isPlaying = newIsPlaying
            let playTime = musicPlayer.currentPlaybackTime
            if !playTime.isNaN && !playTime.isInfinite && playTime >= 0 {
                if !newIsPlaying && abs(playTime - currentPlaybackTimeSec) < 0.4 {
                    // Retain interpolated playback time on pause if IPC drift is below threshold (< 0.4s).
                    anchorPlaybackTimeSec = currentPlaybackTimeSec
                } else {
                    anchorPlaybackTimeSec = playTime
                    currentPlaybackTimeSec = playTime
                }
            }
            anchorMediaTime = CACurrentMediaTime()
            syncExternalEngines()

            if newIsPlaying {
                LiveActivityLyricsEngine.shared.handlePlaybackResumed(track: currentTrack)
            } else {
                LiveActivityLyricsEngine.shared.handlePlaybackPaused()
            }
        }
    }

    // MARK: - Timeline Timer Loop
    private func tick() {
        let now = CACurrentMediaTime()
        lastTickTimestamp = now

        // 1. Track change detection and metadata population.
        if let nowPlaying = musicPlayer.nowPlayingItem {
            let pid = nowPlaying.persistentID
            let storeID = nowPlaying.playbackStoreID ?? ""
            let title = nowPlaying.title ?? ""
            let artist = nowPlaying.artist ?? ""

            let isPidChanged = (pid != 0 && pid != lastPersistentID)
            let isStoreIDChanged = (!storeID.isEmpty && storeID != lastPlaybackStoreID)
            let isInfoChanged = (!title.isEmpty && (title != currentTrack.title || artist != currentTrack.artist))

            if isPidChanged || isStoreIDChanged || isInfoChanged {
                handleTrackChanged()
                return
            }

            // Backfill duration if unavailable during initial stream buffering.
            if currentTrack.duration <= 0 && nowPlaying.playbackDuration > 0 {
                let updatedTrack = TrackInfo(
                    title: currentTrack.title,
                    artist: currentTrack.artist,
                    album: currentTrack.album,
                    duration: nowPlaying.playbackDuration,
                    artworkData: currentTrack.artworkData,
                    genre: currentTrack.genre.isEmpty ? (nowPlaying.genre ?? "") : currentTrack.genre
                )
                currentTrack = updatedTrack
            }
        } else if !isInBackground && currentTrack.title != TrackInfo.placeholder.title {
            // Only treat nowPlaying == nil as stopped when running in foreground.
            handleTrackChanged()
            return
        }

        let playTime = musicPlayer.currentPlaybackTime
        let isPlayTimeValid = !playTime.isNaN && !playTime.isInfinite && playTime >= 0
        let playTimeDelta = isPlayTimeValid ? (playTime - lastPlaybackTimeSec) : 0
        // Check whether system returned a fresh, monotonically advancing timestamp.
        let hasFreshAdvance = isPlayTimeValid && (playTimeDelta > 0.05 && playTimeDelta < 2.0)

        // 2. Playback state synchronization.
        if !isInBackground {
            let actualIsPlaying = (musicPlayer.playbackState == .playing)
            if isPlaying != actualIsPlaying {
                handlePlaybackStateChanged()
                return
            }
        } else if hasFreshAdvance && !isPlaying {
            isPlaying = true
            anchorPlaybackTimeSec = playTime
            anchorMediaTime = now
            LiveActivityLyricsEngine.shared.handlePlaybackResumed(track: currentTrack)
        }

        // 3. Playback clock advancement and drift calibration.
        if isPlaying {
            let predictedTime = anchorPlaybackTimeSec + max(0, now - anchorMediaTime)

            // Align clock upon first non-zero timestamp after stream buffering.
            let isInitialStart = (anchorPlaybackTimeSec == 0 && playTime > 0.05 && playTime < 5.0 && hasFreshAdvance)

            // Seek detected: elapsed time drifted beyond tolerance (> 1.0s).
            let playTimeJump = abs(playTime - lastPlaybackTimeSec)
            let isUserSeek = isPlayTimeValid && (playTimeJump > 1.2 && abs(playTime - predictedTime) > 1.0)

            // Periodic drift calibration: resynchronize if deviation exceeds 1.5s.
            let hasSignificantDrift = isPlayTimeValid && playTime > 0.5 && (abs(playTime - predictedTime) > 1.5)

            if isUserSeek || isInitialStart || hasSignificantDrift || anchorMediaTime == 0 {
                anchorPlaybackTimeSec = playTime
                anchorMediaTime = now
                currentPlaybackTimeSec = playTime
            } else {
                // Linearly advance playback time based on CACurrentMediaTime() anchor.
                currentPlaybackTimeSec = anchorPlaybackTimeSec + max(0, now - anchorMediaTime)
            }
        } else {
            // When paused, freeze playback position unless a seek is detected (> 0.5s deviation).
            let isUserSeek = isPlayTimeValid && abs(playTime - currentPlaybackTimeSec) > 0.5
            if isUserSeek {
                anchorPlaybackTimeSec = playTime
                currentPlaybackTimeSec = playTime
                anchorMediaTime = now
                lastPlaybackTimeSec = playTime
                if currentTrack.duration > 0 {
                    playbackProgress = min(max(currentPlaybackTimeSec / currentTrack.duration, 0.0), 1.0)
                    if abs(PiPLyricsViewModel.shared.progress - playbackProgress) > 0.002 {
                        PiPLyricsViewModel.shared.progress = playbackProgress
                    }
                }
                refreshCurrentLineIndex(forceSync: true)
            }
            // Skip line refresh during pause without seek to avoid jitter.
            return
        }

        if isPlayTimeValid && playTime > 0 {
            lastPlaybackTimeSec = playTime
        }

        if currentTrack.duration > 0 {
            playbackProgress = min(max(currentPlaybackTimeSec / currentTrack.duration, 0.0), 1.0)
            if abs(PiPLyricsViewModel.shared.progress - playbackProgress) > 0.002 {
                PiPLyricsViewModel.shared.progress = playbackProgress
            }
        }

        refreshCurrentLineIndex()
    }

    /// Computes active lyric line index from interpolated clock and dispatches updates.
    private func refreshCurrentLineIndex(forceSync: Bool = false) {
        let accurateTimeMs = interpolatedPlaybackTimeMs()
        let newIndex = currentLyrics.currentLineIndex(at: accurateTimeMs, globalOffsetMs: 0)

        // Calculate interval to next line for Live Activity staleDate determination.
        var nextLineIntervalSec: TimeInterval? = nil
        if let idx = newIndex, idx + 1 < currentLyrics.lines.count {
            let nextStartMs = currentLyrics.lines[idx + 1].timeMs
            nextLineIntervalSec = max(0.5, Double(nextStartMs - accurateTimeMs) / 1000.0)
        }

        // Lock lyric line index while paused unless forceSync is requested.
        if !isPlaying && !forceSync {
            return
        }

        if newIndex != currentLineIndex {
            currentLineIndex = newIndex
            lastHeartbeatTimestamp = CACurrentMediaTime()
            syncExternalEngines(nextLineIntervalSec: nextLineIntervalSec)
        } else if forceSync {
            lastHeartbeatTimestamp = CACurrentMediaTime()
            syncExternalEngines(nextLineIntervalSec: nextLineIntervalSec)
        } else {
            // Heartbeat check: extend Live Activity staleDate every 4 seconds during long intervals.
            let now = CACurrentMediaTime()
            if isPlaying && (now - lastHeartbeatTimestamp >= 4.0) {
                lastHeartbeatTimestamp = now
                LiveActivityLyricsEngine.shared.sendHeartbeat(track: currentTrack)
            }
        }
    }

    /// Dispatches current playback and lyric state to display engines.
    public func syncExternalEngines(nextLineIntervalSec: TimeInterval? = nil) {
        let showTranslation = UserDefaults.standard.object(forKey: "showBilingualLyrics") as? Bool ?? true

        if let index = currentLineIndex, currentLyrics.lines.indices.contains(index) {
            let current = currentLyrics.lines[index]
            let nextLineText = (index + 1 < currentLyrics.lines.count) ? currentLyrics.lines[index + 1].text : nil
            var secondaryText: String? = nil
            if showTranslation, let trans = current.translation, !trans.isEmpty {
                secondaryText = trans
            } else {
                secondaryText = nextLineText
            }

            PiPLyricsEngine.shared.updateLyrics(
                line: current.text,
                secondaryLine: secondaryText,
                progress: playbackProgress
            )
            LiveActivityLyricsEngine.shared.updateLyrics(
                line: current.text,
                secondaryLine: secondaryText,
                track: currentTrack,
                isPlaying: isPlaying,
                progress: playbackProgress,
                nextLineIntervalSec: nextLineIntervalSec
            )
        } else {
            let isPlaceholder = (currentTrack.title == TrackInfo.placeholder.title)
            let introPrimary = isPlaceholder
                ? String(localized: "AuraLyrics 即時歌詞")
                : currentTrack.title
            let firstLineText = currentLyrics.lines.first?.text
            let introSecondary = isPlaceholder ? nil : (firstLineText ?? (currentTrack.artist.isEmpty ? nil : currentTrack.artist))

            PiPLyricsEngine.shared.updateLyrics(
                line: introPrimary,
                secondaryLine: introSecondary,
                progress: playbackProgress
            )
            LiveActivityLyricsEngine.shared.updateLyrics(
                line: introPrimary,
                secondaryLine: introSecondary,
                track: currentTrack,
                isPlaying: isPlaying,
                progress: playbackProgress,
                nextLineIntervalSec: nextLineIntervalSec
            )
        }
    }

    /// Returns current interpolated playback timestamp in milliseconds.
    public func interpolatedPlaybackTimeMs() -> Int {
        let elapsed = isPlaying ? max(0, CACurrentMediaTime() - anchorMediaTime) : 0
        let timeSec = anchorPlaybackTimeSec + elapsed
        return Int(timeSec * 1000) + globalOffsetMs
    }

    // MARK: - Seek Playback To Lyric Line
    public func seek(toMs targetLineTimeMs: Int) {
        let rawMs = targetLineTimeMs - globalOffsetMs - currentLyrics.offsetMs
        let targetSec = max(0.0, Double(rawMs) / 1000.0)
        musicPlayer.currentPlaybackTime = targetSec
        currentPlaybackTimeSec = targetSec
        anchorPlaybackTimeSec = targetSec
        anchorMediaTime = CACurrentMediaTime()
        lastPlaybackTimeSec = targetSec
        if currentTrack.duration > 0 {
            playbackProgress = min(max(targetSec / currentTrack.duration, 0.0), 1.0)
        }
        refreshCurrentLineIndex(forceSync: true)
    }

    // MARK: - Adjust Global Timing Offset
    public func adjustGlobalOffset(byMs: Int) {
        globalOffsetMs += byMs
        refreshCurrentLineIndex(forceSync: true)
    }

    public func resetGlobalOffset() {
        globalOffsetMs = 0
        refreshCurrentLineIndex(forceSync: true)
    }

    // MARK: - Apply Custom Lyrics
    public func applyCustomLyrics(_ lyrics: SyncedLyrics) {
        currentLyrics = lyrics
        refreshCurrentLineIndex(forceSync: true)
    }

    // MARK: - Apply Translated Lyrics
    public func applyTranslatedLyrics(_ lyrics: SyncedLyrics) {
        guard lyrics.trackTitle == currentTrack.title && lyrics.artistName == currentTrack.artist else { return }
        currentLyrics = lyrics
        syncExternalEngines()
    }
}
