import Foundation
import Combine

/// 歌詞來源與本地快取管理器（純手機端連線，無須後端伺服器）
public final class LyricsProviderService: ObservableObject {
    public static let shared = LyricsProviderService()

    private let cacheDirectoryName = "LyricsCache"
    private let urlSession = URLSession.shared

    private let currentCacheSchemaVersion = 3
    private let priorityOrderPrefix = "lyricsSearchPriorityOrder_"
    private let prioritySchemaVersionPrefix = "lyricsSearchPrioritySchemaVersion_"
    private let currentPrioritySchemaVersion = 4

    @Published public private(set) var priorityProfiles: [LyricsLanguageProfile: [LyricsSearchPriorityItem]] = [:]

    public var priorityItems: [LyricsSearchPriorityItem] {
        priorityProfiles[.western] ?? LyricsSearchPriorityItem.defaultList(for: .western)
    }

    private init() {
        checkAndMigrateCache()
        createCacheDirectoryIfNeeded()
        loadPriorityItems()
    }

    // MARK: - 分語系順位管理
    private func loadPriorityItems() {
        for profile in LyricsLanguageProfile.allCases {
            let versionKey = "\(prioritySchemaVersionPrefix)\(profile.rawValue)"
            let orderKey = "\(priorityOrderPrefix)\(profile.rawValue)"
            let version = UserDefaults.standard.integer(forKey: versionKey)

            if version < currentPrioritySchemaVersion {
                // 首次升級至多語系 Schema v3：若為 .asian 且先前有舊版順位設定，繼承舊設定
                if profile == .asian,
                   let oldData = UserDefaults.standard.data(forKey: "lyricsSearchPriorityOrder"),
                   let oldList = try? JSONDecoder().decode([LyricsSearchPriorityItem].self, from: oldData),
                   !oldList.isEmpty {
                    self.priorityProfiles[profile] = oldList
                    savePriorityItems(oldList, for: profile)
                } else {
                    let defaults = LyricsSearchPriorityItem.defaultList(for: profile)
                    self.priorityProfiles[profile] = defaults
                    savePriorityItems(defaults, for: profile)
                }
                UserDefaults.standard.set(currentPrioritySchemaVersion, forKey: versionKey)
                continue
            }

            if let data = UserDefaults.standard.data(forKey: orderKey),
               let saved = try? JSONDecoder().decode([LyricsSearchPriorityItem].self, from: data),
               !saved.isEmpty {
                var list = saved
                let existingIds = Set(saved.map { $0.id })
                var didInsertNewDefaults = false
                for def in LyricsSearchPriorityItem.defaultList(for: profile) {
                    if !existingIds.contains(def.id) {
                        if def.isWordSync, let lastWordIdx = list.lastIndex(where: { $0.isWordSync }) {
                            list.insert(def, at: lastWordIdx + 1)
                        } else {
                            list.append(def)
                        }
                        didInsertNewDefaults = true
                    }
                }
                self.priorityProfiles[profile] = list
                if didInsertNewDefaults {
                    savePriorityItems(list, for: profile)
                }
            } else {
                let defaults = LyricsSearchPriorityItem.defaultList(for: profile)
                self.priorityProfiles[profile] = defaults
                savePriorityItems(defaults, for: profile)
                UserDefaults.standard.set(currentPrioritySchemaVersion, forKey: versionKey)
            }
        }
    }

    public func priorityItems(for profile: LyricsLanguageProfile) -> [LyricsSearchPriorityItem] {
        priorityProfiles[profile] ?? LyricsSearchPriorityItem.defaultList(for: profile)
    }

    public func savePriorityItems(_ items: [LyricsSearchPriorityItem], for profile: LyricsLanguageProfile) {
        priorityProfiles[profile] = items
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: "\(priorityOrderPrefix)\(profile.rawValue)")
        }
        objectWillChange.send()
    }

    public func savePriorityItems(_ items: [LyricsSearchPriorityItem]) {
        savePriorityItems(items, for: .western)
    }

    public func resetPriorityItems(for profile: LyricsLanguageProfile) {
        savePriorityItems(LyricsSearchPriorityItem.defaultList(for: profile), for: profile)
    }

    public func resetPriorityItems() {
        resetPriorityItems(for: .western)
    }

    public func resetAllPriorityItems() {
        for profile in LyricsLanguageProfile.allCases {
            resetPriorityItems(for: profile)
        }
    }

    public var highestPriorityDescription: String {
        func topDesc(for profile: LyricsLanguageProfile) -> String {
            if let first = priorityItems(for: profile).first(where: { $0.isEnabled }) {
                return first.source.displayName
            }
            return String(localized: "無")
        }
        let w = topDesc(for: .western)
        let a = topDesc(for: .asian)
        let j = topDesc(for: .japanese)
        return "歐美: \(w) / 亞: \(a) / 日: \(j)"
    }

    // MARK: - 快取遷移 (Cache Schema v3)
    private func checkAndMigrateCache() {
        let storedVersion = UserDefaults.standard.integer(forKey: "lyricsCacheSchemaVersion")
        if storedVersion < currentCacheSchemaVersion {
            // 升級至支援分語系與嚴格防張冠李戴之快取架構：保留使用者手動匯入之 Local 歌詞，清除舊版快取
            if FileManager.default.fileExists(atPath: cacheDirectoryURL.path),
               let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectoryURL, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension == "json" {
                    if let data = try? Data(contentsOf: file),
                       let lyrics = try? JSONDecoder().decode(SyncedLyrics.self, from: data),
                       lyrics.source == "Local" {
                        continue
                    }
                    try? FileManager.default.removeItem(at: file)
                }
            }
            UserDefaults.standard.set(currentCacheSchemaVersion, forKey: "lyricsCacheSchemaVersion")
        }
    }

    // MARK: - 本地快取路徑
    private var cacheDirectoryURL: URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0].appendingPathComponent(cacheDirectoryName)
    }

    private func createCacheDirectoryIfNeeded() {
        let dir = cacheDirectoryURL
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private func sanitizeFileName(_ string: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|")
        return string.components(separatedBy: invalidCharacters).joined(separator: "_")
    }

    private func cacheFileURL(title: String, artist: String) -> URL {
        let sanitized = sanitizeFileName("\(title) - \(artist)")
        return cacheDirectoryURL.appendingPathComponent("\(sanitized).json")
    }

    // MARK: - 讀取本地快取
    public func loadCachedLyrics(title: String, artist: String) -> SyncedLyrics? {
        let fileURL = cacheFileURL(title: title, artist: artist)
        if let data = try? Data(contentsOf: fileURL),
           let lyrics = try? JSONDecoder().decode(SyncedLyrics.self, from: data) {
            return lyrics
        }
        let variants = MetadataNormalizer.extractQueryVariants(title: title, artist: artist)
        if variants.primaryTitle != title && !variants.primaryTitle.isEmpty {
            let fallbackURL = cacheFileURL(title: variants.primaryTitle, artist: variants.primaryArtist)
            if let data = try? Data(contentsOf: fallbackURL),
               let lyrics = try? JSONDecoder().decode(SyncedLyrics.self, from: data) {
                return lyrics
            }
        }
        return nil
    }

    // MARK: - 儲存至本地快取
    public func saveLyricsToCache(_ lyrics: SyncedLyrics) {
        createCacheDirectoryIfNeeded()
        let fileURL = cacheFileURL(title: lyrics.trackTitle, artist: lyrics.artistName)
        if let data = try? JSONEncoder().encode(lyrics) {
            try? data.write(to: fileURL, options: [.atomic])
        }
    }

    // MARK: - 更新特定歌曲的時間軸微調 Offset
    public func updateOffset(title: String, artist: String, newOffsetMs: Int, currentLyrics: SyncedLyrics) -> SyncedLyrics {
        var updated = currentLyrics
        updated.offsetMs = newOffsetMs
        saveLyricsToCache(updated)
        return updated
    }

    // MARK: - 匯入外部 .lrc 檔案
    public func importLocalLRCFile(url: URL, title: String, artist: String) -> SyncedLyrics? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let (lines, credits) = LRCParser.shared.parseWithCredits(lrcContent: content)
        guard !lines.isEmpty else { return nil }

        let synced = SyncedLyrics(
            trackTitle: title,
            artistName: artist,
            lines: lines,
            credits: credits,
            offsetMs: 0,
            source: "Local"
        )
        saveLyricsToCache(synced)
        return synced
    }

    // MARK: - 列出所有已快取的歌詞檔案
    public func listAllCachedLyrics() -> [SyncedLyrics] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectoryURL, includingPropertiesForKeys: nil) else {
            return []
        }
        var list: [SyncedLyrics] = []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let lyrics = try? JSONDecoder().decode(SyncedLyrics.self, from: data) {
                list.append(lyrics)
            }
        }
        return list.sorted { $0.trackTitle < $1.trackTitle }
    }

    // MARK: - 刪除快取
    public func deleteCachedLyrics(title: String, artist: String) {
        let fileURL = cacheFileURL(title: title, artist: artist)
        try? FileManager.default.removeItem(at: fileURL)
        let variants = MetadataNormalizer.extractQueryVariants(title: title, artist: artist)
        if variants.primaryTitle != title && !variants.primaryTitle.isEmpty {
            let fallbackURL = cacheFileURL(title: variants.primaryTitle, artist: variants.primaryArtist)
            try? FileManager.default.removeItem(at: fallbackURL)
        }
    }

    public func clearAllCache() {
        try? FileManager.default.removeItem(at: cacheDirectoryURL)
        createCacheDirectoryIfNeeded()
    }

    // MARK: - 多層次語系自動判別
    public func detectLanguageProfile(for track: TrackInfo) -> LyricsLanguageProfile {
        let genreLower = track.genre.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let title = track.title
        let artist = track.artist
        let album = track.album
        let combinedMeta = "\(title) \(artist) \(album)"

        // 1. Genre 優先判別
        if !genreLower.isEmpty {
            let japaneseGenres = ["j-pop", "jpop", "japanese", "anime", "kayokyoku", "j-rock", "jrock", "vocaloid", "enka"]
            if japaneseGenres.contains(where: { genreLower.contains($0) }) {
                return .japanese
            }
            let asianGenres = ["mandopop", "cantopop", "c-pop", "cpop", "chinese", "taiwan", "k-pop", "kpop", "korean", "t-pop", "asian"]
            if asianGenres.contains(where: { genreLower.contains($0) }) {
                return .asian
            }
        }

        // 2. 字元集特徵判別 (假名、日系專用符號、韓文諺文)
        // 平假名: 0x3040...0x309F, 片假名: 0x30A0...0x30FF, 半形片假名: 0xFF66...0xFF9F
        let hasKana = combinedMeta.unicodeScalars.contains { scalar in
            let v = scalar.value
            return (v >= 0x3040 && v <= 0x309F) || (v >= 0x30A0 && v <= 0x30FF) || (v >= 0xFF66 && v <= 0xFF9F)
        }
        if hasKana {
            return .japanese
        }

        let jpSymbols: Set<Character> = [
            "々", "〆", "ヶ", "ゐ", "ゑ", "ヰ", "ヱ",
            "咲", "雫", "凪", "叶", "桜", "遥", "凛", "澤", "齋", "邊", "濱",
            "峠", "辻", "笹", "榊", "畑", "畠", "栃", "栂", "椙", "籾", "鰯",
            "鯖", "鯵", "噺", "麿", "躾"
        ]
        if combinedMeta.contains(where: { jpSymbols.contains($0) }) {
            return .japanese
        }

        // 韓文諺文: 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F
        let hasHangul = combinedMeta.unicodeScalars.contains { scalar in
            let v = scalar.value
            return (v >= 0xAC00 && v <= 0xD7AF) || (v >= 0x1100 && v <= 0x11FF) || (v >= 0x3130 && v <= 0x318F)
        }
        if hasHangul {
            return .asian
        }

        // 3. 日本常見羅馬拼音/英文與純漢字歌手特徵庫
        let artistLower = artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !artistLower.isEmpty {
            let artistTokens = Set(artistLower.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
            let japaneseArtists: [String] = [
                "yoasobi", "ado", "vaundy", "lisa", "aimer", "king gnu", "kenshi yonezu", "米津玄師", "米津玄师",
                "fujii kaze", "藤井風", "藤井风", "radwimps", "one ok rock", "official髭男dism", "official hige dandism",
                "hikaru utada", "宇多田光", "宇多田ヒカル", "mrs. green apple", "back number", "yorushika", "ヨルシカ",
                "zutomayo", "ずっと真夜中でいいのに", "eve", "tatsuya kitani", "creepy nuts", "aimyon", "あいみょん",
                "sekai no owari", "perfume", "babymetal", "sawano hiroyuki", "澤野弘之", "久石讓", "久石让",
                "坂本龍一", "坂本龙一", "椎名林檎", "東京事變", "东京事变", "中島美嘉", "中岛美嘉", "濱崎步", "滨崎步",
                "安室奈美惠", "星野源", "菅田將暉", "菅田将晖", "優里", "yuuri", "imase", "tani yuuki", "milet",
                "yama", "ikura", "ayase", "b'z", "mr.children", "spitz", "glay", "l'arc~en~ciel", "uverworld",
                "man with a mission", "asian kung-fu generation", "bump of chicken", "kana-boon", "amazarashi",
                "ling tosite sigure", "sakanaction", "daoko", "majiko", "reol", "sayuri", "supercell", "flow",
                "spyair", "granrodeo", "myth & roid", "ali", "scandal", "wacci", "novelbright", "macaroni empitsu",
                "sumika", "she's", "saucy dog", "dish//", "dish", "da-ice", "generations", "jo1", "ini", "snow man",
                "sixstones", "naniwa danshi", "king & prince", "arashi", "嵐", "smap", "v6", "kinki kids"
            ]
            let isJpArtist = japaneseArtists.contains { ja in
                if ja.count <= 4 && !ja.contains(" ") && !ja.contains("-") && !ja.contains("~") {
                    return artistTokens.contains(ja) || artistLower == ja
                } else {
                    return artistLower == ja || artistLower.contains(ja)
                }
            }
            if isJpArtist {
                return .japanese
            }
        }

        // 4. 中文字元 (CJK Unified Ideographs: 0x4E00...0x9FFF)
        let hasCJK = combinedMeta.unicodeScalars.contains { scalar in
            let v = scalar.value
            return v >= 0x4E00 && v <= 0x9FFF
        }
        if hasCJK {
            return .asian
        }

        // 5. 其餘回退為歐美/預設
        return .western
    }

    // MARK: - 線上自動搜尋歌詞（依語系專屬平台與逐字/逐行順位搜尋）
    public func fetchLyrics(track: TrackInfo) async -> SyncedLyrics? {
        let cleanTitle = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanTitle.isEmpty else { return nil }

        let cached = loadCachedLyrics(title: cleanTitle, artist: cleanArtist)

        // 1. 若為使用者本地手動匯入，絕對優先採用
        if let cached = cached, cached.source == "Local" {
            return cached
        }

        let profile = detectLanguageProfile(for: track)
        let activePriorities = priorityItems(for: profile).filter { $0.isEnabled }

        // 2. 若本地快取已符合該語系最高優先級別且具備逐字，可直接沿用節省連線與電量
        if let cached = cached, cached.hasSyllables,
           let topPriority = activePriorities.first, topPriority.isWordSync,
           topPriority.source.rawValue.caseInsensitiveCompare(cached.source) == .orderedSame {
            return cached
        }

        // 3. 記憶體暫存各來源請求結果，確保在一次歌曲搜尋中各來源最多僅呼叫一次
        var sourceCache: [LyricsSource: SyncedLyrics?] = [:]

        func getOrFetch(source: LyricsSource) async -> SyncedLyrics? {
            if let existing = sourceCache[source] {
                return existing
            }
            let res: SyncedLyrics?
            switch source {
            case .musixmatch:
                res = await fetchFromMusixmatch(title: cleanTitle, artist: cleanArtist, durationSec: track.duration)
            case .netease:
                res = await fetchFromNetEase(title: cleanTitle, artist: cleanArtist, durationSec: track.duration)
            case .lrclib:
                res = await fetchFromLRCLIB(title: cleanTitle, artist: cleanArtist, durationSec: track.duration)
            case .petitlyrics:
                res = await fetchFromPetitLyrics(title: cleanTitle, artist: cleanArtist, durationSec: track.duration)
            }
            sourceCache[source] = res
            return res
        }

        // 4. 依該語系自訂順位依序比對
        for item in activePriorities {
            guard let result = await getOrFetch(source: item.source) else {
                continue
            }

            if item.isWordSync {
                // 逐字項目：必須包含音節時間軸
                if result.hasSyllables {
                    var toSave = result
                    toSave.trackTitle = cleanTitle
                    toSave.artistName = cleanArtist
                    saveLyricsToCache(toSave)
                    return toSave
                }
            } else {
                // 普通逐行項目：無論有無逐字皆可滿足降級標準
                var toSave = result
                toSave.trackTitle = cleanTitle
                toSave.artistName = cleanArtist
                saveLyricsToCache(toSave)
                return toSave
            }
        }

        // 5. 若所有啟用順位皆未滿足，回退至既有快取
        return cached
    }

    // MARK: - 手動搜尋跨庫歌詞（Structured Concurrency 並行請求，不污染快取直到使用者點選）
    public func searchOnlineLyrics(
        query: String,
        targetTitle: String = "",
        targetArtist: String = "",
        durationSec: TimeInterval = 0
    ) async -> [SyncedLyrics] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let resolvedTitle: String
        let resolvedArtist: String
        if !targetTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedTitle = targetTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            resolvedArtist = targetArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let dashRange = trimmed.range(of: " - ") {
            resolvedTitle = String(trimmed[..<dashRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            resolvedArtist = String(trimmed[dashRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let lastSpaceIdx = trimmed.lastIndex(where: { $0.isWhitespace }) {
            let head = String(trimmed[..<lastSpaceIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = String(trimmed[trimmed.index(after: lastSpaceIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            resolvedTitle = head.isEmpty ? trimmed : head
            resolvedArtist = head.isEmpty ? "" : tail
        } else {
            resolvedTitle = trimmed
            resolvedArtist = ""
        }

        async let mxmTask = fetchCandidatesFromMusixmatch(title: resolvedTitle, artist: resolvedArtist, durationSec: durationSec)
        async let netEaseTask = fetchCandidatesFromNetEase(title: resolvedTitle, artist: resolvedArtist, durationSec: durationSec, maxCount: 3)
        async let lrclibTask = fetchCandidatesFromLRCLIB(title: resolvedTitle, artist: resolvedArtist, durationSec: durationSec, maxCount: 3)
        async let petitTask = fetchCandidatesFromPetitLyrics(title: resolvedTitle, artist: resolvedArtist, durationSec: durationSec, maxCount: 3)

        let (mxmList, netEaseList, lrclibList, petitList) = await (mxmTask, netEaseTask, lrclibTask, petitTask)
        var results: [SyncedLyrics] = []
        var seenIds = Set<String>()

        func appendIfNew(_ items: [SyncedLyrics]) {
            for item in items {
                if !seenIds.contains(item.id) {
                    seenIds.insert(item.id)
                    results.append(item)
                }
            }
        }

        // 依多樣性呈現候選清單
        appendIfNew(petitList)
        appendIfNew(netEaseList)
        appendIfNew(mxmList)
        appendIfNew(lrclibList)

        return results
    }

    // MARK: - Musixmatch API 請求（免金鑰匿名憑證 + Richsync 逐字 + 雙重把關）
    private func getMusixmatchToken() async -> String? {
        if let stored = UserDefaults.standard.string(forKey: "musixmatchUserToken"),
           !stored.isEmpty, stored != "00000000000000000000000000000000000000000000000000000000" {
            return stored
        }
        return await refreshMusixmatchToken()
    }

    private func refreshMusixmatchToken() async -> String? {
        guard let url = URL(string: "https://apic-appmobile.musixmatch.com/ws/1.1/token.get?app_id=mac-ios-v2.0") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("apic-appmobile.musixmatch.com", forHTTPHeaderField: "Host")
        request.setValue("10.1.1", forHTTPHeaderField: "x-mxm-app-version")
        request.setValue("Musixmatch/2025120901 CFNetwork/3860.300.31 Darwin/25.2.0", forHTTPHeaderField: "X-User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 8

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }
            struct TokenResponse: Codable {
                struct Message: Codable {
                    struct Body: Codable {
                        let user_token: String?
                    }
                    let header: Header
                    let body: Body?
                    struct Header: Codable {
                        let status_code: Int
                    }
                }
                let message: Message
            }
            let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
            if let token = decoded.message.body?.user_token,
               !token.isEmpty, token != "00000000000000000000000000000000000000000000000000000000" {
                UserDefaults.standard.set(token, forKey: "musixmatchUserToken")
                return token
            }
        } catch {
            print("[LyricsProvider] Musixmatch Token 換發失敗: \(error.localizedDescription)")
        }
        return nil
    }

    public func fetchCandidatesFromMusixmatch(title: String, artist: String, durationSec: TimeInterval = 0) async -> [SyncedLyrics] {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return [] }
        guard let token = await getMusixmatchToken() else { return [] }

        // 先以原標題與歌手請求
        if let result = await performMusixmatchRequest(title: cleanTitle, artist: cleanArtist, durationSec: durationSec, token: token, allowRetryOn401: true) {
            return [result]
        }

        // 若無結果或被硬性門檻攔截，嘗試清洗後的標題
        let variants = MetadataNormalizer.extractQueryVariants(title: cleanTitle, artist: cleanArtist)
        if variants.primaryTitle != cleanTitle && !variants.primaryTitle.isEmpty {
            if let result = await performMusixmatchRequest(title: variants.primaryTitle, artist: variants.primaryArtist, durationSec: durationSec, token: token, allowRetryOn401: true) {
                return [result]
            }
        }
        if let sec = variants.secondaryTitle, sec != cleanTitle && !sec.isEmpty {
            if let result = await performMusixmatchRequest(title: sec, artist: variants.primaryArtist, durationSec: durationSec, token: token, allowRetryOn401: true) {
                return [result]
            }
        }

        return []
    }

    public func fetchFromMusixmatch(title: String, artist: String, durationSec: TimeInterval = 0) async -> SyncedLyrics? {
        await fetchCandidatesFromMusixmatch(title: title, artist: artist, durationSec: durationSec).first
    }

    private func performMusixmatchRequest(title: String, artist: String, durationSec: TimeInterval, token: String, allowRetryOn401: Bool) async -> SyncedLyrics? {
        guard var components = URLComponents(string: "https://apic-appmobile.musixmatch.com/ws/1.1/macro.subtitles.get") else { return nil }

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "namespace", value: "lyrics_richsynched"),
            URLQueryItem(name: "subtitle_format", value: "mxm"),
            URLQueryItem(name: "app_id", value: "mac-ios-v2.0"),
            URLQueryItem(name: "q_track", value: title),
            URLQueryItem(name: "optional_calls", value: "track.richsync"),
            URLQueryItem(name: "richsync_compact_type", value: "words"),
            URLQueryItem(name: "usertoken", value: token)
        ]

        if !artist.isEmpty {
            queryItems.append(URLQueryItem(name: "q_artist", value: artist))
        }

        if durationSec > 0 {
            let durInt = String(Int(durationSec))
            queryItems.append(URLQueryItem(name: "q_duration", value: durInt))
            queryItems.append(URLQueryItem(name: "f_subtitle_length", value: durInt))
            queryItems.append(URLQueryItem(name: "f_subtitle_length_max_deviation", value: "10"))
        }

        components.queryItems = queryItems
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("apic-appmobile.musixmatch.com", forHTTPHeaderField: "Host")
        request.setValue("10.1.1", forHTTPHeaderField: "x-mxm-app-version")
        request.setValue("Musixmatch/2025120901 CFNetwork/3860.300.31 Darwin/25.2.0", forHTTPHeaderField: "X-User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 8

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return nil }

            if httpResponse.statusCode == 401 && allowRetryOn401 {
                UserDefaults.standard.removeObject(forKey: "musixmatchUserToken")
                if let newToken = await refreshMusixmatchToken() {
                    return await performMusixmatchRequest(title: title, artist: artist, durationSec: durationSec, token: newToken, allowRetryOn401: false)
                }
                return nil
            }

            guard httpResponse.statusCode == 200 else { return nil }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let message = json?["message"] as? [String: Any],
                  let header = message["header"] as? [String: Any],
                  let statusCode = header["status_code"] as? Int, statusCode == 200,
                  let body = message["body"] as? [String: Any],
                  let macroCalls = body["macro_calls"] as? [String: Any] else {
                return nil
            }

            // 驗證 Musixmatch 回傳之真實曲目資訊 (嚴格防張冠李戴)
            var mxmTrackName = title
            var mxmArtistName = artist
            var mxmDuration = durationSec

            if let trackCall = macroCalls["matcher.track.get"] as? [String: Any],
               let tMsg = trackCall["message"] as? [String: Any],
               let tBody = tMsg["body"] as? [String: Any],
               let tTrack = tBody["track"] as? [String: Any] {
                if let tName = tTrack["track_name"] as? String, !tName.isEmpty {
                    mxmTrackName = tName
                }
                if let aName = tTrack["artist_name"] as? String, !aName.isEmpty {
                    mxmArtistName = aName
                }
                if let d = tTrack["track_length"] as? Double, d > 0 {
                    mxmDuration = d
                } else if let dInt = tTrack["track_length"] as? Int, dInt > 0 {
                    mxmDuration = Double(dInt)
                }
            }

            // 執行嚴格硬性門檻驗證
            guard MetadataNormalizer.evaluateCandidateMatch(
                targetTitle: title,
                targetArtist: artist,
                targetDuration: durationSec,
                candidateTitle: mxmTrackName,
                candidateArtist: mxmArtistName,
                candidateDuration: mxmDuration,
                isWordSync: true
            ) != nil else {
                return nil
            }

            // 1. 優先嘗試 Richsync 逐字音節時間軸
            if let richsyncCall = macroCalls["track.richsync.get"] as? [String: Any],
               let rsMsg = richsyncCall["message"] as? [String: Any],
               let rsHeader = rsMsg["header"] as? [String: Any],
               (rsHeader["status_code"] as? Int) == 200,
               let rsBody = rsMsg["body"] as? [String: Any],
               let richsyncObj = rsBody["richsync"] as? [String: Any],
               let richsyncRaw = richsyncObj["richsync_body"] as? String {
                let lines = LRCParser.shared.parseMusixmatchRichsync(richsyncBody: richsyncRaw)
                if !lines.isEmpty {
                    var credits: [String] = []
                    if let copyright = richsyncObj["lyrics_copyright"] as? String, !copyright.isEmpty {
                        credits.append(copyright.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    return SyncedLyrics(
                        trackTitle: mxmTrackName,
                        artistName: mxmArtistName,
                        lines: lines,
                        credits: credits,
                        offsetMs: 0,
                        source: "Musixmatch"
                    )
                }
            }

            // 2. 若無逐字，降級提取 Subtitles 逐行時間軸
            if let subCall = macroCalls["track.subtitles.get"] as? [String: Any],
               let subMsg = subCall["message"] as? [String: Any],
               let subHeader = subMsg["header"] as? [String: Any],
               (subHeader["status_code"] as? Int) == 200,
               let subBody = subMsg["body"] as? [String: Any],
               let subList = subBody["subtitle_list"] as? [[String: Any]],
               let firstSub = subList.first?["subtitle"] as? [String: Any],
               let subRaw = firstSub["subtitle_body"] as? String {
                let lines = LRCParser.shared.parseMusixmatchSubtitles(subtitleBody: subRaw)
                if !lines.isEmpty {
                    var credits: [String] = []
                    if let copyright = firstSub["lyrics_copyright"] as? String, !copyright.isEmpty {
                        credits.append(copyright.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    return SyncedLyrics(
                        trackTitle: mxmTrackName,
                        artistName: mxmArtistName,
                        lines: lines,
                        credits: credits,
                        offsetMs: 0,
                        source: "Musixmatch"
                    )
                }
            }
        } catch {
            print("[LyricsProvider] Musixmatch 請求失敗: \(error.localizedDescription)")
        }

        return nil
    }

    // MARK: - LRCLIB API 請求（支援精確匹配與 /api/search 雙重把關）
    private struct LRCLIBRecord: Codable {
        let id: Int?
        let trackName: String?
        let artistName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    public func fetchCandidatesFromLRCLIB(title: String, artist: String, durationSec: TimeInterval = 0, maxCount: Int = 3) async -> [SyncedLyrics] {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return [] }

        var results: [SyncedLyrics] = []

        // 1. 若只有一筆需求，先嘗試精確 /api/get
        if maxCount == 1, var components = URLComponents(string: "https://lrclib.net/api/get") {
            var queryItems = [
                URLQueryItem(name: "track_name", value: cleanTitle),
                URLQueryItem(name: "artist_name", value: cleanArtist)
            ]
            if durationSec > 0 {
                queryItems.append(URLQueryItem(name: "duration", value: String(Int(durationSec))))
            }
            components.queryItems = queryItems
            if let url = components.url {
                var request = URLRequest(url: url)
                request.setValue("AuraLyrics-iOS-OpenSource/1.0", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 8
                if let (data, response) = try? await urlSession.data(for: request),
                   let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                   let decoded = try? JSONDecoder().decode(LRCLIBRecord.self, from: data),
                   let synced = decoded.syncedLyrics, !synced.isEmpty {
                    let candTitle = decoded.trackName ?? cleanTitle
                    let candArtist = decoded.artistName ?? cleanArtist
                    let candDur = decoded.duration ?? durationSec
                    if MetadataNormalizer.evaluateCandidateMatch(
                        targetTitle: cleanTitle,
                        targetArtist: cleanArtist,
                        targetDuration: durationSec,
                        candidateTitle: candTitle,
                        candidateArtist: candArtist,
                        candidateDuration: candDur,
                        isWordSync: false
                    ) != nil {
                        let (lines, credits) = LRCParser.shared.parseWithCredits(lrcContent: synced)
                        if !lines.isEmpty {
                            return [SyncedLyrics(
                                trackTitle: candTitle,
                                artistName: candArtist,
                                lines: lines,
                                credits: credits,
                                offsetMs: 0,
                                source: "LRCLIB"
                            )]
                        }
                    }
                }
            }
        }

        // 2. 備援或多候選檢索：使用 /api/search
        let searchQuery = "\(cleanTitle) \(cleanArtist)".trimmingCharacters(in: .whitespaces)
        results = await performLRCLIBSearch(query: searchQuery, targetTitle: cleanTitle, targetArtist: cleanArtist, durationSec: durationSec, maxCount: maxCount)

        // 若無結果，嘗試清洗後的標題
        if results.isEmpty {
            let variants = MetadataNormalizer.extractQueryVariants(title: cleanTitle, artist: cleanArtist)
            if variants.primaryTitle != cleanTitle && !variants.primaryTitle.isEmpty {
                let retryQuery = "\(variants.primaryTitle) \(variants.primaryArtist)".trimmingCharacters(in: .whitespaces)
                results = await performLRCLIBSearch(query: retryQuery, targetTitle: cleanTitle, targetArtist: cleanArtist, durationSec: durationSec, maxCount: maxCount)
            }
            if results.isEmpty, let sec = variants.secondaryTitle, !sec.isEmpty {
                let retryQuery = "\(sec) \(variants.primaryArtist)".trimmingCharacters(in: .whitespaces)
                results = await performLRCLIBSearch(query: retryQuery, targetTitle: cleanTitle, targetArtist: cleanArtist, durationSec: durationSec, maxCount: maxCount)
            }
        }

        return results
    }

    private func performLRCLIBSearch(query: String, targetTitle: String, targetArtist: String, durationSec: TimeInterval, maxCount: Int) async -> [SyncedLyrics] {
        guard var searchComponents = URLComponents(string: "https://lrclib.net/api/search") else { return [] }
        searchComponents.queryItems = [
            URLQueryItem(name: "q", value: query)
        ]
        guard let searchUrl = searchComponents.url else { return [] }

        var searchRequest = URLRequest(url: searchUrl)
        searchRequest.setValue("AuraLyrics-iOS-OpenSource/1.0", forHTTPHeaderField: "User-Agent")
        searchRequest.timeoutInterval = 8

        do {
            let (data, response) = try await urlSession.data(for: searchRequest)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return []
            }
            let records = try JSONDecoder().decode([LRCLIBRecord].self, from: data)
            var scored: [(record: LRCLIBRecord, score: Double)] = []
            for rec in records {
                guard let synced = rec.syncedLyrics, !synced.isEmpty else { continue }
                let candTitle = rec.trackName ?? ""
                let candArtist = rec.artistName ?? ""
                let candDur = rec.duration ?? 0
                if let score = MetadataNormalizer.evaluateCandidateMatch(
                    targetTitle: targetTitle,
                    targetArtist: targetArtist,
                    targetDuration: durationSec,
                    candidateTitle: candTitle,
                    candidateArtist: candArtist,
                    candidateDuration: candDur,
                    isWordSync: false
                ) {
                    scored.append((rec, score))
                }
            }

            let sorted = scored.sorted { $0.score > $1.score }.prefix(maxCount)
            var results: [SyncedLyrics] = []
            for item in sorted {
                if let synced = item.record.syncedLyrics {
                    let (lines, credits) = LRCParser.shared.parseWithCredits(lrcContent: synced)
                    if !lines.isEmpty {
                        results.append(SyncedLyrics(
                            trackTitle: item.record.trackName ?? targetTitle,
                            artistName: item.record.artistName ?? targetArtist,
                            lines: lines,
                            credits: credits,
                            offsetMs: 0,
                            source: "LRCLIB"
                        ))
                    }
                }
            }
            return results
        } catch {
            print("[LyricsProvider] LRCLIB 檢索失敗: \(error.localizedDescription)")
            return []
        }
    }

    public func fetchFromLRCLIB(title: String, artist: String, durationSec: TimeInterval) async -> SyncedLyrics? {
        await fetchCandidatesFromLRCLIB(title: title, artist: artist, durationSec: durationSec, maxCount: 1).first
    }

    // MARK: - 網易雲音樂公開 API 請求（擴充別名與 transNames，支援 YRC/KRC/LRC 與繁簡折疊評分）
    private struct NetEaseSearchResult: Codable {
        struct ResultData: Codable {
            struct Song: Codable {
                let id: Int
                let name: String
                let duration: Int?
                let alias: [String]?
                let transNames: [String]?
                struct Artist: Codable {
                    let name: String?
                }
                let artists: [Artist]?
            }
            let songs: [Song]?
        }
        let result: ResultData?
    }

    private struct ScoredNetEaseSong {
        let song: NetEaseSearchResult.ResultData.Song
        let score: Double
        let artistName: String
    }

    public func fetchCandidatesFromNetEase(title: String, artist: String, durationSec: TimeInterval = 0, maxCount: Int = 3) async -> [SyncedLyrics] {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return [] }

        var candidateSongs = await requestNetEaseSearchCandidates(title: cleanTitle, artist: cleanArtist, durationSec: durationSec)

        // 若第一次查詢無結果，嘗試以清洗後的 primaryTitle 或 secondaryTitle 重試
        if candidateSongs.isEmpty {
            let variants = MetadataNormalizer.extractQueryVariants(title: cleanTitle, artist: cleanArtist)
            if variants.primaryTitle != cleanTitle && !variants.primaryTitle.isEmpty {
                candidateSongs = await requestNetEaseSearchCandidates(title: variants.primaryTitle, artist: variants.primaryArtist, durationSec: durationSec)
            }
            if candidateSongs.isEmpty, let sec = variants.secondaryTitle, !sec.isEmpty {
                candidateSongs = await requestNetEaseSearchCandidates(title: sec, artist: variants.primaryArtist, durationSec: durationSec)
            }
        }

        guard !candidateSongs.isEmpty else { return [] }

        var results: [SyncedLyrics] = []
        let topSongs = Array(candidateSongs.prefix(maxCount))

        for item in topSongs {
            if let lyrics = await fetchNetEaseSongLyrics(songItem: item, targetTitle: cleanTitle, targetArtist: cleanArtist) {
                results.append(lyrics)
            }
        }

        return results
    }

    public func fetchFromNetEase(title: String, artist: String, durationSec: TimeInterval = 0) async -> SyncedLyrics? {
        await fetchCandidatesFromNetEase(title: title, artist: artist, durationSec: durationSec, maxCount: 1).first
    }

    private func requestNetEaseSearchCandidates(title: String, artist: String, durationSec: TimeInterval) async -> [ScoredNetEaseSong] {
        let searchQuery = "\(title) \(artist)".trimmingCharacters(in: .whitespaces)
        guard var searchComponents = URLComponents(string: "https://music.163.com/api/search/get/web") else { return [] }
        searchComponents.queryItems = [
            URLQueryItem(name: "csrf_token", value: ""),
            URLQueryItem(name: "s", value: searchQuery),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "total", value: "true"),
            URLQueryItem(name: "limit", value: "10")
        ]

        guard let searchUrl = searchComponents.url else { return [] }

        do {
            var searchRequest = URLRequest(url: searchUrl)
            searchRequest.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
            searchRequest.timeoutInterval = 8

            let (searchData, _) = try await urlSession.data(for: searchRequest)
            let searchDecoded = try JSONDecoder().decode(NetEaseSearchResult.self, from: searchData)
            guard let songs = searchDecoded.result?.songs, !songs.isEmpty else { return [] }

            var scored: [ScoredNetEaseSong] = []
            for song in songs {
                let songArtist = song.artists?.compactMap { $0.name }.joined(separator: " ") ?? ""
                let songDurSec = Double(song.duration ?? 0) / 1000.0
                let aliases = (song.alias ?? []) + (song.transNames ?? [])

                if let score = MetadataNormalizer.evaluateCandidateMatch(
                    targetTitle: title,
                    targetArtist: artist,
                    targetDuration: durationSec,
                    candidateTitle: song.name,
                    candidateArtist: songArtist,
                    candidateDuration: songDurSec,
                    candidateAliases: aliases,
                    isWordSync: true
                ) {
                    scored.append(ScoredNetEaseSong(song: song, score: score, artistName: songArtist))
                }
            }

            return scored.sorted { $0.score > $1.score }
        } catch {
            print("[LyricsProvider] 網易雲搜尋失敗: \(error.localizedDescription)")
            return []
        }
    }

    private func fetchNetEaseSongLyrics(songItem: ScoredNetEaseSong, targetTitle: String, targetArtist: String) async -> SyncedLyrics? {
        let songId = songItem.song.id
        guard let lyricUrl = URL(string: "https://music.163.com/api/song/lyric?os=pc&id=\(songId)&lv=-1&kv=-1&tv=-1&yv=-1") else {
            return nil
        }

        var lyricRequest = URLRequest(url: lyricUrl)
        lyricRequest.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        lyricRequest.timeoutInterval = 8

        do {
            let (lyricData, _) = try await urlSession.data(for: lyricRequest)

            struct NetEaseLyricResponse: Codable {
                struct LyricObj: Codable {
                    let lyric: String?
                }
                let lrc: LyricObj?
                let tlyric: LyricObj?
                let yrc: LyricObj?
                let klyric: LyricObj?
            }

            let lyricDecoded = try JSONDecoder().decode(NetEaseLyricResponse.self, from: lyricData)

            var origLines: [LyricLine] = []
            if let rawYrc = lyricDecoded.yrc?.lyric, !rawYrc.isEmpty {
                let parsed = LRCParser.shared.parseYRC(yrcContent: rawYrc)
                if !parsed.isEmpty {
                    origLines = parsed
                }
            }

            if origLines.isEmpty, let rawKrc = lyricDecoded.klyric?.lyric, !rawKrc.isEmpty {
                let parsed = LRCParser.shared.parseKRC(krcContent: rawKrc)
                if !parsed.isEmpty {
                    origLines = parsed
                }
            }

            if origLines.isEmpty, let rawLrc = lyricDecoded.lrc?.lyric, !rawLrc.isEmpty {
                origLines = LRCParser.shared.parse(lrcContent: rawLrc)
            }

            guard !origLines.isEmpty else { return nil }

            let (cleanLines, credits) = LRCParser.shared.extractCredits(from: origLines)
            guard !cleanLines.isEmpty else { return nil }

            var finalLines = cleanLines
            if let rawTrans = lyricDecoded.tlyric?.lyric, !rawTrans.isEmpty {
                let transLines = LRCParser.shared.parse(lrcContent: rawTrans)
                finalLines = LRCParser.shared.mergeTranslations(original: cleanLines, translation: transLines)
            }

            let resolvedTitle = songItem.song.name.isEmpty ? targetTitle : songItem.song.name
            let resolvedArtist = songItem.artistName.isEmpty ? targetArtist : songItem.artistName

            return SyncedLyrics(
                trackTitle: resolvedTitle,
                artistName: resolvedArtist,
                lines: finalLines,
                credits: credits,
                offsetMs: 0,
                source: "NetEase"
            )
        } catch {
            print("[LyricsProvider] 網易雲歌詞解析失敗: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - PetitLyrics API 請求（WSY 逐字 + LSY 逐行 + 雙重把關）
    public func fetchCandidatesFromPetitLyrics(title: String, artist: String, durationSec: TimeInterval = 0, maxCount: Int = 3) async -> [SyncedLyrics] {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return [] }

        var candidates = await requestPetitLyricsCandidates(
            title: cleanTitle,
            artist: cleanArtist,
            lyricsType: 3,
            maxCount: 8
        )
        var resolvedQueryTitle = cleanTitle
        var resolvedQueryArtist = cleanArtist

        func hasPassingCandidate(_ list: [PetitLyricsCandidate]) -> Bool {
            list.contains {
                MetadataNormalizer.evaluateCandidateMatch(
                    targetTitle: cleanTitle,
                    targetArtist: cleanArtist,
                    targetDuration: durationSec,
                    candidateTitle: $0.title,
                    candidateArtist: $0.artist,
                    candidateDuration: $0.durationSec,
                    isWordSync: $0.lyricsType == 3 || $0.availableLyricsType == 3
                ) != nil
            }
        }

        if !hasPassingCandidate(candidates) {
            let variants = MetadataNormalizer.extractQueryVariants(title: cleanTitle, artist: cleanArtist)
            var fallbackQueries: [(title: String, artist: String)] = []

            if variants.primaryTitle != cleanTitle && !variants.primaryTitle.isEmpty {
                fallbackQueries.append((variants.primaryTitle, variants.primaryArtist))
            }
            if let sec = variants.secondaryTitle, !sec.isEmpty {
                fallbackQueries.append((sec, variants.primaryArtist))
                fallbackQueries.append((sec, ""))
            }

            if !cleanArtist.isEmpty {
                let combinedTitle = "\(cleanTitle) \(cleanArtist)"
                fallbackQueries.append((combinedTitle, ""))
                fallbackQueries.append((cleanTitle, ""))
            }

            var seenPairs: Set<String> = ["\(cleanTitle)\u{0}\(cleanArtist)"]
            for queryPair in fallbackQueries {
                let key = "\(queryPair.title)\u{0}\(queryPair.artist)"
                guard seenPairs.insert(key).inserted else { continue }

                let retryCandidates = await requestPetitLyricsCandidates(
                    title: queryPair.title,
                    artist: queryPair.artist,
                    lyricsType: 3,
                    maxCount: 8
                )
                if hasPassingCandidate(retryCandidates) {
                    candidates = retryCandidates
                    resolvedQueryTitle = queryPair.title
                    resolvedQueryArtist = queryPair.artist
                    break
                } else if candidates.isEmpty && !retryCandidates.isEmpty {
                    candidates = retryCandidates
                    resolvedQueryTitle = queryPair.title
                    resolvedQueryArtist = queryPair.artist
                }
            }
        }

        let syncedCandidates = candidates.filter {
            $0.lyricsType == 3 || $0.lyricsType == 2 || $0.availableLyricsType == 3 || $0.availableLyricsType == 2
        }
        guard !syncedCandidates.isEmpty else { return [] }

        var scoredCandidates: [(candidate: PetitLyricsCandidate, score: Double, index: Int)] = []
        for (index, cand) in syncedCandidates.enumerated() {
            let isWord = cand.lyricsType == 3 || cand.availableLyricsType == 3
            if let score = MetadataNormalizer.evaluateCandidateMatch(
                targetTitle: cleanTitle,
                targetArtist: cleanArtist,
                targetDuration: durationSec,
                candidateTitle: cand.title,
                candidateArtist: cand.artist,
                candidateDuration: cand.durationSec,
                isWordSync: isWord
            ) {
                scoredCandidates.append((cand, score, index))
            }
        }

        guard !scoredCandidates.isEmpty else { return [] }

        let sorted = scoredCandidates.sorted {
            let isWord0 = $0.candidate.lyricsType == 3 || $0.candidate.availableLyricsType == 3
            let isWord1 = $1.candidate.lyricsType == 3 || $1.candidate.availableLyricsType == 3
            if isWord0 != isWord1 {
                return isWord0 && !isWord1
            }
            if $0.score != $1.score {
                return $0.score > $1.score
            }
            return $0.index < $1.index
        }.map { $0.candidate }

        var results: [SyncedLyrics] = []
        for candidate in sorted {
            if let origLines = await decodePetitLyricsCandidate(candidate), !origLines.isEmpty {
                let (cleanLines, extractedCredits) = LRCParser.shared.extractCredits(from: origLines)
                let finalLines = cleanLines.isEmpty ? origLines : cleanLines
                guard !finalLines.isEmpty else { continue }

                var credits = extractedCredits
                if !candidate.writer.isEmpty {
                    let writerCredit = "Written by \(candidate.writer)"
                    if !credits.contains(writerCredit) {
                        credits.append(writerCredit)
                    }
                }
                if !candidate.composer.isEmpty {
                    let composerCredit = "Composed by \(candidate.composer)"
                    if !credits.contains(composerCredit) {
                        credits.append(composerCredit)
                    }
                }

                let resolvedTitle = candidate.title.isEmpty ? resolvedQueryTitle : candidate.title
                let resolvedArtist = candidate.artist.isEmpty ? (cleanArtist.isEmpty ? resolvedQueryArtist : cleanArtist) : candidate.artist

                let synced = SyncedLyrics(
                    trackTitle: resolvedTitle,
                    artistName: resolvedArtist,
                    lines: finalLines,
                    credits: credits,
                    offsetMs: 0,
                    source: "PetitLyrics"
                )
                results.append(synced)
                if results.count >= maxCount {
                    break
                }
            }
        }

        return results
    }

    public func fetchFromPetitLyrics(title: String, artist: String, durationSec: TimeInterval = 0) async -> SyncedLyrics? {
        await fetchCandidatesFromPetitLyrics(title: title, artist: artist, durationSec: durationSec, maxCount: 1).first
    }

    private func decodePetitLyricsCandidate(_ candidate: PetitLyricsCandidate) async -> [LyricLine]? {
        if candidate.lyricsType == 3 || candidate.availableLyricsType == 3 {
            var wsyBase64 = (candidate.lyricsType == 3) ? candidate.lyricsData : ""
            if wsyBase64.isEmpty, !candidate.lyricsId.isEmpty {
                let wsyCandidates = await requestPetitLyricsCandidates(
                    title: "",
                    artist: "",
                    lyricsId: candidate.lyricsId,
                    lyricsType: 3,
                    maxCount: 1
                )
                wsyBase64 = wsyCandidates.first(where: { $0.lyricsType == 3 && !$0.lyricsData.isEmpty })?.lyricsData ?? ""
            }
            if !wsyBase64.isEmpty,
               let xmlData = Data(base64Encoded: wsyBase64, options: .ignoreUnknownCharacters),
               let wsyXML = String(data: xmlData, encoding: .utf8) {
                let lines = LRCParser.shared.parsePetitLyricsWSY(wsyXML: wsyXML)
                if !lines.isEmpty {
                    return lines
                }
            }
        }

        if candidate.lyricsType == 2 || candidate.availableLyricsType == 2 || !candidate.lyricsId.isEmpty {
            var lsyBase64 = (candidate.lyricsType == 2) ? candidate.lyricsData : ""
            if lsyBase64.isEmpty, !candidate.lyricsId.isEmpty {
                let lsyCandidates = await requestPetitLyricsCandidates(
                    title: "",
                    artist: "",
                    lyricsId: candidate.lyricsId,
                    lyricsType: 2,
                    maxCount: 1
                )
                lsyBase64 = lsyCandidates.first(where: { $0.lyricsType == 2 && !$0.lyricsData.isEmpty })?.lyricsData ?? ""
            }
            guard !lsyBase64.isEmpty,
                  let plainBase64 = await fetchPetitLyricsPlainText(for: candidate),
                  !plainBase64.isEmpty else {
                return nil
            }
            let lines = LRCParser.shared.decodePetitLyricsLSY(
                lsyBase64: lsyBase64,
                plainLyricsBase64: plainBase64
            )
            return lines.isEmpty ? nil : lines
        }

        return nil
    }

    private func fetchPetitLyricsPlainText(for candidate: PetitLyricsCandidate) async -> String? {
        if !candidate.lyricsId.isEmpty {
            let byId = await requestPetitLyricsCandidates(
                title: "",
                artist: "",
                lyricsId: candidate.lyricsId,
                lyricsType: 1,
                maxCount: 1
            )
            if let match = byId.first(where: { $0.lyricsType == 1 && !$0.lyricsData.isEmpty }) {
                return match.lyricsData
            }
        }

        let byMeta = await requestPetitLyricsCandidates(
            title: candidate.title,
            artist: candidate.artist,
            album: candidate.album,
            lyricsType: 1,
            maxCount: 1
        )
        return byMeta.first(where: { $0.lyricsType == 1 && !$0.lyricsData.isEmpty })?.lyricsData
    }

    private func requestPetitLyricsCandidates(
        title: String,
        artist: String,
        album: String = "",
        lyricsId: String = "",
        lyricsType: Int,
        maxCount: Int
    ) async -> [PetitLyricsCandidate] {
        guard let url = URL(string: "https://p1.petitlyrics.com/api/GetPetitLyricsData.php") else {
            return []
        }

        var formItems: [URLQueryItem] = [
            URLQueryItem(name: "clientAppId", value: "p1110417"),
            URLQueryItem(name: "terminalType", value: "10"),
            URLQueryItem(name: "lyricsType", value: String(lyricsType)),
            URLQueryItem(name: "maxcount", value: String(maxCount)),
            URLQueryItem(name: "maxCount", value: String(maxCount))
        ]

        if !lyricsId.isEmpty {
            formItems.append(URLQueryItem(name: "key_lyricsId", value: lyricsId))
        } else {
            formItems.append(URLQueryItem(name: "key_title", value: title))
            if !artist.isEmpty {
                formItems.append(URLQueryItem(name: "key_artist", value: artist))
            }
            if !album.isEmpty {
                formItems.append(URLQueryItem(name: "key_album", value: album))
            }
        }

        var formComponents = URLComponents()
        formComponents.queryItems = formItems
        guard let bodyString = formComponents.percentEncodedQuery,
              let bodyData = bodyString.data(using: .utf8) else {
            return []
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("AuraLyrics-iOS-OpenSource/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = bodyData
        request.timeoutInterval = 8

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return []
            }
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            let delegate = PetitLyricsResponseXMLDelegate()
            parser.delegate = delegate
            guard parser.parse() else { return [] }
            return delegate.candidates
        } catch {
            print("[LyricsProvider] PetitLyrics 請求失敗: \(error.localizedDescription)")
            return []
        }
    }
}

// MARK: - 元資料正規化與候選匹配雙重把關引擎
public struct MetadataNormalizer {
    public static func foldText(_ text: String) -> String {
        var transformed = text
        let primaryTransform = StringTransform("Hant-Hans")
        if let t1 = transformed.applyingTransform(primaryTransform, reverse: false) {
            transformed = t1
        } else {
            let fallbackTransform = StringTransform("Traditional-Simplified")
            if let t2 = transformed.applyingTransform(fallbackTransform, reverse: false) {
                transformed = t2
            }
        }
        if let t3 = transformed.applyingTransform(.fullwidthToHalfwidth, reverse: false) {
            transformed = t3
        }
        let lower = transformed.lowercased()
        var stripped = ""
        for scalar in lower.unicodeScalars {
            if CharacterSet.punctuationCharacters.contains(scalar) ||
               CharacterSet.whitespacesAndNewlines.contains(scalar) ||
               CharacterSet.symbols.contains(scalar) ||
               scalar.value == 0x3000 || // 全形空白
               scalar.value == 0x3001 || // 、
               scalar.value == 0x3002 || // 。
               scalar.value == 0xFF08 || // （
               scalar.value == 0xFF09 || // ）
               scalar.value == 0x300C || // 「
               scalar.value == 0x300D || // 」
               scalar.value == 0x300E || // 『
               scalar.value == 0x300F || // 』
               scalar.value == 0x3010 || // 【
               scalar.value == 0x3011    // 】
            {
                continue
            }
            stripped.unicodeScalars.append(scalar)
        }
        return stripped
    }

    public static func extractQueryVariants(title: String, artist: String) -> (primaryTitle: String, secondaryTitle: String?, primaryArtist: String, searchVariants: [String]) {
        var cleanTitle = title
        // 1. 移除常見干擾標籤 (支援半形與全形括號)
        let noisePatterns = [
            #"(?i)[\(\[\{（【「『〔［]\s*(?:feat\.|ft\.|featuring|prod\.|produced by)[^\)\]\}）】」』〕］]+[\)\]\}）】」』〕］]"#,
            #"(?i)\b(?:feat\.|ft\.|featuring|prod\.|produced by)\b[^\-]+"#,
            #"(?i)-\s*Single\b"#,
            #"(?i)-\s*EP\b"#,
            #"(?i)-\s*From\s+"[^"]+""#,
            #"(?i)-\s*From\s+THE\s+FIRST\s+TAKE\b"#,
            #"(?i)-\s*Remaster(?:ed)?(?:\s*\d+)?\b"#,
            #"[\(（【「『〔［](?:電影|電視劇|動畫|動漫|網劇|插曲|片尾曲|主題曲|主題歌|OP|ED|OST|Original Soundtrack)[^）\)】」』〕］]*[\)）】」』〕］]"#,
            #"(?i)-\s*TV\s*Size\b"#,
            #"(?i)-\s*Anime\s*Ver(?:\.|\b)"#
        ]
        for pattern in noisePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(cleanTitle.startIndex..<cleanTitle.endIndex, in: cleanTitle)
                cleanTitle = regex.stringByReplacingMatches(in: cleanTitle, options: [], range: range, withTemplate: "")
            }
        }
        cleanTitle = cleanTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanTitle.isEmpty {
            cleanTitle = title
        }

        // 2. 拆解雙語或括號別名 (如 "Idol (アイドル)", "光るなら (Your Lie in April)")
        var primary = cleanTitle
        var secondary: String? = nil

        let bracketPattern = #"^(.+?)\s*[\(（【「『〔［]([^\)）】」』〕］]+)[\)）】」』〕］]$"#
        if let regex = try? NSRegularExpression(pattern: bracketPattern, options: []),
           let match = regex.firstMatch(in: cleanTitle, options: [], range: NSRange(cleanTitle.startIndex..<cleanTitle.endIndex, in: cleanTitle)) {
            if let r1 = Range(match.range(at: 1), in: cleanTitle),
               let r2 = Range(match.range(at: 2), in: cleanTitle) {
                let p = String(cleanTitle[r1]).trimmingCharacters(in: .whitespacesAndNewlines)
                let s = String(cleanTitle[r2]).trimmingCharacters(in: .whitespacesAndNewlines)
                let sLower = s.lowercased()
                let modifiers = ["live", "remix", "instrumental", "acoustic", "ver", "version", "edit", "karaoke", "off vocal", "cover", "deluxe", "bonus", "feat", "ft", "prod"]
                if !modifiers.contains(where: { sLower.contains($0) }) {
                    primary = p
                    secondary = s
                } else {
                    primary = p
                }
            }
        }

        // 3. 提取主歌手
        var primaryArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let artistDelimiters = [", ", " / ", " & ", " × ", " feat. ", " feat ", " ft. ", " (CV: ", " (CV.", " CV: "]
        for delim in artistDelimiters {
            if let r = primaryArtist.range(of: delim, options: .caseInsensitive) {
                primaryArtist = String(primaryArtist[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        if primaryArtist.isEmpty {
            primaryArtist = artist
        }

        // 4. 建構查詢候選
        var variants: [String] = []
        let rawCombined = "\(title) \(artist)".trimmingCharacters(in: .whitespacesAndNewlines)
        variants.append(rawCombined)

        let cleanCombined = "\(primary) \(primaryArtist)".trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanCombined != rawCombined && !cleanCombined.isEmpty {
            variants.append(cleanCombined)
        }

        if let sec = secondary, !sec.isEmpty {
            let secCombined = "\(sec) \(primaryArtist)".trimmingCharacters(in: .whitespacesAndNewlines)
            if !variants.contains(secCombined) {
                variants.append(secCombined)
            }
            if !variants.contains(sec) {
                variants.append(sec)
            }
        }

        if !variants.contains(primary) && !primary.isEmpty {
            variants.append(primary)
        }

        return (primary, secondary, primaryArtist, variants)
    }

    public static func bigramDiceSimilarity(_ s1: String, _ s2: String) -> Double {
        if s1 == s2 { return 1.0 }
        if s1.isEmpty || s2.isEmpty { return 0.0 }
        let a1 = Array(s1)
        let a2 = Array(s2)
        if a1.count == 1 || a2.count == 1 {
            return s1 == s2 ? 1.0 : (s1.contains(s2) || s2.contains(s1) ? 0.7 : 0.0)
        }

        var bigrams1: [String: Int] = [:]
        for i in 0..<(a1.count - 1) {
            let bg = String([a1[i], a1[i + 1]])
            bigrams1[bg, default: 0] += 1
        }

        var matches = 0
        var total2 = 0
        for i in 0..<(a2.count - 1) {
            let bg = String([a2[i], a2[i + 1]])
            total2 += 1
            if let count = bigrams1[bg], count > 0 {
                matches += 1
                bigrams1[bg] = count - 1
            }
        }

        let total1 = a1.count - 1
        return (2.0 * Double(matches)) / Double(total1 + total2)
    }

    public static func evaluateCandidateMatch(
        targetTitle: String,
        targetArtist: String,
        targetDuration: TimeInterval,
        candidateTitle: String,
        candidateArtist: String,
        candidateDuration: TimeInterval,
        candidateAliases: [String] = [],
        isWordSync: Bool = false
    ) -> Double? {
        let (primaryTarget, secondaryTarget, primaryTargetArt, _) = extractQueryVariants(title: targetTitle, artist: targetArtist)
        let foldedTargets = [
            foldText(targetTitle),
            foldText(primaryTarget),
            secondaryTarget != nil ? foldText(secondaryTarget!) : ""
        ].filter { !$0.isEmpty }

        let (primaryCand, secondaryCand, _, _) = extractQueryVariants(title: candidateTitle, artist: candidateArtist)
        var allCandTitles = [candidateTitle, primaryCand]
        if let secCand = secondaryCand {
            allCandTitles.append(secCand)
        }
        allCandTitles.append(contentsOf: candidateAliases)

        let foldedCandidates = allCandTitles.map { foldText($0) }.filter { !$0.isEmpty }

        guard !foldedTargets.isEmpty && !foldedCandidates.isEmpty else { return nil }

        // 1. 歌名比對
        var bestTitleSim: Double = 0.0
        var titleScoreBonus: Double = 0.0

        for t in foldedTargets {
            for c in foldedCandidates {
                if t == c {
                    bestTitleSim = 1.0
                    titleScoreBonus = max(titleScoreBonus, 45.0)
                } else if t.contains(c) || c.contains(t) {
                    let minLen = Double(min(t.count, c.count))
                    let maxLen = Double(max(t.count, c.count))
                    let ratio = maxLen > 0 ? (minLen / maxLen) : 0
                    if ratio >= 0.5 {
                        bestTitleSim = max(bestTitleSim, 0.85)
                        titleScoreBonus = max(titleScoreBonus, 30.0)
                    } else {
                        bestTitleSim = max(bestTitleSim, ratio * 0.8)
                        titleScoreBonus = max(titleScoreBonus, 15.0)
                    }
                } else {
                    let sim = bigramDiceSimilarity(t, c)
                    if sim > bestTitleSim {
                        bestTitleSim = sim
                        if sim >= 0.65 {
                            titleScoreBonus = max(titleScoreBonus, 20.0 * sim)
                        }
                    }
                }
            }
        }

        // 硬性門檻 1: 歌名折疊後相似度 < 0.45 直接淘汰 (阻絕張冠李戴)
        if bestTitleSim < 0.45 {
            return nil
        }

        // 2. 版本衝突與伴奏檢驗
        let targetTitleLower = targetTitle.lowercased()
        let candTitleLower = candidateTitle.lowercased()

        let isTargetInst = targetTitleLower.contains("instrumental") || targetTitleLower.contains("伴奏") || targetTitleLower.contains("karaoke") || targetTitleLower.contains("カラオケ") || targetTitleLower.contains("off vocal")
        let isCandInst = candTitleLower.contains("instrumental") || candTitleLower.contains("伴奏") || candTitleLower.contains("karaoke") || candTitleLower.contains("カラオケ") || candTitleLower.contains("off vocal")

        if !isTargetInst && isCandInst {
            return nil // 目標為原曲，候選為伴奏，硬性淘汰
        }

        var versionPenalty: Double = 0.0
        let isTargetLive = targetTitleLower.contains("live")
        let isCandLive = candTitleLower.contains("live")
        if !isTargetLive && isCandLive {
            versionPenalty += 60.0
        }

        let isTargetRemix = targetTitleLower.contains("remix")
        let isCandRemix = candTitleLower.contains("remix")
        if !isTargetRemix && isCandRemix {
            versionPenalty += 50.0
        }

        let isTargetCover = targetTitleLower.contains("cover") || targetTitleLower.contains("翻唱")
        let isCandCover = candTitleLower.contains("cover") || candTitleLower.contains("翻唱")
        if !isTargetCover && isCandCover {
            versionPenalty += 60.0
        }

        // 3. 時長誤差檢驗
        var durationScore: Double = 0.0
        var diff: Double = 0.0
        if targetDuration > 0 && candidateDuration > 0 {
            diff = abs(candidateDuration - targetDuration)
            if !isTargetLive && diff > 12.0 {
                return nil // 非 Live 時長誤差 > 12 秒，硬性淘汰
            }
            if diff < 3.0 {
                durationScore = 40.0
            } else if diff < 6.0 {
                durationScore = 20.0
            } else if diff < 10.0 {
                durationScore = 5.0
            } else {
                durationScore = -25.0
            }
        }

        // 4. 歌手匹配檢驗
        var artistScore: Double = 0.0
        let foldedTargetArt = foldText(targetArtist)
        let foldedPrimaryTargetArt = foldText(primaryTargetArt)
        let foldedCandArt = foldText(candidateArtist)

        if !foldedCandArt.isEmpty && (!foldedTargetArt.isEmpty || !foldedPrimaryTargetArt.isEmpty) {
            let match1 = !foldedTargetArt.isEmpty && (foldedCandArt.contains(foldedTargetArt) || foldedTargetArt.contains(foldedCandArt))
            let match2 = !foldedPrimaryTargetArt.isEmpty && (foldedCandArt.contains(foldedPrimaryTargetArt) || foldedPrimaryTargetArt.contains(foldedCandArt))

            if match1 || match2 {
                artistScore = 25.0
            } else {
                // 若歌名極短 (<= 3 字) 且歌名僅部分相似 (sim < 0.8)，歌手又完全不同且時長差 > 3.5s，判定為同名異曲淘汰
                if targetTitle.count <= 3 && bestTitleSim < 0.8 && (targetDuration == 0 || diff > 3.5) {
                    return nil
                }
                artistScore = -20.0
            }
        }

        let baseScore = 50.0
        let wordSyncBonus = isWordSync ? 25.0 : 0.0
        let totalScore = baseScore + titleScoreBonus + durationScore + artistScore + wordSyncBonus - versionPenalty

        if totalScore < 70.0 {
            return nil
        }
        return totalScore
    }
}

// MARK: - PetitLyrics API 回應模型與 XML 解析器
private struct PetitLyricsCandidate {
    var lyricsId: String = ""
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var writer: String = ""
    var composer: String = ""
    var lyricsType: Int = 0
    var availableLyricsType: Int = 0
    var durationSec: Double = 0
    var lyricsData: String = ""
}

private final class PetitLyricsResponseXMLDelegate: NSObject, XMLParserDelegate {
    var candidates: [PetitLyricsCandidate] = []

    private var currentElement = ""
    private var inSong = false
    private var currentCandidate = PetitLyricsCandidate()
    private var currentText = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        currentText = ""
        if elementName == "song" {
            inSong = true
            currentCandidate = PetitLyricsCandidate()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inSong, !currentElement.isEmpty else { return }
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard inSong else { return }
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "lyricsId":
            currentCandidate.lyricsId = trimmed
        case "title":
            currentCandidate.title = trimmed
        case "artist":
            currentCandidate.artist = trimmed
        case "album":
            currentCandidate.album = trimmed
        case "writer":
            currentCandidate.writer = trimmed
        case "composer":
            currentCandidate.composer = trimmed
        case "lyricsType":
            currentCandidate.lyricsType = Int(trimmed) ?? 0
        case "availableLyricsType":
            currentCandidate.availableLyricsType = Int(trimmed) ?? 0
        case "duration", "trackDuration":
            if let rawDur = Double(trimmed), rawDur > 0 {
                currentCandidate.durationSec = rawDur > 2000 ? (rawDur / 1000.0) : rawDur
            }
        case "lyricsData":
            currentCandidate.lyricsData = trimmed
        case "song":
            if !currentCandidate.lyricsData.isEmpty || !currentCandidate.lyricsId.isEmpty {
                candidates.append(currentCandidate)
            }
            inSong = false
        default:
            break
        }
        currentElement = ""
        currentText = ""
    }
}
