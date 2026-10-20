import ActivityKit
import Foundation

/// AuraLyrics 的即時動態與動態島資料屬性
public struct LyricsActivityAttributes: ActivityAttributes {
    /// 動態更新的狀態資料（每當歌詞行切換時傳遞）
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
        /// 當前曲目播放進度（0.0 ~ 1.0）
        public var progress: Double
        /// 共享群組內的專輯封面縮圖路徑
        public var artworkPath: String?
        /// 緊湊樣式設定
        public var compactStyle: String

        public init(
            currentLine: String,
            secondaryLine: String? = nil,
            trackTitle: String,
            artistName: String,
            isPlaying: Bool = true,
            progress: Double = 0.0,
            artworkPath: String? = nil,
            compactStyle: String = DynamicIslandCompactStyle.artworkAndText.rawValue
        ) {
            self.currentLine = currentLine
            self.secondaryLine = secondaryLine
            self.trackTitle = trackTitle
            self.artistName = artistName
            self.isPlaying = isPlaying
            self.progress = progress
            self.artworkPath = artworkPath
            self.compactStyle = compactStyle
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
