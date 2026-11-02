import Foundation
import UIKit
import WebKit
import Combine
import SwiftUI

// MARK: - 播放來源列舉
public enum PlaybackSource: String, CaseIterable, Identifiable, Codable, Sendable {
    case appleMusic = "appleMusic"
    case spotify = "spotify"

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .appleMusic:
            return String(localized: "Apple Music (系統播放器)")
        case .spotify:
            return String(localized: "Spotify (免 Client ID 雲端同步)")
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if raw == "spotifyWebAPI" || raw == "spotifyAppRemote" {
            self = .spotify
        } else {
            self = PlaybackSource(rawValue: raw) ?? .appleMusic
        }
    }
}

// MARK: - Spotify 即時播放狀態快照
public struct SpotifyTrackSnapshot: Equatable, Sendable {
    public let track: TrackInfo
    public let isPlaying: Bool
    public let progressMs: Int
    public let timestamp: CFTimeInterval

    public init(track: TrackInfo, isPlaying: Bool, progressMs: Int, timestamp: CFTimeInterval) {
        self.track = track
        self.isPlaying = isPlaying
        self.progressMs = progressMs
        self.timestamp = timestamp
    }
}

// MARK: - Spotify 服務管理中樞 (WebKit 內置登入與背景自動展期)
@MainActor
public final class SpotifyService: NSObject, ObservableObject {
    public static let shared = SpotifyService()

    public static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

    // MARK: - 狀態屬性
    @Published public private(set) var isLoggedIn: Bool = false
    @Published public private(set) var hasCapturedToken: Bool = false
    @Published public private(set) var isRefreshingToken: Bool = false
    @Published public private(set) var playerStatusText: String = String(localized: "尚未連線")

    public var isWebAPILoggedIn: Bool { isLoggedIn }

    // MARK: - 私有狀態與快取
    private var webAPIPollingTask: Task<Void, Never>?
    private var refreshTask: Task<String, Error>?
    private var backgroundWebView: WKWebView?
    private var tokenContinuation: CheckedContinuation<String, Error>?
    private var refreshTimeoutItem: DispatchWorkItem?
    private var isInBackground: Bool = false
    private var cookieDebounceTask: Task<Void, Never>?
    private var isFetchingCurrentlyPlaying: Bool = false
    private var rateLimitCooldownUntil: Date? = nil
    private var consecutive429Count: Int = 0
    private var countdownTimer: AnyCancellable?

    private let artworkCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 100
        return cache
    }()

    // UserDefaults 儲存鍵名
    private let kAccessToken = "spotify_access_token"
    private let kTokenExpiration = "spotify_token_expiration"

    override private init() {
        super.init()
        let storedToken = getStoredAccessToken()
        self.hasCapturedToken = (storedToken != nil)
        self.isLoggedIn = (storedToken != nil)
        WKWebsiteDataStore.default().httpCookieStore.add(self)
        setupLifecycleObservers()
        Task { @MainActor [weak self] in
            await self?.restoreSessionOrRefreshOnColdStart()
        }
    }

    private func restoreSessionOrRefreshOnColdStart() async {
        let hasSPDC = await checkHasSPDC()
        if hasSPDC {
            self.isLoggedIn = true
            let expiration = UserDefaults.standard.double(forKey: kTokenExpiration)
            let now = Date().timeIntervalSince1970
            if getStoredAccessToken() == nil || now >= (expiration - 60) {
                _ = try? await getValidAccessToken()
            }
            if AppleMusicMonitor.shared.playbackSource == .spotify {
                startWebAPIPolling()
            }
        } else if getStoredAccessToken() == nil {
            self.isLoggedIn = false
            self.hasCapturedToken = false
        }
    }

    // MARK: - 生命週期監聽
    private func setupLifecycleObservers() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.isInBackground = false
                if AppleMusicMonitor.shared.playbackSource == .spotify && self.isLoggedIn {
                    self.startWebAPIPolling()
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.isInBackground = true
                if AppleMusicMonitor.shared.playbackSource == .spotify {
                    if !self.isBackgroundSyncActive {
                        self.stopWebAPIPolling()
                    }
                }
            }
        }
    }

    private var isBackgroundSyncActive: Bool {
        PiPLyricsEngine.shared.isPiPActive ||
        PiPLyricsEngine.shared.isPiPEnabled ||
        LiveActivityLyricsEngine.shared.isActivityActive ||
        LiveActivityLyricsEngine.shared.isEnabled ||
        BackgroundKeepAliveManager.shared.isRunning
    }

    // MARK: - 服務啟動與停止中樞
    public func start(source: PlaybackSource = .spotify) {
        guard source == .spotify else {
            stop()
            return
        }
        if isLoggedIn {
            startWebAPIPolling()
        } else {
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if await self.checkHasSPDC() {
                    self.isLoggedIn = true
                    self.startWebAPIPolling()
                }
            }
        }
    }

    public func stop() {
        stopWebAPIPolling()
    }

    // MARK: - Token 持久化與管理
    private func saveToken(token: String, expirationMs: Double) {
        UserDefaults.standard.set(token, forKey: kAccessToken)
        let expirationDate: Double
        if expirationMs > 0 {
            expirationDate = expirationMs / 1000.0
        } else {
            expirationDate = Date().timeIntervalSince1970 + 3600.0
        }
        UserDefaults.standard.set(expirationDate, forKey: kTokenExpiration)
        self.hasCapturedToken = true
        self.isLoggedIn = true
    }

    private func clearTokens() {
        UserDefaults.standard.removeObject(forKey: kAccessToken)
        UserDefaults.standard.removeObject(forKey: kTokenExpiration)
        self.hasCapturedToken = false
    }

    private func getStoredAccessToken() -> String? {
        UserDefaults.standard.string(forKey: kAccessToken)
    }

    public func checkHasSPDC() async -> Bool {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                let hasSPDC = cookies.contains { cookie in
                    cookie.name == "sp_dc" && cookie.domain.contains("spotify.com")
                }
                continuation.resume(returning: hasSPDC)
            }
        }
    }

    public func getValidAccessToken() async throws -> String {
        let expiration = UserDefaults.standard.double(forKey: kTokenExpiration)
        let now = Date().timeIntervalSince1970

        if let token = getStoredAccessToken(), now < (expiration - 60) {
            return token
        }

        if let existingTask = refreshTask {
            return try await existingTask.value
        }

        let task = Task<String, Error> { @MainActor in
            defer { self.refreshTask = nil }
            return try await self.refreshAccessTokenSilently()
        }
        self.refreshTask = task
        return try await task.value
    }

    // MARK: - 憑證捕獲與背景靜默續期
    public func handleCapturedToken(token: String, expirationMs: Double) {
        let isNewToken = (getStoredAccessToken() != token)
        saveToken(token: token, expirationMs: expirationMs)
        self.hasCapturedToken = true
        self.isLoggedIn = true

        self.refreshTimeoutItem?.cancel()
        self.refreshTimeoutItem = nil

        if let cont = self.tokenContinuation {
            self.tokenContinuation = nil
            cleanupBackgroundWebView()
            cont.resume(returning: token)
        }

        if AppleMusicMonitor.shared.playbackSource == .spotify {
            if isNewToken || webAPIPollingTask == nil {
                startWebAPIPolling()
                triggerImmediateWebAPIPoll()
            }
        }
    }

    @MainActor
    private func refreshAccessTokenSilently() async throws -> String {
        let hasSPDC = await checkHasSPDC()
        guard hasSPDC else {
            logout()
            throw SpotifyServiceError.notAuthenticated
        }

        isRefreshingToken = true
        defer { isRefreshingToken = false }

        return try await withCheckedThrowingContinuation { continuation in
            self.tokenContinuation = continuation

            let timeoutItem = DispatchWorkItem { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self = self, let cont = self.tokenContinuation else { return }
                    self.tokenContinuation = nil
                    self.cleanupBackgroundWebView()
                    cont.resume(throwing: SpotifyServiceError.tokenRefreshTimeout)
                }
            }
            self.refreshTimeoutItem = timeoutItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 15.0, execute: timeoutItem)

            let config = Self.createWebViewConfiguration(scriptHandler: self)
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: config)
            webView.alpha = 0.01
            webView.customUserAgent = Self.desktopUserAgent
            webView.navigationDelegate = self
            self.backgroundWebView = webView

            let candidateWindow = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first(where: { $0.isKeyWindow })
                ?? UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .flatMap({ $0.windows })
                    .first
            if let window = candidateWindow {
                window.insertSubview(webView, at: 0)
            }

            if let url = URL(string: "https://open.spotify.com/") {
                webView.load(URLRequest(url: url))
            } else {
                self.refreshTimeoutItem?.cancel()
                self.refreshTimeoutItem = nil
                self.tokenContinuation = nil
                self.cleanupBackgroundWebView()
                continuation.resume(throwing: SpotifyServiceError.tokenRefreshFailed)
            }
        }
    }

    private func cleanupBackgroundWebView() {
        refreshTimeoutItem?.cancel()
        refreshTimeoutItem = nil
        backgroundWebView?.stopLoading()
        backgroundWebView?.navigationDelegate = nil
        backgroundWebView?.configuration.userContentController.removeScriptMessageHandler(forName: "spotifyTokenHandler")
        backgroundWebView?.removeFromSuperview()
        backgroundWebView = nil
    }

    // MARK: - 徹底清除 Cookie 之登出
    public func logout() {
        stopWebAPIPolling()
        clearTokens()
        isLoggedIn = false
        hasCapturedToken = false
        playerStatusText = String(localized: "未登入")
        artworkCache.removeAllObjects()
        AppleMusicMonitor.shared.applySpotifySnapshot(nil, from: .spotify)
        isFetchingCurrentlyPlaying = false
        rateLimitCooldownUntil = nil
        consecutive429Count = 0
        countdownTimer?.cancel()
        countdownTimer = nil

        cookieDebounceTask?.cancel()
        cookieDebounceTask = nil

        refreshTimeoutItem?.cancel()
        refreshTimeoutItem = nil
        refreshTask?.cancel()
        refreshTask = nil
        if let cont = tokenContinuation {
            tokenContinuation = nil
            cont.resume(throwing: SpotifyServiceError.notAuthenticated)
        }
        cleanupBackgroundWebView()

        let cookieStore = WKWebsiteDataStore.default().httpCookieStore
        cookieStore.getAllCookies { cookies in
            for cookie in cookies {
                if cookie.domain.localizedCaseInsensitiveContains("spotify") {
                    cookieStore.delete(cookie)
                }
            }
        }
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().fetchDataRecords(ofTypes: dataTypes) { records in
            let spotifyRecords = records.filter { record in
                record.displayName.localizedCaseInsensitiveContains("spotify")
            }
            WKWebsiteDataStore.default().removeData(ofTypes: dataTypes, for: spotifyRecords) {}
        }
    }

    public func logoutWebAPI() {
        logout()
    }

    // MARK: - Web API 智慧自適應輪詢引擎
    private func startWebAPIPolling() {
        webAPIPollingTask?.cancel()
        webAPIPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self, self.isLoggedIn else { break }
                if self.isInBackground && !self.isBackgroundSyncActive {
                    break
                }
                let nextDelay = await self.fetchCurrentlyPlayingWebAPI()
                guard !Task.isCancelled, self.isLoggedIn else { break }
                try? await Task.sleep(nanoseconds: UInt64(nextDelay * 1_000_000_000))
                guard !Task.isCancelled, self.isLoggedIn else { break }
            }
        }
    }

    private func stopWebAPIPolling() {
        webAPIPollingTask?.cancel()
        webAPIPollingTask = nil
    }

    public func triggerImmediatePoll() {
        triggerImmediateWebAPIPoll()
    }

    public func triggerImmediateWebAPIPoll() {
        guard isLoggedIn else { return }
        if let cooldownDate = rateLimitCooldownUntil, cooldownDate.timeIntervalSinceNow > 0 {
            return
        }
        guard !isFetchingCurrentlyPlaying else { return }
        Task { [weak self] in
            _ = await self?.fetchCurrentlyPlayingWebAPI()
        }
    }

    private func startCountdownTimer(until targetDate: Date, isQuotaExceeded: Bool) {
        countdownTimer?.cancel()
        let initialSec = Int(ceil(max(0, targetDate.timeIntervalSinceNow)))
        if isQuotaExceeded {
            self.playerStatusText = String(localized: "Spotify 配額受限 (QUOTA)，冷卻中（剩餘 \(initialSec) 秒）")
        } else {
            self.playerStatusText = String(localized: "請求過於頻繁 (429)，冷卻中（剩餘 \(initialSec) 秒）")
        }

        countdownTimer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                let remaining = targetDate.timeIntervalSinceNow
                if remaining > 0 {
                    let sec = Int(ceil(remaining))
                    if isQuotaExceeded {
                        self.playerStatusText = String(localized: "Spotify 配額受限 (QUOTA)，冷卻中（剩餘 \(sec) 秒）")
                    } else {
                        self.playerStatusText = String(localized: "請求過於頻繁 (429)，冷卻中（剩餘 \(sec) 秒）")
                    }
                } else {
                    self.countdownTimer?.cancel()
                    self.countdownTimer = nil
                    self.rateLimitCooldownUntil = nil
                    self.playerStatusText = String(localized: "冷卻完成，正在重新連線...")
                    self.triggerImmediateWebAPIPoll()
                }
            }
    }

    private func fetchCurrentlyPlayingWebAPI() async -> TimeInterval {
        let defaultDelay: TimeInterval = self.isInBackground ? 10.0 : 5.0

        // 併發防禦：防止多個非同步 Task 重複發送請求
        guard !isFetchingCurrentlyPlaying else {
            return defaultDelay
        }
        isFetchingCurrentlyPlaying = true
        defer { isFetchingCurrentlyPlaying = false }

        // 429 冷卻防禦：若在冷卻期內，絕不向伺服器發送任何請求，避免 Spotify 延長懲罰
        if let cooldownDate = rateLimitCooldownUntil {
            let remainingCooldown = cooldownDate.timeIntervalSinceNow
            if remainingCooldown > 0 {
                return max(2.0, remainingCooldown)
            } else {
                rateLimitCooldownUntil = nil
                countdownTimer?.cancel()
                countdownTimer = nil
            }
        }

        guard let token = try? await getValidAccessToken() else {
            if self.isLoggedIn {
                self.playerStatusText = String(localized: "等待播放授權...")
            } else {
                self.playerStatusText = String(localized: "未登入")
            }
            return defaultDelay
        }

        guard let url = URL(string: "https://api.spotify.com/v1/me/player/currently-playing") else {
            return defaultDelay
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://open.spotify.com", forHTTPHeaderField: "Origin")
        request.setValue("https://open.spotify.com/", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("zh-TW,zh;q=0.9,en-US;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("same-site", forHTTPHeaderField: "Sec-Fetch-Site")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                self.playerStatusText = String(localized: "連線異常")
                return defaultDelay
            }

            if httpResponse.statusCode == 204 {
                consecutive429Count = 0
                rateLimitCooldownUntil = nil
                countdownTimer?.cancel()
                countdownTimer = nil
                self.playerStatusText = String(localized: "目前未在任何裝置播放音樂")
                AppleMusicMonitor.shared.applySpotifySnapshot(nil, from: .spotify)
                return self.isInBackground ? 12.0 : 6.0
            }

            if httpResponse.statusCode == 401 {
                self.playerStatusText = String(localized: "授權過期，正在重新整理...")
                clearTokens()
                _ = try? await getValidAccessToken()
                return 5.0
            }

            if httpResponse.statusCode == 429 {
                consecutive429Count += 1
                let retryAfterSec = httpResponse.value(forHTTPHeaderField: "Retry-After")
                    .flatMap { Double($0) }
                let responseBody = String(data: data, encoding: .utf8) ?? ""
                let isQuotaExceeded = responseBody.contains("QUOTA_EXCEEDED")

                // 若 Spotify 有回傳 Retry-After 則以其為準，若無則依連續次數指數退避（30s, 60s, 120s）
                let backoffBase = Double(min(30 * consecutive429Count, 120))
                let cooldownDuration = max(backoffBase, retryAfterSec ?? 30.0)
                let cooldownTarget = Date().addingTimeInterval(cooldownDuration)
                rateLimitCooldownUntil = cooldownTarget

                startCountdownTimer(until: cooldownTarget, isQuotaExceeded: isQuotaExceeded)
                return cooldownDuration
            }

            guard httpResponse.statusCode == 200 else {
                self.playerStatusText = String(localized: "連線狀態碼：\(httpResponse.statusCode)")
                return defaultDelay
            }

            // 成功請求，重置 429 連續計數與冷卻
            consecutive429Count = 0
            rateLimitCooldownUntil = nil
            countdownTimer?.cancel()
            countdownTimer = nil

            let playResp = try JSONDecoder().decode(SpotifyCurrentlyPlayingResponse.self, from: data)
            if playResp.currently_playing_type == "ad" {
                self.playerStatusText = String(localized: "正在播放廣告")
                AppleMusicMonitor.shared.applySpotifySnapshot(nil, from: .spotify)
                return defaultDelay
            }

            guard let item = playResp.item, let title = item.name, !title.isEmpty else {
                self.playerStatusText = String(localized: "目前未在任何裝置播放音樂")
                AppleMusicMonitor.shared.applySpotifySnapshot(nil, from: .spotify)
                return self.isInBackground ? 12.0 : 6.0
            }

            let artist = item.artists?.map { $0.name }.joined(separator: ", ") ?? ""
            let album = item.album?.name ?? ""
            let durationMs = item.duration_ms ?? 0
            let durationSec = Double(durationMs) / 1000.0
            let progressMs = playResp.progress_ms ?? 0
            let isPlaying = playResp.is_playing
            let imageUrl = item.album?.images?.first?.url

            self.playerStatusText = isPlaying ? "正在播放：\(title) - \(artist)" : "已暫停：\(title) - \(artist)"

            var artworkData: Data? = nil
            if let imgUrlString = imageUrl {
                let cacheKey = imgUrlString as NSString
                if let cached = artworkCache.object(forKey: cacheKey) {
                    artworkData = cached as Data
                } else if let imgUrl = URL(string: imgUrlString) {
                    Task { [weak self] in
                        guard let self = self else { return }
                        if let (imgBytes, _) = try? await URLSession.shared.data(from: imgUrl) {
                            await MainActor.run {
                                self.artworkCache.setObject(imgBytes as NSData, forKey: cacheKey)
                                AppleMusicMonitor.shared.updateArtworkIfCurrent(trackTitle: title, artist: artist, artworkData: imgBytes)
                            }
                        }
                    }
                }
            }

            let trackInfo = TrackInfo(
                title: title,
                artist: artist,
                album: album,
                duration: durationSec,
                artworkData: artworkData,
                genre: ""
            )

            let snapshot = SpotifyTrackSnapshot(
                track: trackInfo,
                isPlaying: isPlaying,
                progressMs: progressMs,
                timestamp: CACurrentMediaTime()
            )
            AppleMusicMonitor.shared.applySpotifySnapshot(snapshot, from: .spotify)

            if isPlaying {
                let remainingMs = durationMs - progressMs
                if self.isInBackground {
                    if remainingMs > 0 && remainingMs <= 4000 {
                        return 4.0
                    }
                    return 8.0
                } else {
                    if remainingMs > 0 && remainingMs <= 4000 {
                        return 3.0
                    }
                    return 5.0
                }
            } else {
                return self.isInBackground ? 10.0 : 6.0
            }
        } catch {
            return defaultDelay
        }
    }

    public func seek(toMs: Int) {
        seekWebAPI(toMs: toMs)
    }

    public func seekWebAPI(toMs: Int) {
        Task { [weak self] in
            guard let self = self else { return }
            guard let token = try? await self.getValidAccessToken() else { return }
            var components = URLComponents(string: "https://api.spotify.com/v1/me/player/seek")
            components?.queryItems = [URLQueryItem(name: "position_ms", value: "\(toMs)")]
            guard let url = components?.url else { return }

            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            _ = try? await URLSession.shared.data(for: request)
        }
    }

    // MARK: - WebKit 腳本注入與配置建置
    public static let tokenInterceptorScript = """
    (function() {
        if (window !== window.top) return;
        if (window.__auraLyricsInjected) return;
        window.__auraLyricsInjected = true;

        var hasCapturedAnyToken = false;

        function notifyToken(token, expirationMs, isAnon) {
            if (!token || typeof token !== 'string') return;
            if (isAnon === true) return;
            hasCapturedAnyToken = true;
            try {
                window.webkit.messageHandlers.spotifyTokenHandler.postMessage({
                    accessToken: token,
                    expirationMs: expirationMs || 0,
                    isAnonymous: false
                });
            } catch(e) {}
        }

        function extractBearer(val) {
            if (!val || typeof val !== 'string') return null;
            if (val.startsWith('Bearer ') || val.startsWith('bearer ')) {
                return val.substring(7).trim();
            }
            return null;
        }

        function checkHeaders(headers) {
            if (!headers) return;
            try {
                if (typeof headers.get === 'function') {
                    const auth = headers.get('authorization') || headers.get('Authorization');
                    const b = extractBearer(auth);
                    if (b) notifyToken(b, 0, false);
                } else if (typeof headers === 'object') {
                    for (const k in headers) {
                        if (k.toLowerCase() === 'authorization') {
                            const b = extractBearer(headers[k]);
                            if (b) notifyToken(b, 0, false);
                        }
                    }
                }
            } catch(e) {}
        }

        function checkResponse(url, text) {
            if (!text || typeof text !== 'string') return;
            try {
                const data = JSON.parse(text);
                const token = data.accessToken || data.access_token || (data.token && data.token.accessToken) || (data.session && data.session.accessToken);
                const exp = data.accessTokenExpirationTimestampMs || (data.expires_in ? Date.now() + data.expires_in * 1000 : 0);
                const isAnon = (data.isAnonymous === true) || (data.is_anonymous === true);
                if (token && !isAnon) {
                    notifyToken(token, exp, isAnon);
                }
            } catch(e) {}
        }

        function probeAccessToken() {
            if (hasCapturedAnyToken) return;
            try {
                fetch('https://open.spotify.com/get_access_token?reason=transport&productType=web_player', {
                    credentials: 'include'
                })
                .then(r => r.json())
                .then(data => {
                    if (data && data.accessToken && !data.isAnonymous) {
                        notifyToken(data.accessToken, data.accessTokenExpirationTimestampMs, false);
                    }
                })
                .catch(() => {});
            } catch(e) {}
        }

        const origFetch = window.fetch;
        if (origFetch) {
            window.fetch = async function(...args) {
                try {
                    if (args[1] && args[1].headers) {
                        checkHeaders(args[1].headers);
                    }
                } catch(e) {}
                const response = await origFetch.apply(this, args);
                try {
                    const rawUrl = response.url || (typeof args[0] === 'string' ? args[0] : (args[0] && args[0].url ? args[0].url : ''));
                    const lower = (rawUrl || '').toLowerCase();
                    if (lower.includes('token') || lower.includes('session') || lower.includes('config')) {
                        const clone = response.clone();
                        clone.text().then(text => checkResponse(rawUrl, text)).catch(() => {});
                    }
                } catch(e) {}
                return response;
            };
        }

        const origOpen = XMLHttpRequest.prototype.open;
        const origSend = XMLHttpRequest.prototype.send;
        const origSetHeader = XMLHttpRequest.prototype.setRequestHeader;

        XMLHttpRequest.prototype.setRequestHeader = function(header, value) {
            try {
                if (header && header.toLowerCase() === 'authorization') {
                    const b = extractBearer(value);
                    if (b) notifyToken(b, 0, false);
                }
            } catch(e) {}
            return origSetHeader.apply(this, arguments);
        };

        XMLHttpRequest.prototype.open = function(method, url) {
            this._auraUrl = (typeof url === 'string') ? url : (url && url.href ? url.href : String(url || ''));
            return origOpen.apply(this, arguments);
        };

        XMLHttpRequest.prototype.send = function() {
            this.addEventListener('load', function() {
                try {
                    const resolvedUrl = (this.responseURL || this._auraUrl || '').toLowerCase();
                    if (resolvedUrl.includes('token') || resolvedUrl.includes('session') || resolvedUrl.includes('config')) {
                        checkResponse(resolvedUrl, this.responseText);
                    }
                } catch(e) {}
            });
            return origSend.apply(this, arguments);
        };

        function scanDOM() {
            if (hasCapturedAnyToken) return;
            try {
                const ids = ['session', 'config', 'initial-state', 'appServerConfig'];
                for (const id of ids) {
                    const el = document.getElementById(id);
                    if (el && el.textContent) {
                        try {
                            const data = JSON.parse(el.textContent);
                            const token = data.accessToken || data.access_token || (data.token && data.token.accessToken) || (data.session && data.session.accessToken);
                            const exp = data.accessTokenExpirationTimestampMs || (data.expires_in ? Date.now() + data.expires_in * 1000 : 0);
                            const isAnon = (data.isAnonymous === true) || (data.is_anonymous === true);
                            if (token && !isAnon) {
                                notifyToken(token, exp, isAnon);
                                return;
                            }
                        } catch(e) {}
                    }
                }
            } catch(e) {}
        }

        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', function() {
                scanDOM();
                probeAccessToken();
            });
        } else {
            scanDOM();
            probeAccessToken();
        }
        setTimeout(function() { scanDOM(); probeAccessToken(); }, 800);
        setTimeout(function() { scanDOM(); probeAccessToken(); }, 2000);
        setTimeout(function() { scanDOM(); probeAccessToken(); }, 4000);
    })();
    """

    public static func createWebViewConfiguration(scriptHandler: WKScriptMessageHandler) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        let userScript = WKUserScript(
            source: tokenInterceptorScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )

        let contentController = WKUserContentController()
        contentController.addUserScript(userScript)
        contentController.add(WeakScriptMessageHandler(delegate: scriptHandler), name: "spotifyTokenHandler")
        config.userContentController = contentController
        return config
    }
}

// MARK: - WKScriptMessageHandler 實作
extension SpotifyService: WKScriptMessageHandler {
    nonisolated public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "spotifyTokenHandler",
              let body = message.body as? [String: Any],
              let token = body["accessToken"] as? String,
              !token.isEmpty else {
            return
        }

        let isAnon = (body["isAnonymous"] as? Bool) ?? false
        if isAnon { return }

        let expMs: Double
        if let exp = body["expirationMs"] as? Double {
            expMs = exp
        } else if let expInt = body["expirationMs"] as? Int {
            expMs = Double(expInt)
        } else {
            expMs = 0
        }

        Task { @MainActor in
            self.handleCapturedToken(token: token, expirationMs: expMs)
        }
    }
}

// MARK: - WKHTTPCookieStoreObserver 實作 (即時監聽 sp_dc 憑證與狀態變更)
extension SpotifyService: WKHTTPCookieStoreObserver {
    nonisolated public func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.cookieDebounceTask?.cancel()
            self.cookieDebounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled, let self = self else { return }
                await self.handleCookiesDidChange()
            }
        }
    }

    private func handleCookiesDidChange() async {
        let hasSPDC = await checkHasSPDC()
        if hasSPDC {
            if !isLoggedIn {
                isLoggedIn = true
                if AppleMusicMonitor.shared.playbackSource == .spotify {
                    startWebAPIPolling()
                }
            }
        } else {
            let expiration = UserDefaults.standard.double(forKey: kTokenExpiration)
            let now = Date().timeIntervalSince1970
            if getStoredAccessToken() == nil || now >= expiration {
                if isLoggedIn {
                    logout()
                }
            }
        }
    }
}

// MARK: - WKNavigationDelegate 實作 (背景隱藏 WebView 導航控制)
extension SpotifyService: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if webView == backgroundWebView, let url = navigationAction.request.url {
            if url.path.contains("/login") || url.host == "accounts.spotify.com" {
                decisionHandler(.cancel)
                logout()
                return
            }
        }
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView == backgroundWebView {
            let probeScript = """
            (function() {
                try {
                    fetch('https://open.spotify.com/get_access_token?reason=transport&productType=web_player', { credentials: 'include' })
                        .then(r => r.json())
                        .then(data => {
                            if (data && data.accessToken && !data.isAnonymous) {
                                window.webkit.messageHandlers.spotifyTokenHandler.postMessage({
                                    accessToken: data.accessToken,
                                    expirationMs: data.accessTokenExpirationTimestampMs || 0,
                                    isAnonymous: false
                                });
                            }
                        }).catch(() => {});
                } catch(e) {}
            })();
            """
            webView.evaluateJavaScript(probeScript, completionHandler: nil)
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView == backgroundWebView {
            handleBackgroundWebViewFailure(error: error)
        }
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if webView == backgroundWebView {
            handleBackgroundWebViewFailure(error: error)
        }
    }

    private func handleBackgroundWebViewFailure(error: Error) {
        if (error as? URLError)?.code == .cancelled || (error as NSError).code == NSURLErrorCancelled {
            return
        }
        self.refreshTimeoutItem?.cancel()
        self.refreshTimeoutItem = nil
        cleanupBackgroundWebView()
        if let cont = self.tokenContinuation {
            self.tokenContinuation = nil
            cont.resume(throwing: error)
        }
    }
}

// MARK: - 弱引用腳本訊息轉發器 (防止循環引用)
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var delegate: WKScriptMessageHandler?

    init(delegate: WKScriptMessageHandler) {
        self.delegate = delegate
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

// MARK: - Spotify 內置登入彈窗視圖 (SwiftUI Sheet)
public struct SpotifyWebLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var spotifyService = SpotifyService.shared
    @State private var isLoading: Bool = true
    @State private var estimatedProgress: Double = 0.0
    @State private var reloadTrigger: Bool = false

    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                SpotifyWebViewRepresentable(
                    isLoading: $isLoading,
                    progress: $estimatedProgress,
                    reloadTrigger: $reloadTrigger
                )
                .edgesIgnoringSafeArea(.bottom)

                if isLoading {
                    ProgressView(value: estimatedProgress)
                        .progressViewStyle(LinearProgressViewStyle(tint: .pink))
                        .frame(height: 2)
                }

                if spotifyService.isLoggedIn && !spotifyService.hasCapturedToken {
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("帳號驗證成功，正在同步播放授權...")
                            .font(.headline)
                        Text("請稍候，授權完成後將自動關閉並開始同步。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .shadow(radius: 8)
                    .padding(.top, 80)
                }
            }
            .navigationTitle("登入 Spotify")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        reloadTrigger.toggle()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .onChange(of: spotifyService.hasCapturedToken) { _, captured in
                if captured {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    dismiss()
                }
            }
        }
    }
}

// MARK: - Spotify 內置 WebView 封裝元件 (UIViewRepresentable)
public struct SpotifyWebViewRepresentable: UIViewRepresentable {
    @Binding var isLoading: Bool
    @Binding var progress: Double
    @Binding var reloadTrigger: Bool

    public class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: SpotifyWebViewRepresentable
        var progressObservation: NSKeyValueObservation?
        var loadingObservation: NSKeyValueObservation?
        var lastReloadTrigger: Bool = false
        weak var webView: WKWebView?

        init(parent: SpotifyWebViewRepresentable) {
            self.parent = parent
            self.lastReloadTrigger = parent.reloadTrigger
        }

        // 支援 window.open 或 target="_blank" 彈窗交由 decidePolicyFor 在當前 WebView 內導航（避免重覆載入）
        public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            return nil
        }

        public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = true
            }
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
        }

        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
        }

        public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public func makeUIView(context: Context) -> WKWebView {
        let config = SpotifyService.createWebViewConfiguration(scriptHandler: SpotifyService.shared)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = SpotifyService.desktopUserAgent
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.webView = webView

        context.coordinator.progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak coordinator = context.coordinator] wv, _ in
            DispatchQueue.main.async {
                coordinator?.parent.progress = wv.estimatedProgress
            }
        }

        context.coordinator.loadingObservation = webView.observe(\.isLoading, options: [.new]) { [weak coordinator = context.coordinator] wv, _ in
            DispatchQueue.main.async {
                coordinator?.parent.isLoading = wv.isLoading
            }
        }

        if let url = URL(string: "https://accounts.spotify.com/login?continue=https%3A%2F%2Fopen.spotify.com%2F") {
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.lastReloadTrigger != reloadTrigger {
            context.coordinator.lastReloadTrigger = reloadTrigger
            uiView.reload()
        }
    }

    public static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        uiView.navigationDelegate = nil
        uiView.uiDelegate = nil
        coordinator.progressObservation?.invalidate()
        coordinator.progressObservation = nil
        coordinator.loadingObservation?.invalidate()
        coordinator.loadingObservation = nil
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "spotifyTokenHandler")
        coordinator.webView = nil
    }
}

// MARK: - 輔助 Codable 結構體與錯誤列舉
private struct SpotifyCurrentlyPlayingResponse: Codable {
    let is_playing: Bool
    let progress_ms: Int?
    let currently_playing_type: String?
    let item: SpotifyTrackItem?
}

private struct SpotifyTrackItem: Codable {
    let name: String?
    let duration_ms: Int?
    let artists: [SpotifyArtistItem]?
    let album: SpotifyAlbumItem?
    let uri: String?
}

private struct SpotifyArtistItem: Codable {
    let name: String
}

private struct SpotifyAlbumItem: Codable {
    let name: String
    let images: [SpotifyImageItem]?
}

private struct SpotifyImageItem: Codable {
    let url: String
    let width: Int?
    let height: Int?
}

public enum SpotifyServiceError: LocalizedError {
    case notAuthenticated
    case tokenRefreshFailed
    case tokenRefreshTimeout

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return String(localized: "尚未登入 Spotify 帳號")
        case .tokenRefreshFailed:
            return String(localized: "更新 Spotify Token 失敗，請重新登入")
        case .tokenRefreshTimeout:
            return String(localized: "Spotify 憑證續期逾時，請重新登入")
        }
    }
}
