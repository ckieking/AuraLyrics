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
        let lines = LRCParser.shared.parse(lrcContent: content)
        guard !lines.isEmpty else { return nil }

        let synced = SyncedLyrics(
            trackTitle: title,
            artistName: artist,
            lines: lines,
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

    // MARK: - 線上自動搜尋歌詞（優先查詢快取 -> LRCLIB -> 網易雲）
    public func fetchLyrics(track: TrackInfo) async -> SyncedLyrics? {
        let cleanTitle = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanTitle.isEmpty else { return nil }

        // 1. 檢查本地快取
        if let cached = loadCachedLyrics(title: cleanTitle, artist: cleanArtist) {
            return cached
        }

        // 2. 查詢 LRCLIB
        if let lrclibResult = await fetchFromLRCLIB(title: cleanTitle, artist: cleanArtist, durationSec: track.duration) {
            saveLyricsToCache(lrclibResult)
            return lrclibResult
        }

        // 3. 備援查詢 網易雲音樂公開 API（含雙語翻譯）
        if let netEaseResult = await fetchFromNetEase(title: cleanTitle, artist: cleanArtist) {
            saveLyricsToCache(netEaseResult)
            return netEaseResult
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
                let lines = LRCParser.shared.parse(lrcContent: synced)
                if !lines.isEmpty {
                    return SyncedLyrics(
                        trackTitle: title,
                        artistName: artist,
                        lines: lines,
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

    // MARK: - 網易雲音樂公開 API 請求（搜尋曲目與歌詞 + 翻譯）
    public func fetchFromNetEase(title: String, artist: String) async -> SyncedLyrics? {
        let searchQuery = "\(title) \(artist)".trimmingCharacters(in: .whitespaces)
        guard var searchComponents = URLComponents(string: "https://music.163.com/api/search/get/web") else { return nil }
        searchComponents.queryItems = [
            URLQueryItem(name: "csrf_token", value: ""),
            URLQueryItem(name: "s", value: searchQuery),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "total", value: "true"),
            URLQueryItem(name: "limit", value: "3")
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
                    }
                    let songs: [Song]?
                }
                let result: ResultData?
            }

            let searchDecoded = try JSONDecoder().decode(NetEaseSearchResult.self, from: searchData)
            guard let songId = searchDecoded.result?.songs?.first?.id else {
                return nil
            }

            // 請求歌詞
            guard let lyricUrl = URL(string: "https://music.163.com/api/song/lyric?os=pc&id=\(songId)&lv=-1&kv=-1&tv=-1") else {
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
            }

            let lyricDecoded = try JSONDecoder().decode(NetEaseLyricResponse.self, from: lyricData)
            guard let rawLrc = lyricDecoded.lrc?.lyric, !rawLrc.isEmpty else {
                return nil
            }

            let origLines = LRCParser.shared.parse(lrcContent: rawLrc)
            var finalLines = origLines

            if let rawTrans = lyricDecoded.tlyric?.lyric, !rawTrans.isEmpty {
                let transLines = LRCParser.shared.parse(lrcContent: rawTrans)
                finalLines = LRCParser.shared.mergeTranslations(original: origLines, translation: transLines)
            }

            if !finalLines.isEmpty {
                return SyncedLyrics(
                    trackTitle: title,
                    artistName: artist,
                    lines: finalLines,
                    offsetMs: 0,
                    source: "NetEase"
                )
            }
        } catch {
            print("[LyricsProvider] 網易雲請求失敗: \(error.localizedDescription)")
        }

        return nil
    }
}
