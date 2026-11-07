import Foundation
import Translation
import NaturalLanguage

/// 翻譯目標語言選項模型
public struct TranslationTargetLanguageItem: Identifiable, Hashable, Sendable {
    public var id: String { identifier }
    public let identifier: String
    public let displayName: String
    public let localeLanguage: Locale.Language

    public init(identifier: String, displayName: String, localeLanguage: Locale.Language) {
        self.identifier = identifier
        self.displayName = displayName
        self.localeLanguage = localeLanguage
    }
}

/// 歌詞離線翻譯與繁簡轉換服務（支援 iOS 原生 Translation 框架與本機 NLP 語意判別）
@MainActor
public final class LyricsTranslationService: ObservableObject {
    public static let shared = LyricsTranslationService()

    /// UserDefaults key
    public static let targetLanguageKey = "lyricsTranslationTargetLanguage"
    public static let defaultTargetLanguage = "zh-Hant"

    /// 目標翻譯語言（BCP-47 代碼，如 zh-Hant, en, ja）
    @Published public var currentTargetLanguage: String {
        didSet {
            UserDefaults.standard.set(currentTargetLanguage, forKey: Self.targetLanguageKey)
        }
    }

    /// 動態快取之 iOS 支援翻譯語言清單（排序：系統語言第一、App 語言第二、其餘依語系排序）
    @Published public private(set) var availableLanguages: [TranslationTargetLanguageItem] = []

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.targetLanguageKey)
        self.currentTargetLanguage = saved?.isEmpty == false ? saved! : Self.defaultTargetLanguage
        refreshAvailableLanguages()
    }

    // MARK: - 動態取得並排序 iOS 支援的所有翻譯語言
    public func refreshAvailableLanguages() {
        Task {
            let availability = LanguageAvailability()
            let supported = await availability.supportedLanguages

            // 若系統未回傳（例如模擬器離線環境），提供常用備援語系
            let languagesToProcess: [Locale.Language]
            if !supported.isEmpty {
                languagesToProcess = supported
            } else {
                let fallbackCodes = ["zh-Hant", "zh-Hans", "en", "ja", "ko", "es", "fr", "de", "it", "pt"]
                languagesToProcess = fallbackCodes.map { Locale.Language(identifier: $0) }
            }

            // 1. 取得系統首選語言
            let systemPreferredLangCode = Locale.preferredLanguages.first ?? "zh-Hant"
            let systemLocaleLang = Locale.Language(identifier: systemPreferredLangCode)

            // 2. 取得 App 當前語言
            let appLangCode = Bundle.main.preferredLocalizations.first ?? "zh-Hant"
            let appLocaleLang = Locale.Language(identifier: appLangCode)

            // 轉換為 Item 並去重
            var itemsMap: [String: TranslationTargetLanguageItem] = [:]
            let currentLocale = Locale.current

            for lang in languagesToProcess {
                let id = lang.minimalIdentifier
                let name = currentLocale.localizedString(forIdentifier: id) ?? id
                let capitalizedName = name.prefix(1).uppercased() + name.dropFirst()
                itemsMap[id] = TranslationTargetLanguageItem(
                    identifier: id,
                    displayName: capitalizedName,
                    localeLanguage: lang
                )
            }

            var sortedItems: [TranslationTargetLanguageItem] = []
            var usedIds = Set<String>()

            // 找到與系統語言匹配的 item（第一順位）
            let systemMatched = itemsMap.values.first { item in
                item.localeLanguage.languageCode == systemLocaleLang.languageCode &&
                (item.localeLanguage.script == nil || item.localeLanguage.script == systemLocaleLang.script)
            } ?? itemsMap.values.first { item in
                item.localeLanguage.languageCode == systemLocaleLang.languageCode
            }

            if let sys = systemMatched {
                sortedItems.append(sys)
                usedIds.insert(sys.identifier)
            }

            // 找到與 App 語言匹配的 item（第二順位）
            let appMatched = itemsMap.values.first { item in
                !usedIds.contains(item.identifier) &&
                item.localeLanguage.languageCode == appLocaleLang.languageCode &&
                (item.localeLanguage.script == nil || item.localeLanguage.script == appLocaleLang.script)
            } ?? itemsMap.values.first { item in
                !usedIds.contains(item.identifier) &&
                item.localeLanguage.languageCode == appLocaleLang.languageCode
            }

            if let app = appMatched {
                sortedItems.append(app)
                usedIds.insert(app.identifier)
            }

            // 其餘語言依顯示名稱排序
            let remaining = itemsMap.values
                .filter { !usedIds.contains($0.identifier) }
                .sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }

            sortedItems.append(contentsOf: remaining)

            self.availableLanguages = sortedItems
        }
    }

    // MARK: - 繁簡文字無損轉換
    nonisolated public static func convertSimplifiedToTraditional(_ text: String) -> String {
        var str = text
        if let transformed = str.applyingTransform(StringTransform("Simplified-Traditional"), reverse: false) {
            str = transformed
        } else if let t2 = str.applyingTransform(StringTransform("Hans-Hant"), reverse: false) {
            str = t2
        }
        return str
    }

    nonisolated public static func convertTraditionalToSimplified(_ text: String) -> String {
        var str = text
        if let transformed = str.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) {
            str = transformed
        } else if let t2 = str.applyingTransform(StringTransform("Hant-Hans"), reverse: false) {
            str = t2
        }
        return str
    }

    // MARK: - 歌詞文字與音節全面簡轉繁
    nonisolated public static func convertLyricsToTraditional(_ lyrics: SyncedLyrics) -> SyncedLyrics {
        var updated = lyrics
        updated.lines = lyrics.lines.map { line in
            var updatedLine = line
            updatedLine.text = convertSimplifiedToTraditional(line.text)
            if let trans = line.translation {
                updatedLine.translation = convertSimplifiedToTraditional(trans)
            }
            if let syllables = line.syllables {
                updatedLine.syllables = syllables.map { syl in
                    var updatedSyl = syl
                    updatedSyl.text = convertSimplifiedToTraditional(syl.text)
                    return updatedSyl
                }
            }
            return updatedLine
        }
        return updated
    }

    // MARK: - 歌詞語言偵測與同語系檢查
    /// 偵測整首歌詞的主要語言
    nonisolated public static func detectLyricsLanguage(_ lyrics: SyncedLyrics) -> NLLanguage? {
        let sampleText = lyrics.lines.prefix(20).map { $0.text }.joined(separator: "\n")
        guard !sampleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sampleText)
        return recognizer.dominantLanguage
    }

    /// 判斷歌詞原文是否與目標語言相同（避免中文歌出中文翻譯、英文歌出英文翻譯）
    nonisolated public static func isSameLanguage(lyrics: SyncedLyrics, targetLanguageId: String) -> Bool {
        guard let dominant = detectLyricsLanguage(lyrics) else { return false }
        let targetLower = targetLanguageId.lowercased()

        // 華語判別
        if targetLower.hasPrefix("zh") {
            return dominant == .traditionalChinese || dominant == .simplifiedChinese
        }
        if targetLower.hasPrefix("en") && dominant == .english {
            return true
        }
        if targetLower.hasPrefix("ja") && dominant == .japanese {
            return true
        }
        if targetLower.hasPrefix("ko") && dominant == .korean {
            return true
        }
        if targetLower.hasPrefix("es") && dominant == .spanish {
            return true
        }
        if targetLower.hasPrefix("fr") && dominant == .french {
            return true
        }
        if targetLower.hasPrefix("de") && dominant == .german {
            return true
        }
        return false
    }

    /// 判斷目標語言為繁中且原文歌詞為簡體中文（華語歌）
    nonisolated public static func isTargetHantAndLyricsSimplified(lyrics: SyncedLyrics, targetLanguageId: String) -> Bool {
        let targetLower = targetLanguageId.lowercased()
        guard targetLower == "zh-hant" || targetLower.hasPrefix("zh-tw") || targetLower.hasPrefix("zh-hk") else {
            return false
        }
        guard let dominant = detectLyricsLanguage(lyrics) else { return false }
        return dominant == .simplifiedChinese
    }

    // MARK: - 判定歌詞是否需要進行 Translation 翻譯
    nonisolated public static func shouldTranslate(lyrics: SyncedLyrics, targetLanguageId: String) -> Bool {
        guard !lyrics.lines.isEmpty else { return false }

        // 若原文與目標語言同語系，不需要翻譯
        if isSameLanguage(lyrics: lyrics, targetLanguageId: targetLanguageId) {
            return false
        }

        // 若已經具備匹配當前目標語言的翻譯，不需要再次翻譯
        if let existingTarget = lyrics.translationTargetLanguage,
           existingTarget.caseInsensitiveCompare(targetLanguageId) == .orderedSame,
           lyrics.hasTranslation {
            return false
        }

        // 若歌詞尚未有翻譯，或翻譯對應之語言不符當前目標語言，則需要翻譯
        return true
    }

    // MARK: - Apple TranslationSession 批次翻譯整首歌詞
    public static func translateLyrics(
        _ lyrics: SyncedLyrics,
        using session: TranslationSession,
        targetLanguageId: String
    ) async -> SyncedLyrics? {
        guard !lyrics.lines.isEmpty else { return nil }

        // 篩選出需要翻譯的行（建立 requests，以行索引作為 clientIdentifier）
        var requests: [TranslationSession.Request] = []
        for (index, line) in lyrics.lines.enumerated() {
            let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                requests.append(TranslationSession.Request(sourceText: trimmed, clientIdentifier: "\(index)"))
            }
        }

        guard !requests.isEmpty else { return lyrics }

        do {
            let responses = try await session.translations(from: requests)
            var translationsByIndex: [Int: String] = [:]
            for resp in responses {
                if let idStr = resp.clientIdentifier, let idx = Int(idStr) {
                    var transText = resp.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                    // 若目標語言為繁體中文，確保輸出結果無殘留簡體
                    if targetLanguageId.lowercased().hasPrefix("zh-hant") || targetLanguageId.lowercased().hasPrefix("zh-tw") {
                        transText = convertSimplifiedToTraditional(transText)
                    }
                    translationsByIndex[idx] = transText
                }
            }

            var updatedLines = lyrics.lines
            for idx in 0..<updatedLines.count {
                updatedLines[idx].translation = translationsByIndex[idx]
            }

            var translatedLyrics = lyrics
            translatedLyrics.lines = updatedLines
            translatedLyrics.translationTargetLanguage = targetLanguageId

            // 儲存至本地快取
            LyricsProviderService.shared.saveLyricsToCache(translatedLyrics)
            return translatedLyrics
        } catch {
            print("[LyricsTranslationService] 批次翻譯失敗: \(error.localizedDescription)")
            return nil
        }
    }
}
