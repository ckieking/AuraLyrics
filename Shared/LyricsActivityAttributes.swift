import ActivityKit
import Foundation

/// AuraLyrics 的即時動態與動態島資料屬性
public struct LyricsActivityAttributes: ActivityAttributes {
    /// 動態更新的狀態資料（每當歌詞行切換或播放狀態變動時傳遞）
    public struct ContentState: Codable, Hashable, Sendable {
        /// 當前播放行主歌詞
        public var currentLine: String
        /// 次要行（雙語翻譯或下一句歌詞預覽）
        public var secondaryLine: String?
        /// 歌曲名稱
        public var trackTitle: String
        /// 歌手名稱
        public var artistName: String
        /// 播放中狀態
        public var isPlaying: Bool
        /// 當前曲目播放進度（0.0 ~ 1.0，備用靜態數值）
        public var progress: Double
        /// 共享封面縮圖檔案路徑（存於共享 App Group / 沙盒目錄，避免 4KB payload 超限）
        public var artworkPath: String?
        /// 播放區間起點（供 ProgressView 原生平滑計時器使用）
        public var playbackStart: Date
        /// 播放區間終點（供 ProgressView 原生平滑計時器使用）
        public var playbackEnd: Date
        /// 動態島緊湊模式樣式標籤 (對應 DynamicIslandCompactStyle.rawValue)
        public var compactStyle: String
        /// 進度條驅動引擎 (對應 LiveActivityProgressEngine.rawValue)
        public var progressEngine: String

        public init(
            currentLine: String,
            secondaryLine: String? = nil,
            trackTitle: String,
            artistName: String,
            isPlaying: Bool = true,
            progress: Double = 0.0,
            artworkPath: String? = nil,
            playbackStart: Date = Date(),
            playbackEnd: Date = Date().addingTimeInterval(1),
            compactStyle: String = DynamicIslandCompactStyle.artworkAndText.rawValue,
            progressEngine: String = LiveActivityProgressEngine.smoothTimer.rawValue
        ) {
            self.currentLine = currentLine
            self.secondaryLine = secondaryLine
            self.trackTitle = trackTitle
            self.artistName = artistName
            self.isPlaying = isPlaying
            self.progress = progress
            self.artworkPath = artworkPath
            self.playbackStart = playbackStart
            self.playbackEnd = playbackEnd
            self.compactStyle = compactStyle
            self.progressEngine = progressEngine
        }
    }

    /// 靜態屬性（建立 Live Activity 時指定）
    public var albumTitle: String
    public var totalDurationSec: Double

    public init(albumTitle: String, totalDurationSec: Double = 0) {
        self.albumTitle = albumTitle
        self.totalDurationSec = totalDurationSec
    }
}
