import Foundation
import UIKit
import AuthenticationServices
import CryptoKit
import Combine
import SpotifyiOS

// MARK: - 播放來源列舉
public enum PlaybackSource: String, CaseIterable, Identifiable, Codable, Sendable {
    case appleMusic = "appleMusic"
    case spotifyWebAPI = "spotifyWebAPI"
    case spotifyAppRemote = "spotifyAppRemote"

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .appleMusic:
            return String(localized: "Apple Music (系統播放器)")
        case .spotifyWebAPI:
            return String(localized: "Spotify (Web API 雲端同步)")
        case .spotifyAppRemote:
            return String(localized: "Spotify (App Remote 本機連線)")
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

// MARK: - Spotify 服務管理中樞 (Web API PKCE + App Remote 雙模式)
@MainActor
public final class SpotifyService: NSObject, ObservableObject {
    public static let shared = SpotifyService()
    public static let redirectURI = "auralyrics://spotify-callback"

    // MARK: - 狀態屬性
    @Published public var clientId: String {
        didSet {
            UserDefaults.standard.set(clientId, forKey: "spotify_client_id")
        }
    }

    @Published public private(set) var isWebAPILoggedIn: Bool = false
    @Published public private(set) var isAppRemoteConnected: Bool = false
    @Published public private(set) var appRemoteStatusText: String = String(localized: "未連線")

    // MARK: - 私有認證與通訊狀態
    private var codeVerifier: String?
    private var authSession: ASWebAuthenticationSession?
    private var webAPIPollingTask: Task<Void, Never>?
    private let artworkCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 100
        return cache
    }()

    // App Remote 核心物件
    private var appRemote: SPTAppRemote?
    private var configuration: SPTConfiguration?

    // UserDefaults 儲存鍵名
    private let kAccessToken = "spotify_access_token"
    private let kRefreshToken = "spotify_refresh_token"
    private let kTokenExpiration = "spotify_token_expiration"
    private let kAppRemoteAccessToken = "spotify_app_remote_token"

    override private init() {
        self.clientId = UserDefaults.standard.string(forKey: "spotify_client_id") ?? ""
        super.init()
        self.isWebAPILoggedIn = (getStoredRefreshToken() != nil)
        setupLifecycleObservers()
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
                if AppleMusicMonitor.shared.playbackSource == .spotifyAppRemote {
                    if let remote = self.appRemote {
                        if !remote.isConnected && remote.connectionParameters.accessToken != nil {
                            remote.connect()
                        }
                    } else {
                        self.connectAppRemote(forceReauth: false)
                    }
                } else if AppleMusicMonitor.shared.playbackSource == .spotifyWebAPI {
                    if self.isWebAPILoggedIn {
                        self.startWebAPIPolling()
                    }
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
                // App Remote 進入背景時中斷連線避免無謂耗電
                if AppleMusicMonitor.shared.playbackSource == .spotifyAppRemote {
                    if let remote = self.appRemote, remote.isConnected {
                        remote.disconnect()
                    }
                } else if AppleMusicMonitor.shared.playbackSource == .spotifyWebAPI {
                    self.stopWebAPIPolling()
                }
            }
        }
    }

    // MARK: - 服務啟動與停止中樞
    public func start(source: PlaybackSource) {
        switch source {
        case .appleMusic:
            stop()
        case .spotifyWebAPI:
            disconnectAppRemote()
            if isWebAPILoggedIn {
                startWebAPIPolling()
            }
        case .spotifyAppRemote:
            stopWebAPIPolling()
            connectAppRemote(forceReauth: false)
        }
    }

    public func stop() {
        stopWebAPIPolling()
        disconnectAppRemote()
    }

    // MARK: - URL 外部跳轉接收處理
    public func handleOpenURL(_ url: URL) {
        guard url.scheme == "auralyrics" else { return }

        // 1. Web API OAuth PKCE 回呼容錯處理
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           components.queryItems?.contains(where: { $0.name == "code" }) == true {
            Task { @MainActor [weak self] in
                await self?.exchangeCodeForToken(url: url)
            }
            return
        }

        // 2. App Remote 授權回傳 (含 Access Token 或錯誤)
        if appRemote == nil {
            let cleanId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanId.isEmpty {
                let config = SPTConfiguration(clientID: cleanId, redirectURL: URL(string: Self.redirectURI)!)
                config.playURI = ""
                self.configuration = config
                let remote = SPTAppRemote(configuration: config, logLevel: .none)
                remote.delegate = self
                self.appRemote = remote
            }
        }

        if let remote = appRemote, let params = remote.authorizationParameters(from: url) {
            if let accessToken = params[SPTAppRemoteAccessTokenKey] {
                UserDefaults.standard.set(accessToken, forKey: kAppRemoteAccessToken)
                remote.connectionParameters.accessToken = accessToken
                remote.connect()
                appRemoteStatusText = String(localized: "正在連線...")
            } else if let errorDescription = params[SPTAppRemoteErrorDescriptionKey] {
                appRemoteStatusText = errorDescription
            }
        }
    }

    // MARK: - =========================================================
    // MARK: - 模式 1: Spotify Web API (OAuth 2.0 PKCE + 自適應輪詢)
    // MARK: - =========================================================

    public func startWebAPILogin() {
        let cleanId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty else { return }

        let verifier = generateCodeVerifier()
        self.codeVerifier = verifier
        let challenge = generateCodeChallenge(from: verifier)

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: cleanId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "scope", value: "user-read-playback-state user-read-currently-playing user-modify-playback-state app-remote-control")
        ]

        guard let authURL = components.url else { return }

        let session = ASWebAuthenticationSession(
            url: authURL,
            callbackURLScheme: "auralyrics"
        ) { [weak self] callbackURL, error in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let callbackURL = callbackURL {
                    await self.exchangeCodeForToken(url: callbackURL)
                }
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.authSession = session
        session.start()
    }

    public func logoutWebAPI() {
        stopWebAPIPolling()
        clearTokens()
        isWebAPILoggedIn = false
        artworkCache.removeAllObjects()
        AppleMusicMonitor.shared.applySpotifySnapshot(nil, from: .spotifyWebAPI)
    }

    // MARK: PKCE 憑證生成
    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let unreserved = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        let unreservedChars = Array(unreserved)
        return String(bytes.map { unreservedChars[Int($0) % unreservedChars.count] })
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: Token 交換與持久化
    private func exchangeCodeForToken(url: URL) async {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              let verifier = self.codeVerifier else {
            return
        }
        self.codeVerifier = nil

        let cleanId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "client_id", value: cleanId),
            URLQueryItem(name: "code_verifier", value: verifier)
        ]
        request.httpBody = bodyComponents.percentEncodedQuery?.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return
            }
            let tokenResp = try JSONDecoder().decode(SpotifyTokenResponse.self, data: data)
            saveTokens(tokenResp)
            self.isWebAPILoggedIn = true
            if AppleMusicMonitor.shared.playbackSource == .spotifyWebAPI {
                startWebAPIPolling()
            }
        } catch {
            print("[Spotify Web API] Token exchange error: \(error)")
        }
    }

    private func saveTokens(_ response: SpotifyTokenResponse) {
        UserDefaults.standard.set(response.access_token, forKey: kAccessToken)
        if let refresh = response.refresh_token {
            UserDefaults.standard.set(refresh, forKey: kRefreshToken)
        }
        let expirationDate = Date().timeIntervalSince1970 + Double(response.expires_in)
        UserDefaults.standard.set(expirationDate, forKey: kTokenExpiration)
    }

    private func clearTokens() {
        UserDefaults.standard.removeObject(forKey: kAccessToken)
        UserDefaults.standard.removeObject(forKey: kRefreshToken)
        UserDefaults.standard.removeObject(forKey: kTokenExpiration)
    }

    private func getStoredAccessToken() -> String? {
        UserDefaults.standard.string(forKey: kAccessToken)
    }

    private func getStoredRefreshToken() -> String? {
        UserDefaults.standard.string(forKey: kRefreshToken)
    }

    private func getValidAccessToken() async throws -> String {
        let expiration = UserDefaults.standard.double(forKey: kTokenExpiration)
        let now = Date().timeIntervalSince1970

        if let token = getStoredAccessToken(), now < (expiration - 60) {
            return token
        }

        // Token 即將過期或已過期，呼叫 Refresh Token
        return try await refreshAccessToken()
    }

    private func refreshAccessToken() async throws -> String {
        guard let refreshToken = getStoredRefreshToken() else {
            clearTokens()
            isWebAPILoggedIn = false
            stopWebAPIPolling()
            AppleMusicMonitor.shared.applySpotifySnapshot(nil, from: .spotifyWebAPI)
            throw SpotifyServiceError.notAuthenticated
        }

        let cleanId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty else {
            throw SpotifyServiceError.missingClientId
        }

        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: cleanId)
        ]
        request.httpBody = bodyComponents.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            clearTokens()
            isWebAPILoggedIn = false
            stopWebAPIPolling()
            AppleMusicMonitor.shared.applySpotifySnapshot(nil, from: .spotifyWebAPI)
            throw SpotifyServiceError.tokenRefreshFailed
        }
        let tokenResp = try JSONDecoder().decode(SpotifyTokenResponse.self, data: data)
        saveTokens(tokenResp)
        self.isWebAPILoggedIn = true
        return tokenResp.access_token
    }

    // MARK: Web API 智慧自適應輪詢引擎
    private func startWebAPIPolling() {
        webAPIPollingTask?.cancel()
        webAPIPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self, self.isWebAPILoggedIn else { break }
                let nextDelay = await self.fetchCurrentlyPlayingWebAPI()
                guard !Task.isCancelled, self.isWebAPILoggedIn else { break }
                try? await Task.sleep(nanoseconds: UInt64(nextDelay * 1_000_000_000))
                guard !Task.isCancelled, self.isWebAPILoggedIn else { break }
            }
        }
    }

    private func stopWebAPIPolling() {
        webAPIPollingTask?.cancel()
        webAPIPollingTask = nil
    }

    /// App 返回前景時立即主動輪詢一次
    public func triggerImmediateWebAPIPoll() {
        guard isWebAPILoggedIn else { return }
        Task { [weak self] in
            _ = await self?.fetchCurrentlyPlayingWebAPI()
        }
    }

    /// 請求 Spotify 播放狀態並回傳下次建議輪詢秒數
    private func fetchCurrentlyPlayingWebAPI() async -> TimeInterval {
        guard let token = try? await getValidAccessToken() else {
            return 4.0
        }

        guard let url = URL(string: "https://api.spotify.com/v1/me/player/currently-playing") else {
            return 4.0
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return 4.0
            }

            // HTTP 204: 當前無音樂播放
            if httpResponse.statusCode == 204 {
                AppleMusicMonitor.shared.applySpotifySnapshot(nil, from: .spotifyWebAPI)
                return 4.0
            }

            if httpResponse.statusCode == 401 {
                // Token 無效，嘗試重整 Token 並於下次輪詢生效
                _ = try? await refreshAccessToken()
                return 2.0
            }

            guard httpResponse.statusCode == 200 else {
                return 4.0
            }

            let playResp = try JSONDecoder().decode(SpotifyCurrentlyPlayingResponse.self, data: data)
            if playResp.currently_playing_type == "ad" {
                // 廣告插播中：保持現有畫面並以 4.0 秒稍後重試，避免清空狀態
                return 4.0
            }

            guard let item = playResp.item, let title = item.name, !title.isEmpty else {
                AppleMusicMonitor.shared.applySpotifySnapshot(nil, from: .spotifyWebAPI)
                return 4.0
            }

            let artist = item.artists?.map { $0.name }.joined(separator: ", ") ?? ""
            let album = item.album?.name ?? ""
            let durationMs = item.duration_ms ?? 0
            let durationSec = Double(durationMs) / 1000.0
            let progressMs = playResp.progress_ms ?? 0
            let isPlaying = playResp.is_playing
            let imageUrl = item.album?.images?.first?.url

            var artworkData: Data? = nil
            if let imgUrlString = imageUrl {
                let cacheKey = imgUrlString as NSString
                if let cached = artworkCache.object(forKey: cacheKey) {
                    artworkData = cached as Data
                } else if let imgUrl = URL(string: imgUrlString) {
                    // 非同步抓取封面，抓取完成後補全快照
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
            AppleMusicMonitor.shared.applySpotifySnapshot(snapshot, from: .spotifyWebAPI)

            // 計算智慧自適應輪詢延遲：
            // 播放中且距結尾 < 3 秒為 1.0s；一般播放中 2.0s；暫停時 4.0s
            if isPlaying {
                let remainingMs = durationMs - progressMs
                if remainingMs > 0 && remainingMs <= 3000 {
                    return 1.0
                }
                return 2.0
            } else {
                return 4.0
            }
        } catch {
            return 4.0
        }
    }

    /// 透過 Web API 跳轉進度 (PUT /v1/me/player/seek)
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

            // 免費版用戶若回傳 403 Forbidden 靜默忽略不報錯
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    // MARK: - =========================================================
    // MARK: - 模式 2: Spotify App Remote (本機 SDK 即時 IPC 通訊)
    // MARK: - =========================================================

    public func connectAppRemote(forceReauth: Bool = false) {
        let cleanId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty else {
            appRemoteStatusText = String(localized: "請先填入 Spotify Client ID")
            return
        }

        let config = SPTConfiguration(clientID: cleanId, redirectURL: URL(string: Self.redirectURI)!)
        config.playURI = ""
        self.configuration = config

        let remote = SPTAppRemote(configuration: config, logLevel: .none)
        remote.delegate = self
        self.appRemote = remote

        // 若先前已取得 App Remote Access Token 且未要求強制重驗證，直接連線
        if !forceReauth, let savedToken = UserDefaults.standard.string(forKey: kAppRemoteAccessToken), !savedToken.isEmpty {
            remote.connectionParameters.accessToken = savedToken
            appRemoteStatusText = String(localized: "正在連線...")
            remote.connect()
            return
        }

        appRemoteStatusText = String(localized: "正在連線本機 Spotify...")
        remote.authorizeAndPlayURI("") { [weak self] success in
            Task { @MainActor [weak self] in
                if !success {
                    self?.appRemoteStatusText = String(localized: "無法喚醒 Spotify App，請確認已安裝")
                }
            }
        }
    }

    public func disconnectAppRemote() {
        appRemote?.disconnect()
        isAppRemoteConnected = false
        appRemoteStatusText = String(localized: "未連線")
        AppleMusicMonitor.shared.applySpotifySnapshot(nil, from: .spotifyAppRemote)
    }

    public func seekAppRemote(toMs: Int) {
        appRemote?.playerAPI?.seek(toPosition: toMs, callback: { _, error in
            if let error = error {
                print("[Spotify App Remote] Seek error: \(error.localizedDescription)")
            }
        })
    }

    // MARK: App Remote 內部回呼處理
    fileprivate func handleEstablishConnection(_ remote: SPTAppRemote) {
        isAppRemoteConnected = true
        appRemoteStatusText = String(localized: "已連線")
        if let token = remote.connectionParameters.accessToken, !token.isEmpty {
            UserDefaults.standard.set(token, forKey: kAppRemoteAccessToken)
        }
        remote.playerAPI?.delegate = self
        remote.playerAPI?.subscribe(toPlayerState: { [weak self] _, error in
            Task { @MainActor [weak self] in
                if let error = error {
                    self?.appRemoteStatusText = error.localizedDescription
                }
            }
        })
        remote.playerAPI?.getPlayerState { [weak self] result, error in
            Task { @MainActor [weak self] in
                if let state = result as? SPTAppRemotePlayerState {
                    self?.handleAppRemotePlayerState(state)
                }
            }
        }
    }

    fileprivate func handleConnectionFailed(_ error: Error?) {
        isAppRemoteConnected = false
        let desc = error?.localizedDescription ?? String(localized: "連線失敗")
        appRemoteStatusText = desc
        // 若因 Token 失效而連線失敗，清空儲存的 Token 以便下次連線時重新喚醒授權
        UserDefaults.standard.removeObject(forKey: kAppRemoteAccessToken)
    }

    fileprivate func handleDisconnected(_ error: Error?) {
        isAppRemoteConnected = false
        appRemoteStatusText = error != nil ? error!.localizedDescription : String(localized: "已中斷連線")
    }

    fileprivate func handleAppRemotePlayerState(_ playerState: SPTAppRemotePlayerState) {
        let track = playerState.track
        let title = track.name
        let artist = track.artist.name
        let album = track.album.name
        let durationSec = Double(track.duration) / 1000.0
        let positionMs = playerState.playbackPosition
        let isPlaying = !playerState.isPaused
        let trackUri = track.uri

        let trackKey = trackUri as NSString
        var artworkData: Data? = artworkCache.object(forKey: trackKey) as Data?
        if artworkData == nil {
            appRemote?.imageAPI?.fetchImage(forItem: track, with: CGSize(width: 120, height: 120)) { [weak self] result, _ in
                guard let self = self, let image = result as? UIImage, let data = image.pngData() else { return }
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.artworkCache.setObject(data as NSData, forKey: trackKey)
                    AppleMusicMonitor.shared.updateArtworkIfCurrent(trackTitle: title, artist: artist, artworkData: data)
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
            progressMs: positionMs,
            timestamp: CACurrentMediaTime()
        )
        AppleMusicMonitor.shared.applySpotifySnapshot(snapshot, from: .spotifyAppRemote)
    }
}

// MARK: - SPTAppRemoteDelegate 實作 (併發防護：線程隔離分流)
extension SpotifyService: SPTAppRemoteDelegate {
    nonisolated public func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        Task { @MainActor in
            self.handleEstablishConnection(appRemote)
        }
    }

    nonisolated public func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        Task { @MainActor in
            self.handleConnectionFailed(error)
        }
    }

    nonisolated public func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        Task { @MainActor in
            self.handleDisconnected(error)
        }
    }
}

// MARK: - SPTAppRemotePlayerStateDelegate 實作
extension SpotifyService: SPTAppRemotePlayerStateDelegate {
    nonisolated public func playerStateDidChange(_ playerState: SPTAppRemotePlayerState) {
        Task { @MainActor in
            self.handleAppRemotePlayerState(playerState)
        }
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding 實作
extension SpotifyService: ASWebAuthenticationPresentationContextProviding {
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let activeScene = scenes.first(where: { $0.activationState == .foregroundActive }),
           let window = activeScene.windows.first(where: { $0.isKeyWindow }) ?? activeScene.windows.first {
            return window
        }
        if let window = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) ?? scenes.flatMap({ $0.windows }).first {
            return window
        }
        return ASPresentationAnchor()
    }
}

// MARK: - 輔助 Codable 結構體與錯誤列舉
private struct SpotifyTokenResponse: Codable {
    let access_token: String
    let token_type: String
    let expires_in: Int
    let refresh_token: String?
    let scope: String?
}

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
    case missingClientId
    case tokenRefreshFailed

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return String(localized: "尚未登入 Spotify 帳號")
        case .missingClientId:
            return String(localized: "缺少 Spotify Client ID")
        case .tokenRefreshFailed:
            return String(localized: "更新 Spotify Token 失敗，請重新登入")
        }
    }
}
