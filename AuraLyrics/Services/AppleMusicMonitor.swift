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
    @Published public private(set) var playbackProgress: Double = 0.0
    @Published public private(set) var currentPlaybackTimeSec: TimeInterval = 0.0
    @Published public private(set) var lastTickTimestamp: CFTimeInterval = CACurrentMediaTime()
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

    private init() {
        self.globalOffsetMs = UserDefaults.standard.integer(forKey: "globalLyricsOffsetMs")
        setupNotifications()
    }

    // MARK: - 系統通知設定
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
    }

    // MARK: - 啟動監聽與高精度時間軸定時器
    public func startMonitoring() {
        handleTrackChanged()
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
    }

    // MARK: - 曲目變更處理
    private func handleTrackChanged() {
        guard let nowPlaying = musicPlayer.nowPlayingItem else {
            currentTrack = .placeholder
            currentLyrics = .empty
            currentLineIndex = nil
            playbackProgress = 0.0
            anchorPlaybackTimeSec = 0
            anchorMediaTime = 0
            return
        }

        let title = nowPlaying.title ?? "未知曲目"
        let artist = nowPlaying.artist ?? "未知歌手"
        let album = nowPlaying.albumTitle ?? ""
        let duration = nowPlaying.playbackDuration

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

        currentTrack = newTrack
        currentLineIndex = nil
        playbackProgress = 0.0

        let playTime = musicPlayer.currentPlaybackTime
        currentPlaybackTimeSec = playTime
        anchorPlaybackTimeSec = playTime
        anchorMediaTime = CACurrentMediaTime()

        // 載入歌詞
        Task {
            isLoadingLyrics = true
            if let fetched = await LyricsProviderService.shared.fetchLyrics(track: newTrack) {
                currentLyrics = fetched
            } else {
                currentLyrics = SyncedLyrics.empty
            }
            isLoadingLyrics = false
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
        // 即時檢查當前播放曲目是否已換歌（增強換歌偵測）
        if let nowPlaying = musicPlayer.nowPlayingItem {
            let title = nowPlaying.title ?? ""
            let artist = nowPlaying.artist ?? ""
            if !title.isEmpty && (title != currentTrack.title || artist != currentTrack.artist) {
                handleTrackChanged()
                return
            }
        }

        let playTime = musicPlayer.currentPlaybackTime
        currentPlaybackTimeSec = playTime
        let now = CACurrentMediaTime()
        lastTickTimestamp = now

        // 平滑防抖校正：比較實測播放時間與時鐘線性推估值的差值
        let predictedTime = anchorPlaybackTimeSec + (isPlaying ? max(0, now - anchorMediaTime) : 0)
        let drift = abs(playTime - predictedTime)

        // 若誤差超過 120ms（發生拖曳跳轉或暫停），立即重設基準錨點；否則維持平滑推進
        if drift >= 0.12 || anchorMediaTime == 0 || !isPlaying {
            anchorPlaybackTimeSec = playTime
            anchorMediaTime = now
        }

        if currentTrack.duration > 0 {
            playbackProgress = min(max(playTime / currentTrack.duration, 0.0), 1.0)
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
