import Foundation
import Combine

/// 歌詞來源與本地快取管理器（純手機端連線，無須後端伺服器）
public final class LyricsProviderService: ObservableObject {
    public static let shared = LyricsProviderService()

    private let cacheDirectoryName = "LyricsCache"
    private let urlSession = URLSession.shared

    private let currentCacheSchemaVersion = 2
    private let priorityOrderKey = "lyricsSearchPriorityOrder"
    private let prioritySchemaVersionKey = "lyricsSearchPrioritySchemaVersion"
    private let currentPrioritySchemaVersion = 2

    @Published public private(set) var priorityItems: [LyricsSearchPriorityItem] = []

    private init() {
        checkAndMigrateCache()
        createCacheDirectoryIfNeeded()
        loadPriorityItems()
    }

    private func loadPriorityItems() {
        let version = UserDefaults.standard.integer(forKey: prioritySchemaVersionKey)
        if version < currentPrioritySchemaVersion {
            self.priorityItems = LyricsSearchPriorityItem.defaultList
            UserDefaults.standard.set(currentPrioritySchemaVersion, forKey: prioritySchemaVersionKey)
            savePriorityItems(LyricsSearchPriorityItem.defaultList)
            return
        }

        if let data = UserDefaults.standard.data(forKey: priorityOrderKey),
           let saved = try? JSONDecoder().decode([LyricsSearchPriorityItem].self, from: data),
           !saved.isEmpty {
            var list = saved
            let existingIds = Set(saved.map { $0.id })
            var didInsertNewDefaults = false
            for def in LyricsSearchPriorityItem.defaultList {
                if !existingIds.contains(def.id) {
                    if def.isWordSync, let lastWordIdx = list.lastIndex(where: { $0.isWordSync }) {
                        list.insert(def, at: lastWordIdx + 1)
                    } else {
                        list.append(def)
                    }
                    didInsertNewDefaults = true
                }
            }
            self.priorityItems = list
            if didInsertNewDefaults {
                savePriorityItems(list)
            }
        } else {
            self.priorityItems = LyricsSearchPriorityItem.defaultList
            UserDefaults.standard.set(currentPrioritySchemaVersion, forKey: prioritySchemaVersionKey)
        }
    }

    public func savePriorityItems(_ items: [LyricsSearchPriorityItem]) {
        self.priorityItems = items
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: priorityOrderKey)
        }
    }

    public func resetPriorityItems() {
        savePriorityItems(LyricsSearchPriorityItem.defaultList)
    }

    public var highestPriorityDescription: String {
        if let first = priorityItems.first(where: { $0.isEnabled }) {
            return "\(first.title)（\(first.isWordSync ? String(localized: "逐字") : String(localized: "逐行"))）"
        }
        return String(localized: "已停用所有來源")
    }

    private func checkAndMigrateCache() {
        let storedVersion = UserDefaults.standard.integer(forKey: "lyricsCacheSchemaVersion")
        if storedVersion < currentCacheSchemaVersion {
            // 升級至支援時長與歌手評分比對之快取架構，自動清理舊版本未評分之快取
            try? FileManager.default.removeItem(at: cacheDirectoryURL)
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
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SyncedLyrics.self, from: data)
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
    }

    public func clearAllCache() {
        try? FileManager.default.removeItem(at: cacheDirectoryURL)
        createCacheDirectoryIfNeeded()
    }

    // MARK: - 線上自動搜尋歌詞（依使用者自訂平台與逐字/逐行順位搜尋）
    public func fetchLyrics(track: TrackInfo) async -> SyncedLyrics? {
        let cleanTitle = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanTitle.isEmpty else { return nil }

        let cached = loadCachedLyrics(title: cleanTitle, artist: cleanArtist)

        // 1. 若為使用者本地手動匯入，絕對優先採用
        if let cached = cached, cached.source == "Local" {
            return cached
        }

        let activePriorities = priorityItems.filter { $0.isEnabled }

        // 2. 若本地快取已符合使用者最高優先級別且具備逐字，可直接沿用節省連線與電量
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

        // 4. 依使用者自訂順位依序比對
        for item in activePriorities {
            guard let result = await getOrFetch(source: item.source) else {
                continue
            }

            if item.isWordSync {
                // 逐字項目：必須包含音節時間軸
                if result.hasSyllables {
                    saveLyricsToCache(result)
                    return result
                }
            } else {
                // 普通逐行項目：無論有無逐字皆可滿足降級標準
                saveLyricsToCache(result)
                return result
            }
        }

        // 5. 若所有啟用順位皆未滿足，回退至既有快取
        return cached
    }

    // MARK: - 手動搜尋跨庫歌詞（Structured Concurrency 並行請求，不污染快取直到使用者點選）
    public func searchOnlineLyrics(query: String, durationSec: TimeInterval = 0) async -> [SyncedLyrics] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // 若手動搜尋字串包含空白（例如「歌名 歌手」或「First Love 宇多田ヒカル」），以最後一個空白拆分歌名與歌手供 PetitLyrics 結構化查詢
        let petitTitle: String
        let petitArtist: String
        if let lastSpaceIdx = trimmed.lastIndex(where: { $0.isWhitespace }) {
            let head = String(trimmed[..<lastSpaceIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = String(trimmed[trimmed.index(after: lastSpaceIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            petitTitle = head.isEmpty ? trimmed : head
            petitArtist = head.isEmpty ? "" : tail
        } else {
            petitTitle = trimmed
            petitArtist = ""
        }

        async let mxmTask = fetchFromMusixmatch(title: trimmed, artist: "", durationSec: durationSec)
        async let netEaseTask = fetchFromNetEase(title: trimmed, artist: "", durationSec: durationSec)
        async let lrclibTask = fetchFromLRCLIB(title: trimmed, artist: "", durationSec: durationSec)
        async let petitTask = fetchFromPetitLyrics(title: petitTitle, artist: petitArtist, durationSec: durationSec)

        let (mxmResult, netEaseResult, lrclibResult, petitResult) = await (mxmTask, netEaseTask, lrclibTask, petitTask)
        var results: [SyncedLyrics] = []
        if let mxm = mxmResult {
            results.append(mxm)
        }
        if let netEase = netEaseResult, !results.contains(where: { $0.id == netEase.id }) {
            results.append(netEase)
        }
        if let lrclib = lrclibResult, !results.contains(where: { $0.id == lrclib.id }) {
            results.append(lrclib)
        }
        if let petit = petitResult, !results.contains(where: { $0.id == petit.id }) {
            results.append(petit)
        }
        return results
    }

    // MARK: - Musixmatch API 請求（免金鑰取得官方客戶端匿名憑證與 Richsync 逐字時間軸）
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

    public func fetchFromMusixmatch(title: String, artist: String, durationSec: TimeInterval = 0) async -> SyncedLyrics? {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return nil }

        guard let token = await getMusixmatchToken() else { return nil }

        return await performMusixmatchRequest(title: cleanTitle, artist: cleanArtist, durationSec: durationSec, token: token, allowRetryOn401: true)
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
            queryItems.append(URLQueryItem(name: "f_subtitle_length_max_deviation", value: "5"))
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

            // 解析 Musixmatch Macro 回應
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let message = json?["message"] as? [String: Any],
                  let header = message["header"] as? [String: Any],
                  let statusCode = header["status_code"] as? Int, statusCode == 200,
                  let body = message["body"] as? [String: Any],
                  let macroCalls = body["macro_calls"] as? [String: Any] else {
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
                        trackTitle: title,
                        artistName: artist,
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
                        trackTitle: title,
                        artistName: artist,
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

    // MARK: - LRCLIB API 請求
    public func fetchFromLRCLIB(title: String, artist: String, durationSec: TimeInterval) async -> SyncedLyrics? {
        guard var components = URLComponents(string: "https://lrclib.net/api/get") else { return nil }
        var queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        if durationSec > 0 {
            queryItems.append(URLQueryItem(name: "duration", value: String(Int(durationSec))))
        }
        components.queryItems = queryItems

        guard let url = components.url else { return nil }

        do {
            var request = URLRequest(url: url)
            request.setValue("AuraLyrics-iOS-OpenSource/1.0", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 8

            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }

            struct LRCLIBResponse: Codable {
                let syncedLyrics: String?
                let plainLyrics: String?
            }

            let decoded = try JSONDecoder().decode(LRCLIBResponse.self, from: data)
            if let synced = decoded.syncedLyrics, !synced.isEmpty {
                let (lines, credits) = LRCParser.shared.parseWithCredits(lrcContent: synced)
                if !lines.isEmpty {
                    return SyncedLyrics(
                        trackTitle: title,
                        artistName: artist,
                        lines: lines,
                        credits: credits,
                        offsetMs: 0,
                        source: "LRCLIB"
                    )
                }
            }
        } catch {
            print("[LyricsProvider] LRCLIB 請求失敗: \(error.localizedDescription)")
        }

        return nil
    }

    // MARK: - 網易雲音樂公開 API 請求（支援 YRC 原生逐字時間軸 + KRC + LRC + 雙語翻譯）
    public func fetchFromNetEase(title: String, artist: String, durationSec: TimeInterval = 0) async -> SyncedLyrics? {
        let searchQuery = "\(title) \(artist)".trimmingCharacters(in: .whitespaces)
        guard var searchComponents = URLComponents(string: "https://music.163.com/api/search/get/web") else { return nil }
        searchComponents.queryItems = [
            URLQueryItem(name: "csrf_token", value: ""),
            URLQueryItem(name: "s", value: searchQuery),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "total", value: "true"),
            URLQueryItem(name: "limit", value: "5")
        ]

        guard let searchUrl = searchComponents.url else { return nil }

        do {
            var searchRequest = URLRequest(url: searchUrl)
            searchRequest.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
            searchRequest.timeoutInterval = 8

            let (searchData, _) = try await urlSession.data(for: searchRequest)

            struct NetEaseSearchResult: Codable {
                struct ResultData: Codable {
                    struct Song: Codable {
                        let id: Int
                        let name: String
                        let duration: Int?
                        struct Artist: Codable {
                            let name: String?
                        }
                        let artists: [Artist]?
                    }
                    let songs: [Song]?
                }
                let result: ResultData?
            }

            let searchDecoded = try JSONDecoder().decode(NetEaseSearchResult.self, from: searchData)
            guard let candidateSongs = searchDecoded.result?.songs, !candidateSongs.isEmpty else {
                return nil
            }

            // 智慧最佳匹配演算法：精準命中原版，排除 Remix / Live / 伴奏干擾
            let targetTitleLower = title.lowercased()
            let targetArtistLower = artist.lowercased()

            let scoredSongs = candidateSongs.map { song -> (song: NetEaseSearchResult.ResultData.Song, score: Double) in
                let nameLower = song.name.lowercased()
                var score: Double = 100.0

                // 扣分項：原曲非 Remix/Live 但搜尋結果帶有
                if nameLower.contains("remix") && !targetTitleLower.contains("remix") {
                    score -= 50.0
                }
                if nameLower.contains("live") && !targetTitleLower.contains("live") {
                    score -= 40.0
                }
                if nameLower.contains("instrumental") || song.name.contains("伴奏") {
                    score -= 60.0
                }

                // 時長吻合加分（時長最能代表是否為同一錄音版本）
                if durationSec > 0, let songDurMs = song.duration, songDurMs > 0 {
                    let songDurSec = Double(songDurMs) / 1000.0
                    let diff = abs(songDurSec - durationSec)
                    if diff < 3.0 {
                        score += 40.0
                    } else if diff < 8.0 {
                        score += 15.0
                    } else {
                        score -= min(30.0, diff * 2.0)
                    }
                }

                // 歌手名稱匹配加分
                if let artists = song.artists {
                    let artistNames = artists.compactMap { $0.name }.joined(separator: " ").lowercased()
                    if artistNames.contains(targetArtistLower) || targetArtistLower.contains(artistNames) {
                        score += 20.0
                    }
                }

                return (song, score)
            }

            guard let bestSong = scoredSongs.max(by: { $0.score < $1.score })?.song else {
                return nil
            }
            let songId = bestSong.id

            // 請求歌詞：帶上 yv=-1 以取得網易雲 YRC 原生逐字時間軸
            guard let lyricUrl = URL(string: "https://music.163.com/api/song/lyric?os=pc&id=\(songId)&lv=-1&kv=-1&tv=-1&yv=-1") else {
                return nil
            }

            var lyricRequest = URLRequest(url: lyricUrl)
            lyricRequest.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
            lyricRequest.timeoutInterval = 8

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

            // 優先解析 YRC 逐字時間軸 -> KRC 逐字時間軸 -> 普通 LRC 行級時間軸
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

            guard !origLines.isEmpty else {
                return nil
            }

            // 分離製作名單 (Credits) 與滾動歌詞，杜絕作者資訊搶佔時間軸
            let (cleanLines, credits) = LRCParser.shared.extractCredits(from: origLines)
            guard !cleanLines.isEmpty else {
                return nil
            }

            var finalLines = cleanLines
            if let rawTrans = lyricDecoded.tlyric?.lyric, !rawTrans.isEmpty {
                let transLines = LRCParser.shared.parse(lrcContent: rawTrans)
                finalLines = LRCParser.shared.mergeTranslations(original: cleanLines, translation: transLines)
            }

            return SyncedLyrics(
                trackTitle: title,
                artistName: artist,
                lines: finalLines,
                credits: credits,
                offsetMs: 0,
                source: "NetEase"
            )
        } catch {
            print("[LyricsProvider] 網易雲請求失敗: \(error.localizedDescription)")
        }

        return nil
    }

    // MARK: - PetitLyrics API 請求（支援 WSY 逐字時間軸 XML + LSY 逐行二進位 XOR 解碼）
    // shortcut: README.md and README.zh-TW.md do not yet list PetitLyrics (WSY/LSY) as a supported lyrics source, update both README files before the next release
    public func fetchFromPetitLyrics(title: String, artist: String, durationSec: TimeInterval = 0) async -> SyncedLyrics? {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return nil }

        var candidates = await requestPetitLyricsCandidates(
            title: cleanTitle,
            artist: cleanArtist,
            lyricsType: 3,
            maxCount: 5
        )
        var resolvedQueryTitle = cleanTitle
        var resolvedQueryArtist = cleanArtist
        var usedAlternativeSplit = false

        func hasExactTitleMatch(_ list: [PetitLyricsCandidate], targetTitle: String) -> Bool {
            let normTarget = Self.normalizeComparisonText(targetTitle.lowercased())
            guard !normTarget.isEmpty else { return false }
            return list.contains {
                Self.normalizeComparisonText($0.title.lowercased()) == normTarget
            }
        }

        // 若含歌手查詢無結果或未命中完整歌名（如手動搜尋將含空白的多字歌名或複合歌手拆開，或羅馬拼音/日文歌手別名差異），依序降級重試
        if (!hasExactTitleMatch(candidates, targetTitle: cleanTitle) || candidates.isEmpty) && !cleanArtist.isEmpty {
            let combinedTitle = "\(cleanTitle) \(cleanArtist)"
            let tokens = combinedTitle.split(whereSeparator: { $0.isWhitespace }).map(String.init)

            var fallbackQueries: [(title: String, artist: String, isAltSplit: Bool)] = [
                (combinedTitle, "", true)
            ]
            if tokens.count >= 3 {
                let firstWordTitle = tokens[0]
                let restArtist = tokens.dropFirst().joined(separator: " ")
                fallbackQueries.append((firstWordTitle, restArtist, true))
            }
            if tokens.count >= 4 {
                let mid = tokens.count / 2
                let midTitle = tokens[..<mid].joined(separator: " ")
                let midArtist = tokens[mid...].joined(separator: " ")
                fallbackQueries.append((midTitle, midArtist, true))
            }
            fallbackQueries.append((cleanTitle, "", false))

            var seenPairs: Set<String> = ["\(cleanTitle)\u{0}\(cleanArtist)"]
            for queryPair in fallbackQueries {
                let key = "\(queryPair.title)\u{0}\(queryPair.artist)"
                guard seenPairs.insert(key).inserted else { continue }

                let retryCandidates = await requestPetitLyricsCandidates(
                    title: queryPair.title,
                    artist: queryPair.artist,
                    lyricsType: 3,
                    maxCount: 5
                )
                if hasExactTitleMatch(retryCandidates, targetTitle: queryPair.title) {
                    candidates = retryCandidates
                    resolvedQueryTitle = queryPair.title
                    resolvedQueryArtist = queryPair.artist
                    usedAlternativeSplit = queryPair.isAltSplit
                    break
                } else if candidates.isEmpty && !retryCandidates.isEmpty {
                    candidates = retryCandidates
                    resolvedQueryTitle = queryPair.title
                    resolvedQueryArtist = queryPair.artist
                    usedAlternativeSplit = queryPair.isAltSplit
                }
            }
        }

        // 僅保留具備時間軸（lyricsType = 3 逐字 WSY 或 lyricsType = 2 逐行 LSY）的候選項目
        let syncedCandidates = candidates.filter {
            $0.lyricsType == 3 || $0.lyricsType == 2 || $0.availableLyricsType == 3 || $0.availableLyricsType == 2
        }
        guard !syncedCandidates.isEmpty else { return nil }

        let targetTitleForScoring = resolvedQueryTitle
        let targetArtistForScoring = usedAlternativeSplit ? resolvedQueryArtist : cleanArtist
        let targetTitleLower = targetTitleForScoring.lowercased()
        let targetArtistLower = targetArtistForScoring.lowercased()
        let normTargetTitle = Self.normalizeComparisonText(targetTitleLower)
        let normTargetArtist = Self.normalizeComparisonText(targetArtistLower)

        // 依「逐字優先 + 時長誤差 + 歌手/標題匹配度」自動評分選出最佳版本
        let scoredCandidates = syncedCandidates.enumerated().map { (index, candidate) -> (candidate: PetitLyricsCandidate, score: Double, index: Int) in
            let candTitleLower = candidate.title.lowercased()
            let normCandTitle = Self.normalizeComparisonText(candTitleLower)
            let normCandArtist = Self.normalizeComparisonText(candidate.artist.lowercased())
            var score: Double = 100.0

            // 1. 排除非目標的 Remix / Live / 伴奏版本
            if candTitleLower.contains("remix") && !targetTitleLower.contains("remix") {
                score -= 50.0
            }
            if candTitleLower.contains("live") && !targetTitleLower.contains("live") {
                score -= 40.0
            }
            if candTitleLower.contains("instrumental") || candidate.title.contains("伴奏") || candidate.title.contains("カラオケ") || candTitleLower.contains("off vocal") {
                score -= 60.0
            }

            // 2. 逐字時間軸優先加分 (lyricsType = 3 WSY > lyricsType = 2 LSY)
            let effectiveType = (candidate.lyricsType == 3 || candidate.lyricsType == 2) ? candidate.lyricsType : candidate.availableLyricsType
            if effectiveType == 3 {
                score += 50.0
            } else if effectiveType == 2 {
                score += 20.0
            }

            // 3. 時長誤差評分
            if durationSec > 0, candidate.durationSec > 0 {
                let diff = abs(candidate.durationSec - durationSec)
                if diff < 3.0 {
                    score += 40.0
                } else if diff < 8.0 {
                    score += 15.0
                } else {
                    score -= min(30.0, diff * 2.0)
                }
            }

            // 4. 標題與歌手匹配度
            if !normTargetTitle.isEmpty && !normCandTitle.isEmpty {
                if normCandTitle == normTargetTitle {
                    score += 25.0
                } else if normCandTitle.contains(normTargetTitle) || normTargetTitle.contains(normCandTitle) {
                    score += 10.0
                } else {
                    score -= 35.0
                }
            }

            if !normTargetArtist.isEmpty && !normCandArtist.isEmpty {
                if normCandArtist == normTargetArtist {
                    score += 30.0
                } else if normCandArtist.contains(normTargetArtist) || normTargetArtist.contains(normCandArtist) {
                    score += 20.0
                }
            }

            return (candidate, score, index)
        }

        let sortedCandidates = scoredCandidates.sorted {
            if $0.score != $1.score {
                return $0.score > $1.score
            }
            return $0.index < $1.index
        }.map { $0.candidate }

        for candidate in sortedCandidates {
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

                let resolvedTitle: String
                let resolvedArtist: String
                if usedAlternativeSplit {
                    resolvedTitle = candidate.title.isEmpty ? resolvedQueryTitle : candidate.title
                    resolvedArtist = candidate.artist.isEmpty ? resolvedQueryArtist : candidate.artist
                } else {
                    resolvedTitle = cleanTitle
                    resolvedArtist = cleanArtist.isEmpty ? candidate.artist : cleanArtist
                }

                return SyncedLyrics(
                    trackTitle: resolvedTitle,
                    artistName: resolvedArtist,
                    lines: finalLines,
                    credits: credits,
                    offsetMs: 0,
                    source: "PetitLyrics"
                )
            }
        }

        return nil
    }

    private static func normalizeComparisonText(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
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
                // PetitLyrics API 回傳的 duration 通常為毫秒（如 213288 代表 213.288 秒）
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

