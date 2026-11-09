import Foundation

/// Basic track metadata.
public struct TrackInfo: Codable, Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var duration: TimeInterval
    public var artworkData: Data?
    public var genre: String

    public init(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        artworkData: Data? = nil,
        genre: String = ""
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artworkData = artworkData
        self.genre = genre
    }

    enum CodingKeys: String, CodingKey {
        case title, artist, album, duration, artworkData, genre
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try container.decode(String.self, forKey: .title)
        self.artist = try container.decode(String.self, forKey: .artist)
        self.album = try container.decode(String.self, forKey: .album)
        self.duration = try container.decode(TimeInterval.self, forKey: .duration)
        self.artworkData = try container.decodeIfPresent(Data.self, forKey: .artworkData)
        self.genre = try container.decodeIfPresent(String.self, forKey: .genre) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(artist, forKey: .artist)
        try container.encode(album, forKey: .album)
        try container.encode(duration, forKey: .duration)
        try container.encodeIfPresent(artworkData, forKey: .artworkData)
        try container.encode(genre, forKey: .genre)
    }

    public static let placeholder = TrackInfo(
        title: String(localized: "尚未播放音樂"),
        artist: String(localized: "請在 Apple Music 播放歌曲"),
        album: "AuraLyrics",
        duration: 0,
        genre: ""
    )
}

/// Syllable-level timing metadata for synchronized karaoke text.
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

/// Single-line timed lyric model.
public struct LyricLine: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    /// Line start timestamp in milliseconds.
    public var timeMs: Int
    /// Original lyric text.
    public var text: String
    /// Translated lyric text, or nil if unavailable.
    public var translation: String?
    /// Word or syllable timing data when available.
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

/// Synchronized lyrics container with metadata.
public struct SyncedLyrics: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(trackTitle)-\(artistName)-\(source)-\(lines.count)-\(lines.first?.timeMs ?? 0)-\(lines.last?.timeMs ?? 0)-\(hasSyllables ? "ws" : "ls")" }
    public var trackTitle: String
    public var artistName: String
    public var lines: [LyricLine]
    /// Songwriter and production credits.
    public var credits: [String]
    /// Manual timing offset in milliseconds (positive advances lyrics, negative delays).
    public var offsetMs: Int
    /// Lyric provider source identifier (e.g. "LRCLIB", "NetEase", "Local").
    public var source: String
    /// Target language code for translation (e.g. "zh-Hant", "en", "ja").
    public var translationTargetLanguage: String?

    public init(
        trackTitle: String,
        artistName: String,
        lines: [LyricLine],
        credits: [String] = [],
        offsetMs: Int = 0,
        source: String = "Unknown",
        translationTargetLanguage: String? = nil
    ) {
        self.trackTitle = trackTitle
        self.artistName = artistName
        self.lines = lines
        self.credits = credits
        self.offsetMs = offsetMs
        self.source = source
        self.translationTargetLanguage = translationTargetLanguage
    }

    enum CodingKeys: String, CodingKey {
        case trackTitle, artistName, lines, credits, offsetMs, source, translationTargetLanguage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.trackTitle = try container.decode(String.self, forKey: .trackTitle)
        self.artistName = try container.decode(String.self, forKey: .artistName)
        self.lines = try container.decode([LyricLine].self, forKey: .lines)
        self.credits = try container.decodeIfPresent([String].self, forKey: .credits) ?? []
        self.offsetMs = try container.decode(Int.self, forKey: .offsetMs)
        self.source = try container.decode(String.self, forKey: .source)
        self.translationTargetLanguage = try container.decodeIfPresent(String.self, forKey: .translationTargetLanguage)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(trackTitle, forKey: .trackTitle)
        try container.encode(artistName, forKey: .artistName)
        try container.encode(lines, forKey: .lines)
        try container.encode(credits, forKey: .credits)
        try container.encode(offsetMs, forKey: .offsetMs)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(translationTargetLanguage, forKey: .translationTargetLanguage)
    }

    public static let empty = SyncedLyrics(
        trackTitle: "",
        artistName: "",
        lines: [],
        credits: [],
        offsetMs: 0,
        source: "None"
    )

    /// Indicates whether syllable-level timing data is present.
    public var hasSyllables: Bool {
        lines.contains { line in
            if let syllables = line.syllables, !syllables.isEmpty {
                return true
            }
            return false
        }
    }

    /// Indicates whether valid translation text is present.
    public var hasTranslation: Bool {
        lines.contains { line in
            if let trans = line.translation, !trans.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            return false
        }
    }

    /// Computes active lyric line index for given playback timestamp and offset.
    public func currentLineIndex(at currentPlaybackTimeMs: Int, globalOffsetMs: Int = 0) -> Int? {
        guard !lines.isEmpty else { return nil }
        let adjustedTime = currentPlaybackTimeMs + globalOffsetMs + offsetMs

        // Check if playback position is prior to the first lyric line.
        if adjustedTime < lines[0].timeMs {
            return nil
        }

        // Binary search for the line with maximum start time <= adjustedTime.
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

/// Lyrics display engine mode.
public enum DisplayEngineMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic = "auto"
    case pipCapsule = "pip"
    case liveActivity = "dynamicIsland"
    case both = "both"

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .automatic: return String(localized: "自動選擇（依環境推薦）")
        case .pipCapsule: return String(localized: "子母畫面 (PiP) 懸浮膠囊")
        case .liveActivity: return String(localized: "原生動態島 / 即時動態")
        case .both: return String(localized: "雙模式並行")
        }
    }
}

/// Lyrics provider source platform.
public enum LyricsSource: String, CaseIterable, Identifiable, Codable, Sendable {
    case musixmatch = "Musixmatch"
    case netease = "NetEase"
    case lrclib = "LRCLIB"
    case petitlyrics = "PetitLyrics"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .musixmatch: return "Musixmatch"
        case .netease: return String(localized: "網易雲音樂 (NetEase)")
        case .lrclib: return "LRCLIB"
        case .petitlyrics: return "PetitLyrics"
        }
    }
}

/// Language profile for provider search priority ordering.
public enum LyricsLanguageProfile: String, CaseIterable, Identifiable, Codable, Sendable {
    case western = "western"
    case asian = "asian"
    case japanese = "japanese"

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .western: return String(localized: "歐美 / 預設")
        case .asian: return String(localized: "華語 / 亞洲")
        case .japanese: return String(localized: "日語")
        }
    }
}

/// Provider search priority item differentiating platform and sync granularity.
public struct LyricsSearchPriorityItem: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var source: LyricsSource
    public var isWordSync: Bool
    public var isEnabled: Bool

    public init(id: String, source: LyricsSource, isWordSync: Bool, isEnabled: Bool = true) {
        self.id = id
        self.source = source
        self.isWordSync = isWordSync
        self.isEnabled = isEnabled
    }

    public var title: String {
        source.displayName
    }

    public var subtitle: String {
        if isWordSync {
            switch source {
            case .musixmatch:
                return String(localized: "逐字時間軸 (Richsync)")
            case .netease:
                return String(localized: "逐字時間軸 (YRC/KRC)")
            case .lrclib:
                return String(localized: "逐字時間軸 (Enhanced LRC)")
            case .petitlyrics:
                return String(localized: "逐字時間軸 (WSY)")
            }
        } else {
            return String(localized: "普通逐行時間軸 (LRC)")
        }
    }

    public var icon: String {
        switch source {
        case .musixmatch:
            return "waveform.badge.mic"
        case .netease:
            return "cloud.fill"
        case .lrclib:
            return "music.note.list"
        case .petitlyrics:
            return "sparkles.rectangle.stack"
        }
    }

    public static func defaultList(for profile: LyricsLanguageProfile) -> [LyricsSearchPriorityItem] {
        switch profile {
        case .japanese:
            return [
                LyricsSearchPriorityItem(id: "petitlyrics_word", source: .petitlyrics, isWordSync: true, isEnabled: true),
                LyricsSearchPriorityItem(id: "netease_word", source: .netease, isWordSync: true, isEnabled: true),
                LyricsSearchPriorityItem(id: "lrclib_word", source: .lrclib, isWordSync: true, isEnabled: true),
                LyricsSearchPriorityItem(id: "musixmatch_word", source: .musixmatch, isWordSync: true, isEnabled: true),
                LyricsSearchPriorityItem(id: "petitlyrics_line", source: .petitlyrics, isWordSync: false, isEnabled: true),
                LyricsSearchPriorityItem(id: "netease_line", source: .netease, isWordSync: false, isEnabled: true),
                LyricsSearchPriorityItem(id: "lrclib_line", source: .lrclib, isWordSync: false, isEnabled: true),
                LyricsSearchPriorityItem(id: "musixmatch_line", source: .musixmatch, isWordSync: false, isEnabled: true)
            ]
        case .asian:
            return [
                LyricsSearchPriorityItem(id: "netease_word", source: .netease, isWordSync: true, isEnabled: true),
                LyricsSearchPriorityItem(id: "petitlyrics_word", source: .petitlyrics, isWordSync: true, isEnabled: true),
                LyricsSearchPriorityItem(id: "lrclib_word", source: .lrclib, isWordSync: true, isEnabled: true),
                LyricsSearchPriorityItem(id: "musixmatch_word", source: .musixmatch, isWordSync: true, isEnabled: true),
                LyricsSearchPriorityItem(id: "netease_line", source: .netease, isWordSync: false, isEnabled: true),
                LyricsSearchPriorityItem(id: "petitlyrics_line", source: .petitlyrics, isWordSync: false, isEnabled: true),
                LyricsSearchPriorityItem(id: "lrclib_line", source: .lrclib, isWordSync: false, isEnabled: true),
                LyricsSearchPriorityItem(id: "musixmatch_line", source: .musixmatch, isWordSync: false, isEnabled: true)
            ]
        case .western:
            return [
                LyricsSearchPriorityItem(id: "netease_word", source: .netease, isWordSync: true, isEnabled: true),
                LyricsSearchPriorityItem(id: "petitlyrics_word", source: .petitlyrics, isWordSync: true, isEnabled: true),
                LyricsSearchPriorityItem(id: "lrclib_word", source: .lrclib, isWordSync: true, isEnabled: true),
                LyricsSearchPriorityItem(id: "musixmatch_word", source: .musixmatch, isWordSync: true, isEnabled: true),
                LyricsSearchPriorityItem(id: "netease_line", source: .netease, isWordSync: false, isEnabled: true),
                LyricsSearchPriorityItem(id: "petitlyrics_line", source: .petitlyrics, isWordSync: false, isEnabled: true),
                LyricsSearchPriorityItem(id: "lrclib_line", source: .lrclib, isWordSync: false, isEnabled: true),
                LyricsSearchPriorityItem(id: "musixmatch_line", source: .musixmatch, isWordSync: false, isEnabled: true)
            ]
        }
    }

    public static let defaultList: [LyricsSearchPriorityItem] = defaultList(for: .western)
}

/// Picture-in-Picture floating capsule visual theme.
public enum PiPVisualTheme: String, CaseIterable, Identifiable, Codable, Sendable {
    case dynamicIsland = "dynamicIsland"
    case standardCard = "standardCard"
    case minimalLine = "minimalLine"

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .dynamicIsland: return String(localized: "動態島膠囊風（深黑圓角 + 頂部吸附感）")
        case .standardCard: return String(localized: "標準雙行卡片（原文＋雙語翻譯）")
        case .minimalLine: return String(localized: "極簡單行（高對比精緻小窗）")
        }
    }
}
