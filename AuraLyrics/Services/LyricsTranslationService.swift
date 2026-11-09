import Foundation
import Translation
import NaturalLanguage

/// Model representing a target translation language option.
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

/// Lyrics translation and Chinese script conversion service.
@MainActor
public final class LyricsTranslationService: ObservableObject {
    public static let shared = LyricsTranslationService()

    /// UserDefaults key
    public static let targetLanguageKey = "lyricsTranslationTargetLanguage"
    public static let defaultTargetLanguage = "zh-Hant"

    /// Target translation language code (BCP-47 identifier, e.g. zh-Hant, en, ja).
    @Published public var currentTargetLanguage: String {
        didSet {
            UserDefaults.standard.set(currentTargetLanguage, forKey: Self.targetLanguageKey)
        }
    }

    /// Cached list of supported translation languages sorted by priority.
    @Published public private(set) var availableLanguages: [TranslationTargetLanguageItem] = []

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.targetLanguageKey)
        self.currentTargetLanguage = saved?.isEmpty == false ? saved! : Self.defaultTargetLanguage
        refreshAvailableLanguages()
    }

    // MARK: - Fetch And Sort Supported Languages
    public func refreshAvailableLanguages() {
        Task {
            let availability = LanguageAvailability()
            let supported = await availability.supportedLanguages

            // Fallback language list when availability check returns empty.
            let languagesToProcess: [Locale.Language]
            if !supported.isEmpty {
                languagesToProcess = supported
            } else {
                let fallbackCodes = ["zh-Hant", "zh-Hans", "en", "ja", "ko", "es", "fr", "de", "it", "pt"]
                languagesToProcess = fallbackCodes.map { Locale.Language(identifier: $0) }
            }

            // 1. Get system preferred language.
            let systemPreferredLangCode = Locale.preferredLanguages.first ?? "zh-Hant"
            let systemLocaleLang = Locale.Language(identifier: systemPreferredLangCode)

            // 2. Get App preferred language.
            let appLangCode = Bundle.main.preferredLocalizations.first ?? "zh-Hant"
            let appLocaleLang = Locale.Language(identifier: appLangCode)

            // Deduplicate into items map.
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

            // First priority: system language match.
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

            // Second priority: App language match.
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

            // Sort remaining languages alphabetically by display name.
            let remaining = itemsMap.values
                .filter { !usedIds.contains($0.identifier) }
                .sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }

            sortedItems.append(contentsOf: remaining)

            self.availableLanguages = sortedItems
        }
    }

    // MARK: - Chinese Script Conversion
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

    // MARK: - Convert Lyrics Text And Syllables To Traditional Chinese
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

    // MARK: - Language Detection And Matching
    /// Detects dominant language of lyrics lines.
    nonisolated public static func detectLyricsLanguage(_ lyrics: SyncedLyrics) -> NLLanguage? {
        let sampleText = lyrics.lines.prefix(20).map { $0.text }.joined(separator: "\n")
        guard !sampleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sampleText)
        return recognizer.dominantLanguage
    }

    /// Checks whether original lyrics match target translation language.
    nonisolated public static func isSameLanguage(lyrics: SyncedLyrics, targetLanguageId: String) -> Bool {
        guard let dominant = detectLyricsLanguage(lyrics) else { return false }
        let targetLower = targetLanguageId.lowercased()

        // Chinese language match.
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

    /// Checks if target is Traditional Chinese while source lyrics are Simplified Chinese.
    nonisolated public static func isTargetHantAndLyricsSimplified(lyrics: SyncedLyrics, targetLanguageId: String) -> Bool {
        let targetLower = targetLanguageId.lowercased()
        guard targetLower == "zh-hant" || targetLower.hasPrefix("zh-tw") || targetLower.hasPrefix("zh-hk") else {
            return false
        }
        guard let dominant = detectLyricsLanguage(lyrics) else { return false }
        return dominant == .simplifiedChinese
    }

    // MARK: - Translation Eligibility Evaluation
    nonisolated public static func shouldTranslate(lyrics: SyncedLyrics, targetLanguageId: String) -> Bool {
        guard !lyrics.lines.isEmpty else { return false }

        // Skip translation if source matches target language.
        if isSameLanguage(lyrics: lyrics, targetLanguageId: targetLanguageId) {
            return false
        }

        // Skip if matching translation already exists.
        if let existingTarget = lyrics.translationTargetLanguage,
           existingTarget.caseInsensitiveCompare(targetLanguageId) == .orderedSame,
           lyrics.hasTranslation {
            return false
        }

        // Requires translation if missing or targeting different language.
        return true
    }

    // MARK: - Batch Translation via TranslationSession
    public static func translateLyrics(
        _ lyrics: SyncedLyrics,
        using session: TranslationSession,
        targetLanguageId: String
    ) async -> SyncedLyrics? {
        guard !lyrics.lines.isEmpty else { return nil }

        // Construct batch translation requests using line index as identifier.
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
                    // Ensure output is in Traditional Chinese if requested.
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

            // Persist translated lyrics to cache.
            LyricsProviderService.shared.saveLyricsToCache(translatedLyrics)
            return translatedLyrics
        } catch {
            print("[LyricsTranslationService] 批次翻譯失敗: \(error.localizedDescription)")
            return nil
        }
    }
}
