import Foundation

/// 動態島緊湊模式樣式
public enum DynamicIslandCompactStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case artworkAndText = "artworkAndText"
    case iconAndText = "iconAndText"
    case minimalWaveform = "minimalWaveform"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .artworkAndText:
            return "專輯縮圖與歌詞"
        case .iconAndText:
            return "音符圖示與歌詞"
        case .minimalWaveform:
            return "極簡動態頻譜"
        }
    }

    public var description: String {
        switch self {
        case .artworkAndText:
            return "Leading 顯示歌曲專輯圓角封面縮圖，Trailing 顯示當前歌詞文字"
        case .iconAndText:
            return "Leading 顯示粉色音符圖示，Trailing 顯示當前歌詞文字"
        case .minimalWaveform:
            return "僅呈現精緻頻譜波形，點擊或長按展開時才閱讀歌詞"
        }
    }
}

/// 音樂暫停時的即時動態處理機制
public enum LiveActivityPausePolicy: String, CaseIterable, Identifiable, Codable, Sendable {
    case dismissImmediately = "dismissImmediately"
    case keepActiveWithTimeout = "keepActiveWithTimeout"
    case keepActiveAlways = "keepActiveAlways"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dismissImmediately:
            return "暫停時立即關閉"
        case .keepActiveWithTimeout:
            return "維持顯示 (5 分鐘後逾時結束)"
        case .keepActiveAlways:
            return "持續長駐顯示已暫停"
        }
    }

    public var description: String {
        switch self {
        case .dismissImmediately:
            return "在系統中按下暫停時，立即收回動態島與即時動態，最省電且不干擾"
        case .keepActiveWithTimeout:
            return "暫停時膠囊保持顯示暫停圖示，超過 5 分鐘未繼續播放則自動清理"
        case .keepActiveAlways:
            return "暫停時維持膠囊常駐，直到手動關閉或更換 App"
        }
    }
}

/// 暫停後恢復播放時的行為策略
public enum LiveActivityResumePolicy: String, CaseIterable, Identifiable, Codable, Sendable {
    case autoResume = "autoResume"
    case manual = "manual"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .autoResume:
            return "自動重新啟動"
        case .manual:
            return "保持關閉 (需手動重開)"
        }
    }

    public var description: String {
        switch self {
        case .autoResume:
            return "只要功能開關保持啟用，音樂恢復播放時自動重啟動態島同步"
        case .manual:
            return "暫停關閉後將開關關閉，下次需要時再手動於選單啟動"
        }
    }
}

/// 次要行（雙語/下一句）顯示模式
public enum LiveActivitySecondaryMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case bilingualOrNext = "bilingualOrNext"
    case bilingualOnly = "bilingualOnly"
    case nextOnly = "nextOnly"
    case none = "none"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .bilingualOrNext:
            return "雙語優先 / 次句預覽"
        case .bilingualOnly:
            return "僅雙語翻譯"
        case .nextOnly:
            return "僅下一句預覽"
        case .none:
            return "隱藏次要行"
        }
    }

    public var description: String {
        switch self {
        case .bilingualOrNext:
            return "有翻譯時顯示雙語，無翻譯時預覽下一句歌詞"
        case .bilingualOnly:
            return "只在有雙語翻譯時顯示副行，無翻譯時留空"
        case .nextOnly:
            return "固定預覽即將到來的下一句歌詞"
        case .none:
            return "僅專注顯示當前播放行，排版最簡潔"
        }
    }
}

/// 進度條推進驅動引擎
public enum LiveActivityProgressEngine: String, CaseIterable, Identifiable, Codable, Sendable {
    case smoothTimer = "smoothTimer"
    case lineStep = "lineStep"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .smoothTimer:
            return "系統 60fps 原生平滑計時器"
        case .lineStep:
            return "換行步進模式"
        }
    }

    public var description: String {
        switch self {
        case .smoothTimer:
            return "利用 iOS ActivityKit 原生計時器在動態島以 60fps 平滑推進，零 IPC 與電量開銷"
        case .lineStep:
            return "僅在歌詞切換時更新進度點，保持進度條與歌詞完全對齊"
        }
    }
}
