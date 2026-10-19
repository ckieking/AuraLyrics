import Foundation

/// 歌曲基本資訊
public struct TrackInfo: Codable, Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var duration: TimeInterval
    public var artworkData: Data?

    public init(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        artworkData: Data? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artworkData = artworkData
    }

    public static let placeholder = TrackInfo(
        title: "尚未播放音樂",
        artist: "請在 Apple Music 播放歌曲",
        album: "AuraLyrics",
        duration: 0
    )
}

/// 單字/音節時間軸（支援 Apple Music 逐字卡拉OK播放）
public struct LyricSyllable: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var text: String
    public var timeMs: Int
    public var durationMs: Int

    public init(
        id: UUID = UUID(),
        text: String,
        timeMs: Int,
        durationMs: Int = 0
    ) {
        self.id = id
        self.text = text
        self.timeMs = timeMs
        self.durationMs = durationMs
    }
}

/// 單行時間軸歌詞
public struct LyricLine: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    /// 歌詞開始時間（毫秒）
    public var timeMs: Int
    /// 原文歌詞
    public var text: String
    /// 翻譯歌詞（若無則為 nil）
    public var translation: String?
    /// 逐字音節時間軸（若有 Enhanced LRC 逐字資料）
    public var syllables: [LyricSyllable]?

    public init(
        id: UUID = UUID(),
        timeMs: Int,
        text: String,
        translation: String? = nil,
        syllables: [LyricSyllable]? = nil
    ) {
        self.id = id
        self.timeMs = timeMs
        self.text = text
        self.translation = translation
        self.syllables = syllables
    }
}

/// 完整同步歌詞集合與相關元資料
public struct SyncedLyrics: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(trackTitle)-\(artistName)-\(source)" }
    public var trackTitle: String
    public var artistName: String
    public var lines: [LyricLine]
    /// 參與人員與創作團隊名單（如 Written by ..., Produced by ...）
    public var credits: [String]
    /// 時間軸微調偏移量（毫秒，正值代表歌詞提前、負值代表延後）
    public var offsetMs: Int
    /// 來源標記（如 "LRCLIB" 或 "NetEase" 或 "Local"）
    public var source: String

    public init(
        trackTitle: String,
        artistName: String,
        lines: [LyricLine],
        credits: [String] = [],
        offsetMs: Int = 0,
        source: String = "Unknown"
    ) {
        self.trackTitle = trackTitle
        self.artistName = artistName
        self.lines = lines
        self.credits = credits
        self.offsetMs = offsetMs
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case trackTitle, artistName, lines, credits, offsetMs, source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.trackTitle = try container.decode(String.self, forKey: .trackTitle)
        self.artistName = try container.decode(String.self, forKey: .artistName)
        self.lines = try container.decode([LyricLine].self, forKey: .lines)
        self.credits = try container.decodeIfPresent([String].self, forKey: .credits) ?? []
        self.offsetMs = try container.decode(Int.self, forKey: .offsetMs)
        self.source = try container.decode(String.self, forKey: .source)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(trackTitle, forKey: .trackTitle)
        try container.encode(artistName, forKey: .artistName)
        try container.encode(lines, forKey: .lines)
        try container.encode(credits, forKey: .credits)
        try container.encode(offsetMs, forKey: .offsetMs)
        try container.encode(source, forKey: .source)
    }

    public static let empty = SyncedLyrics(
        trackTitle: "",
        artistName: "",
        lines: [],
        credits: [],
        offsetMs: 0,
        source: "None"
    )

    /// 是否包含逐字音節時間軸資料
    public var hasSyllables: Bool {
        lines.contains { line in
            if let syllables = line.syllables, !syllables.isEmpty {
                return true
            }
            return false
        }
    }

    /// 根據當前播放時間（毫秒）與全域微調偏移量，取得當前正在唱的歌詞行索引
    public func currentLineIndex(at currentPlaybackTimeMs: Int, globalOffsetMs: Int = 0) -> Int? {
        guard !lines.isEmpty else { return nil }
        let adjustedTime = currentPlaybackTimeMs + globalOffsetMs + offsetMs

        // 若尚未到達第一句歌詞時間
        if adjustedTime < lines[0].timeMs {
            return nil
        }

        // 二分搜尋尋找最大 <= adjustedTime 的歌詞行
        var low = 0
        var high = lines.count - 1
        var resultIndex = 0

        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].timeMs <= adjustedTime {
                resultIndex = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return resultIndex
    }
}

/// 顯示引擎模式
public enum DisplayEngineMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic = "auto"
    case pipCapsule = "pip"
    case liveActivity = "dynamicIsland"
    case both = "both"

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .automatic: return "自動選擇（依環境推薦）"
        case .pipCapsule: return "PiP 畫中畫懸浮膠囊"
        case .liveActivity: return "原生動態島 / 即時動態"
        case .both: return "雙模式並行"
        }
    }
}

/// PiP 懸浮窗樣式風格
public enum PiPVisualTheme: String, CaseIterable, Identifiable, Codable, Sendable {
    case dynamicIsland = "dynamicIsland"
    case standardCard = "standardCard"
    case minimalLine = "minimalLine"

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .dynamicIsland: return "動態島膠囊風（深黑圓角 + 頂部吸附感）"
        case .standardCard: return "標準雙行卡片（原文＋雙語翻譯）"
        case .minimalLine: return "極簡單行（高對比精緻小窗）"
        }
    }
}
