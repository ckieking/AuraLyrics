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
    @Published public private(set) var isLoadingLyrics: Bool = false

    private let musicPlayer = MPMusicPlayerController.systemMusicPlayer
    private var timer: Timer?

    private init() {
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
        isPlaying = (musicPlayer.playbackState == .playing)
    }

    // MARK: - 時間軸定時器循環
    private func tick() {
        let playTime = musicPlayer.currentPlaybackTime
        currentPlaybackTimeSec = playTime

        if currentTrack.duration > 0 {
            playbackProgress = min(max(playTime / currentTrack.duration, 0.0), 1.0)
        }

        let timeMs = Int(playTime * 1000)
        let newIndex = currentLyrics.currentLineIndex(at: timeMs)

        if newIndex != currentLineIndex {
            currentLineIndex = newIndex
        }
    }

    // MARK: - 調整時間軸微調偏移量
    public func adjustOffset(byMs: Int) {
        let newOffset = currentLyrics.offsetMs + byMs
        currentLyrics = LyricsProviderService.shared.updateOffset(
            title: currentTrack.title,
            artist: currentTrack.artist,
            newOffsetMs: newOffset,
            currentLyrics: currentLyrics
        )
        // 立即重新計算索引
        let timeMs = Int(currentPlaybackTimeSec * 1000)
        currentLineIndex = currentLyrics.currentLineIndex(at: timeMs)
    }

    // MARK: - 手動套用自訂歌詞
    public func applyCustomLyrics(_ lyrics: SyncedLyrics) {
        currentLyrics = lyrics
        let timeMs = Int(currentPlaybackTimeSec * 1000)
        currentLineIndex = currentLyrics.currentLineIndex(at: timeMs)
    }
}
