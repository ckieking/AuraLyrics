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
            for def in LyricsSearchPriorityItem.defaultList {
                if !existingIds.contains(def.id) {
                    list.append(def)
                }
            }
            self.priorityItems = list
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

        async let mxmTask = fetchFromMusixmatch(title: trimmed, artist: "", durationSec: durationSec)
        async let netEaseTask = fetchFromNetEase(title: trimmed, artist: "", durationSec: durationSec)
        async let lrclibTask = fetchFromLRCLIB(title: trimmed, artist: "", durationSec: durationSec)

        let (mxmResult, netEaseResult, lrclibResult) = await (mxmTask, netEaseTask, lrclibTask)
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
}
