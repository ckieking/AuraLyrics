import Foundation
import Combine

/// 歌詞來源與本地快取管理器（純手機端連線，無須後端伺服器）
public final class LyricsProviderService: ObservableObject {
    public static let shared = LyricsProviderService()

    private let cacheDirectoryName = "LyricsCache"
    private let urlSession = URLSession.shared

    private init() {
        createCacheDirectoryIfNeeded()
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
        let fileURL = cacheFileURL(title: lyrics.trackTitle, artist: lyrics.artistName)
        if let data = try? JSONEncoder().encode(lyrics) {
            try? data.write(to: fileURL)
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

    // MARK: - 線上自動搜尋歌詞（優先查詢具備逐字音節來源 -> 自動升級舊快取）
    public func fetchLyrics(track: TrackInfo) async -> SyncedLyrics? {
        let cleanTitle = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanTitle.isEmpty else { return nil }

        let cached = loadCachedLyrics(title: cleanTitle, artist: cleanArtist)

        // 1. 若本地快取已包含逐字音節時間軸，或為使用者本地手動匯入，直接採用
        if let cached = cached, (cached.hasSyllables || cached.source == "Local") {
            return cached
        }

        // 2. 優先向網易雲音樂請求原生逐字時間軸 (YRC/KRC) 與雙語翻譯
        if let netEaseResult = await fetchFromNetEase(title: cleanTitle, artist: cleanArtist, durationSec: track.duration) {
            if netEaseResult.hasSyllables {
                saveLyricsToCache(netEaseResult)
                return netEaseResult
            }
            // 若網易雲僅有普通行級歌詞，但本地尚無任何快取，暫存該備援結果
            if cached == nil {
                saveLyricsToCache(netEaseResult)
            }
        }

        // 3. 查詢 LRCLIB 嘗試比對 Enhanced LRC 逐字標籤
        if let lrclibResult = await fetchFromLRCLIB(title: cleanTitle, artist: cleanArtist, durationSec: track.duration) {
            if lrclibResult.hasSyllables {
                saveLyricsToCache(lrclibResult)
                return lrclibResult
            }
            if cached == nil {
                saveLyricsToCache(lrclibResult)
                return lrclibResult
            }
        }

        // 4. 若無逐字來源，回退至既有快取或普通行級歌詞
        if let cached = cached {
            return cached
        }

        return nil
    }

    // MARK: - LRCLIB API 請求
    private func fetchFromLRCLIB(title: String, artist: String, durationSec: TimeInterval) async -> SyncedLyrics? {
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
