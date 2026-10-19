import Foundation
import MediaPlayer
import Combine
import UIKit

/// Apple Music 系統播放器監聽與即時時間軸推播器
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

    /// 全域歌詞同步時間微調偏移量（毫秒，每首歌共用）
    @Published public var globalOffsetMs: Int {
        didSet {
            UserDefaults.standard.set(globalOffsetMs, forKey: "globalLyricsOffsetMs")
        }
    }

    private let musicPlayer = MPMusicPlayerController.systemMusicPlayer
    private var timer: Timer?

    // MARK: - 高精度防抖時鐘錨點
    private var anchorPlaybackTimeSec: TimeInterval = 0.0
    private var anchorMediaTime: CFTimeInterval = 0.0

    // MARK: - 換歌追蹤與非同步任務管理
    private var lastPersistentID: MPMediaEntityPersistentID = 0
    private var lastPlaybackStoreID: String = ""
    private var lastPlaybackTimeSec: TimeInterval = 0.0
    private var lyricsFetchTask: Task<Void, Never>? = nil

    private init() {
        self.globalOffsetMs = UserDefaults.standard.integer(forKey: "globalLyricsOffsetMs")
        setupNotifications()
    }

    // MARK: - 系統通知與生命週期設定
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

        // App 回到前景時主動重新同步播放器狀態，防止自然切歌時系統通知脫鉤
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
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
                self.handleTrackChanged()
                self.handlePlaybackStateChanged()
            }
        }
    }

    // MARK: - 啟動監聽與高精度時間軸定時器
    public func startMonitoring() {
        handleTrackChanged(force: true)
        handlePlaybackStateChanged()

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
    }

    public func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        lyricsFetchTask?.cancel()
        lyricsFetchTask = nil
        musicPlayer.endGeneratingPlaybackNotifications()
    }

    // MARK: - 曲目變更處理 (支援強制刷新與即時清空舊歌詞)
    private func handleTrackChanged(force: Bool = false) {
        guard let nowPlaying = musicPlayer.nowPlayingItem else {
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
            return
        }

        let persistentID = nowPlaying.persistentID
        let playbackStoreID = nowPlaying.playbackStoreID ?? ""
        let title = nowPlaying.title ?? "未知曲目"
        let artist = nowPlaying.artist ?? "未知歌手"
        let album = nowPlaying.albumTitle ?? ""
        let duration = nowPlaying.playbackDuration

        // 若非強制重整，且 persistentID 或 storeID 與當前曲目完全相符，且已有歌詞或正在載入，避免無謂重複請求
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
            artworkData: artworkData
        )

        // 核心修復：立即更新曲目並清空舊歌詞，杜絕上一首歌詞殘留並在 0 秒處被錯誤重新點亮
        currentTrack = newTrack
        currentLyrics = .empty
        currentLineIndex = nil
        playbackProgress = 0.0

        let playTime = musicPlayer.currentPlaybackTime
        currentPlaybackTimeSec = playTime
        anchorPlaybackTimeSec = playTime
        anchorMediaTime = CACurrentMediaTime()
        lastPlaybackTimeSec = playTime

        // 取消先前可能未完成的非同步歌詞請求，避免競態覆蓋
        lyricsFetchTask?.cancel()
        lyricsFetchTask = Task { [weak self] in
            guard let self = self else { return }
            self.isLoadingLyrics = true
            let fetched = await LyricsProviderService.shared.fetchLyrics(track: newTrack)
            guard !Task.isCancelled else { return }
            if let fetched = fetched {
                self.currentLyrics = fetched
                let currentMs = self.interpolatedPlaybackTimeMs()
                self.currentLineIndex = fetched.currentLineIndex(at: currentMs, globalOffsetMs: self.globalOffsetMs)
            } else {
                self.currentLyrics = SyncedLyrics.empty
                self.currentLineIndex = nil
            }
            self.isLoadingLyrics = false
        }
    }

    private func handlePlaybackStateChanged() {
        let newIsPlaying = (musicPlayer.playbackState == .playing)
        if isPlaying != newIsPlaying {
            isPlaying = newIsPlaying
            let playTime = musicPlayer.currentPlaybackTime
            currentPlaybackTimeSec = playTime
            anchorPlaybackTimeSec = playTime
            anchorMediaTime = CACurrentMediaTime()
        }
    }

    // MARK: - 時間軸定時器循環
    private func tick() {
        let playTime = musicPlayer.currentPlaybackTime
        let nowPlaying = musicPlayer.nowPlayingItem

        // 1. 多維度換歌偵測 (Persistent ID, Store ID, 曲目基本資訊, 或時間突變 Wrap-around)
        if let nowPlaying = nowPlaying {
            let pid = nowPlaying.persistentID
            let storeID = nowPlaying.playbackStoreID ?? ""
            let title = nowPlaying.title ?? ""
            let artist = nowPlaying.artist ?? ""

            let isPidChanged = (pid != 0 && pid != lastPersistentID)
            let isStoreIDChanged = (!storeID.isEmpty && storeID != lastPlaybackStoreID)
            let isInfoChanged = (!title.isEmpty && (title != currentTrack.title || artist != currentTrack.artist))

            // 自然播完切歌或單曲重播之時間突變偵測 (Time Wrap-around)
            // 當前時間已歸零至 < 2.5 秒，而前一拍時間 > 5 秒且前首歌進度已超過 70%
            let isTimeWrapped = (playTime < 2.5 && lastPlaybackTimeSec > 5.0 && (currentTrack.duration > 0 ? (lastPlaybackTimeSec / currentTrack.duration > 0.70) : true))

            if isPidChanged || isStoreIDChanged || isInfoChanged {
                handleTrackChanged()
                return
            } else if isTimeWrapped {
                handleTrackChanged(force: true)
                return
            }
        } else if currentTrack.title != TrackInfo.placeholder.title {
            // 播放器已被關閉或曲目為空
            handleTrackChanged()
            return
        }

        currentPlaybackTimeSec = playTime
        lastPlaybackTimeSec = playTime
        let now = CACurrentMediaTime()
        lastTickTimestamp = now

        // 平滑防抖校正：比較實測播放時間與時鐘線性推估值的差值
        let predictedTime = anchorPlaybackTimeSec + (isPlaying ? max(0, now - anchorMediaTime) : 0)
        let drift = abs(playTime - predictedTime)

        // 若誤差超過 600ms（發生手動拖曳跳轉或暫停），立即重設基準錨點；否則維持平滑推進
        if drift >= 0.60 || anchorMediaTime == 0 || !isPlaying {
            anchorPlaybackTimeSec = playTime
            anchorMediaTime = now
        }

        if currentTrack.duration > 0 {
            playbackProgress = min(max(playTime / currentTrack.duration, 0.0), 1.0)
            if PiPLyricsEngine.shared.isPiPActive {
                PiPLyricsViewModel.shared.progress = playbackProgress
            }
        }

        let timeMs = Int(playTime * 1000)
        let newIndex = currentLyrics.currentLineIndex(at: timeMs, globalOffsetMs: globalOffsetMs)

        if newIndex != currentLineIndex {
            currentLineIndex = newIndex
        }
    }

    /// 取得高精度插值播放時間（毫秒，結合平滑防抖時鐘與微秒級幀間差）
    public func interpolatedPlaybackTimeMs() -> Int {
        let elapsed = isPlaying ? max(0, CACurrentMediaTime() - anchorMediaTime) : 0
        let timeSec = anchorPlaybackTimeSec + elapsed
        return Int(timeSec * 1000) + globalOffsetMs
    }

    // MARK: - 調整全域共用之時間軸微調偏移量
    public func adjustGlobalOffset(byMs: Int) {
        globalOffsetMs += byMs
        let timeMs = Int(currentPlaybackTimeSec * 1000)
        currentLineIndex = currentLyrics.currentLineIndex(at: timeMs, globalOffsetMs: globalOffsetMs)
    }

    public func resetGlobalOffset() {
        globalOffsetMs = 0
        let timeMs = Int(currentPlaybackTimeSec * 1000)
        currentLineIndex = currentLyrics.currentLineIndex(at: timeMs, globalOffsetMs: globalOffsetMs)
    }

    // MARK: - 手動套用自訂歌詞
    public func applyCustomLyrics(_ lyrics: SyncedLyrics) {
        currentLyrics = lyrics
        let timeMs = Int(currentPlaybackTimeSec * 1000)
        currentLineIndex = currentLyrics.currentLineIndex(at: timeMs, globalOffsetMs: globalOffsetMs)
    }
}
