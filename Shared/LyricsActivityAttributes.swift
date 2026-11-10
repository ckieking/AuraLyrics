import ActivityKit
import Foundation

/// ActivityKit attributes for lyrics Live Activity and Dynamic Island.
public struct LyricsActivityAttributes: ActivityAttributes {
    /// Dynamic state payload pushed on each lyrics line update.
    public struct ContentState: Codable, Hashable, Sendable {
        /// Primary current lyrics line text.
        public var currentLine: String
        /// Secondary row text (translation or next line preview).
        public var secondaryLine: String?
        /// Track title.
        public var trackTitle: String
        /// Artist name.
        public var artistName: String
        /// Playback state indicator.
        public var isPlaying: Bool
        /// Current playback progress (0.0 to 1.0).
        public var progress: Double
        /// App Group relative path to cached artwork thumbnail.
        public var artworkPath: String?
        /// In-memory compressed JPEG thumbnail data for cross-sandbox fallback rendering.
        public var artworkData: Data?
        /// Dynamic Island compact presentation style key.
        public var compactStyle: String
        /// Indicates whether system appearance is in light mode.
        public var isLightMode: Bool

        public init(
            currentLine: String,
            secondaryLine: String? = nil,
            trackTitle: String,
            artistName: String,
            isPlaying: Bool = true,
            progress: Double = 0.0,
            artworkPath: String? = nil,
            artworkData: Data? = nil,
            compactStyle: String = DynamicIslandCompactStyle.artworkAndText.rawValue,
            isLightMode: Bool = false
        ) {
            self.currentLine = currentLine
            self.secondaryLine = secondaryLine
            self.trackTitle = trackTitle
            self.artistName = artistName
            self.isPlaying = isPlaying
            self.progress = progress
            self.artworkPath = artworkPath
            self.artworkData = artworkData
            self.compactStyle = compactStyle
            self.isLightMode = isLightMode
        }
    }

    /// Static attributes specified upon activity creation.
    public var albumTitle: String
    public var totalDurationSec: Double

    public init(albumTitle: String, totalDurationSec: Double = 0) {
        self.albumTitle = albumTitle
        self.totalDurationSec = totalDurationSec
    }
}
