import Foundation

/// 動態島緊湊視圖顯示樣式
public enum DynamicIslandCompactStyle: String, CaseIterable, Identifiable, Codable {
    case artworkAndText = "artworkAndText"
    case iconAndText = "iconAndText"
    case textOnly = "textOnly"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .artworkAndText:
            return "專輯封面 + 當前歌詞 (預設)"
        case .iconAndText:
            return "音符圖示 + 當前歌詞"
        case .textOnly:
            return "僅當前歌詞"
        }
    }

    public var description: String {
        switch self {
        case .artworkAndText:
            return "左側展示微縮專輯封面，右側隨歌曲平滑滾動當前播放歌詞。"
        case .iconAndText:
            return "左側展示簡約音樂圖示，右側顯示當前歌詞。"
        case .textOnly:
            return "動態島兩側均最大化空間呈現歌詞文字。"
        }
    }
}

/// 音樂暫停時即時動態與動態島之保留策略
public enum LiveActivityPausePolicy: String, CaseIterable, Identifiable, Codable {
    case dismissImmediately = "dismissImmediately"
    case keepActiveWithTimeout = "keepActiveWithTimeout"
    case keepActiveAlways = "keepActiveAlways"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dismissImmediately:
            return "音樂暫停時立即收起 (預設)"
        case .keepActiveWithTimeout:
            return "保留 5 分鐘後自動關閉"
        case .keepActiveAlways:
            return "持續保留直至手動關閉"
        }
    }

    public var description: String {
        switch self {
        case .dismissImmediately:
            return "音樂暫停時立即結束即時動態，恢復播放時自動重新開啟。"
        case .keepActiveWithTimeout:
            return "暫停時維持最後歌詞顯示，逾時 5 分鐘後自動收起清理。"
        case .keepActiveAlways:
            return "暫停時維持最後歌詞，隨時等待繼續播放。"
        }
    }
}

/// 音樂恢復播放時的即時動態重啟策略
public enum LiveActivityResumePolicy: String, CaseIterable, Identifiable, Codable {
    case autoResume = "autoResume"
    case manualOnly = "manualOnly"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .autoResume:
            return "繼續播放時自動重新啟動 (預設)"
        case .manualOnly:
            return "僅由使用者手動開啟"
        }
    }
}

/// 即時動態與動態島副行資訊顯示模式
public enum LiveActivitySecondaryMode: String, CaseIterable, Identifiable, Codable {
    case bilingualOrNext = "bilingualOrNext"
    case bilingualOnly = "bilingualOnly"
    case nextOnly = "nextOnly"
    case none = "none"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .bilingualOrNext:
            return "雙語翻譯優先，無翻譯則顯示下一句 (預設)"
        case .bilingualOnly:
            return "僅顯示雙語翻譯"
        case .nextOnly:
            return "僅顯示下一句歌詞預覽"
        case .none:
            return "不顯示副行"
        }
    }
}
