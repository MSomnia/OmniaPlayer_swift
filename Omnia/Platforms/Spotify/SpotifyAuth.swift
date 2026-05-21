import Foundation
import CryptoKit
import WebKit
import AppKit

// MARK: - Constants

private let webPlayerURL    = "https://open.spotify.com/"
private let serverTimeURL   = "https://open.spotify.com/api/server-time"
private let tokenURL        = "https://open.spotify.com/api/token"
private let accountsURL     = "https://accounts.spotify.com/en/status"
private let loginURL        = "https://open.spotify.com/"

// Chrome UA to match Python version
let spotifyWebUA =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) " +
    "AppleWebKit/537.36 (KHTML, like Gecko) " +
    "Chrome/124.0.0.0 Safari/537.36"

// Fallback TOTP secret (matches Python _TOTP_SECRET_RAW)
private let totpSecretRaw: [Int] = [12, 56, 76, 33, 88, 44, 88, 33, 78, 78, 11, 66, 22, 22, 55, 69, 54]

// MARK: - TOTP helpers (static, no actor isolation needed)

enum SpotifyTOTP {
    /// Decode int array → UTF-8 secret bytes via XOR.
    static func secretFromInts(_ values: [Int]) -> Data {
        let xored = values.enumerated().map { idx, val in val ^ ((idx % 33) + 9) }
        return Data(xored.map { String($0) }.joined().utf8)
    }

    /// Decode string → UTF-8 secret bytes via XOR (for bundle-extracted secret).
    static func secretFromString(_ value: String) -> Data {
        let xored = value.unicodeScalars.enumerated().map { idx, c in
            Int(c.value) ^ ((idx % 33) + 9)
        }
        return Data(xored.map { String($0) }.joined().utf8)
    }

    /// RFC 6238 TOTP with HMAC-SHA1, 30-second window, 6 digits.
    static func generate(timestamp: Int, secret: Data) -> String {
        let counter = UInt64(timestamp / 30).bigEndian
        let counterData = withUnsafeBytes(of: counter) { Data($0) }
        let key = SymmetricKey(data: secret)
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: counterData, using: key)
        let digest = Data(mac)
        let offset = Int(digest[digest.count - 1] & 0x0F)
        // Manual big-endian read to avoid misaligned-pointer crash.
        // Data slices are not guaranteed 4-byte aligned; $0.load(as: UInt32.self)
        // crashes when offset % 4 != 0 (probabilistic, depends on HMAC output).
        let b = [UInt8](digest[offset..<offset+4])
        let code = (UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])) & 0x7FFF_FFFF
        return String(format: "%06d", code % 1_000_000)
    }
}

// MARK: - SpotifyAuth

public actor SpotifyAuth {
    private let repository: AppRepository

    // Cached token state
    private var cachedToken: String?
    private var tokenExpiresAt: Date = .distantPast

    // Cached TOTP config
    private var totpSecret: Data?
    private var totpVersion: Int = 5

    public init(repository: AppRepository) {
        self.repository = repository
    }

    // MARK: - Credential management

    public func loadSpDC() async throws -> String? {
        let cred = try await repository.loadCredential("spotify")
        return cred?["sp_dc"]
    }

    public func logout() async throws {
        try await repository.deleteCredential("spotify")
        cachedToken = nil
        tokenExpiresAt = .distantPast
    }

    public func ensureAuthenticated() async throws -> String? {
        if let spDC = try await loadSpDC() { return spDC }
        return await login()
    }

    // MARK: - WKWebView Login (captures sp_dc cookie)

    public func login() async -> String? {
        await loginCookies()?["sp_dc"]
    }

    public func loginCookies() async -> [String: String]? {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                let helper = SpotifyLoginHelper(continuation: continuation)
                helper.start()
            }
        }
    }

    // MARK: - Access Token

    public func getAccessToken() async throws -> String {
        let now = Date()
        if let token = cachedToken, now < tokenExpiresAt.addingTimeInterval(-60) {
            return token
        }

        guard let spDC = try await loadSpDC() else {
            throw SpotifyAuthError.notAuthenticated
        }
        let spKey: String? = (try? await repository.loadCredential("spotify"))?["sp_key"]

        let serverTime = await getServerTime()
        let (secret, version) = await getTotpConfig()
        let clientTime = Int(Date().timeIntervalSince1970)
        let totp = SpotifyTOTP.generate(timestamp: clientTime, secret: secret)
        let totpServer: String
        if let st = serverTime {
            totpServer = SpotifyTOTP.generate(timestamp: st, secret: secret)
        } else {
            totpServer = "unavailable"
        }

        let params: [String: String] = [
            "reason": "transport",
            "productType": "web-player",
            "totp": totp,
            "totpServer": totpServer,
            "totpVer": String(version),
        ]

        var urlComponents = URLComponents(string: tokenURL)!
        urlComponents.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = urlComponents.url else { throw SpotifyAuthError.invalidURL }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(spotifyWebUA, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://open.spotify.com/", forHTTPHeaderField: "Referer")
        var cookieParts = ["sp_dc=\(spDC)"]
        if let key = spKey { cookieParts.append("sp_key=\(key)") }
        request.setValue(cookieParts.joined(separator: "; "), forHTTPHeaderField: "Cookie")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SpotifyAuthError.networkError(error)
        }

        if let http = response as? HTTPURLResponse, http.statusCode == 403 {
            // Fallback: load via hidden WKWebView
            let json = try await fetchTokenViaWebView(params: params, spDC: spDC, spKey: spKey)
            return try extractToken(from: json, now: now)
        }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SpotifyAuthError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return try extractToken(from: json, now: now)
    }

    private func extractToken(from json: [String: Any], now: Date) throws -> String {
        guard let token = json["accessToken"] as? String, !token.isEmpty else {
            throw SpotifyAuthError.missingToken
        }
        cachedToken = token
        if let expiresMs = json["accessTokenExpirationTimestampMs"] as? Double {
            tokenExpiresAt = Date(timeIntervalSince1970: expiresMs / 1000)
        } else {
            tokenExpiresAt = now.addingTimeInterval(3600)
        }
        return token
    }

    // MARK: - Server time

    private func getServerTime() async -> Int? {
        guard let url = URL(string: serverTimeURL) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(spotifyWebUA, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = json["serverTime"] as? Double
        else { return nil }
        return Int(t)
    }

    // MARK: - TOTP config from web-player bundle

    func getTotpConfig() async -> (Data, Int) {
        if let secret = totpSecret { return (secret, totpVersion) }

        if let (secret, version) = await fetchTotpConfigFromBundle() {
            totpSecret = secret
            totpVersion = version
            return (secret, version)
        }

        let fallback = SpotifyTOTP.secretFromInts(totpSecretRaw)
        totpSecret = fallback
        totpVersion = 5
        return (fallback, 5)
    }

    private func fetchTotpConfigFromBundle() async -> (Data, Int)? {
        guard let homeURL = URL(string: webPlayerURL) else { return nil }
        var homeReq = URLRequest(url: homeURL, timeoutInterval: 10)
        homeReq.setValue(spotifyWebUA, forHTTPHeaderField: "User-Agent")
        homeReq.setValue("text/html", forHTTPHeaderField: "Accept")

        guard let (homeData, _) = try? await URLSession.shared.data(for: homeReq),
              let html = String(data: homeData, encoding: .utf8)
        else { return nil }

        // Find web-player bundle URLs
        let bundlePattern = try? NSRegularExpression(
            pattern: #"https://[^"']+/web-player\.[^"']+\.js"#)
        let htmlNS = html as NSString
        let matches = bundlePattern?.matches(in: html, range: NSRange(location: 0, length: htmlNS.length)) ?? []
        let bundleURLs: [String] = Array(
            OrderedSet(matches.compactMap { m -> String? in
                guard let r = Range(m.range, in: html) else { return nil }
                return String(html[r])
            }).prefix(8)
        )

        for urlStr in bundleURLs {
            guard let url = URL(string: urlStr) else { continue }
            var req = URLRequest(url: url, timeoutInterval: 20)
            req.setValue(spotifyWebUA, forHTTPHeaderField: "User-Agent")
            guard let (jsData, _) = try? await URLSession.shared.data(for: req),
                  let js = String(data: jsData, encoding: .utf8),
                  let config = extractTotpConfig(from: js)
            else { continue }
            return config
        }
        return nil
    }

    private func extractTotpConfig(from source: String) -> (Data, Int)? {
        // Narrow the search window around TOTP-related code
        var body = source
        if let marker = source.range(of: "totpServer") ?? source.range(of: "totpVer") {
            let start = source.index(marker.lowerBound, offsetBy: -min(4000, source.distance(from: source.startIndex, to: marker.lowerBound)))
            let end   = source.index(marker.upperBound, offsetBy: min(500,  source.distance(from: marker.upperBound, to: source.endIndex)))
            body = String(source[start..<end])
        }

        let pattern = #"\{\s*secret\s*:\s*(?<secret>'[^']*'|"[^"]*")\s*,\s*version\s*:\s*(?<version>\d+)\s*\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let secretRange  = Range(match.range(withName: "secret"),  in: body),
              let versionRange = Range(match.range(withName: "version"), in: body),
              let version = Int(body[versionRange])
        else { return nil }

        let rawSecret = String(body[secretRange])
        let secretContent: String
        if rawSecret.hasPrefix("\"") {
            // Double-quoted — JSON-parse it
            guard let parsed = try? JSONSerialization.jsonObject(
                with: Data(rawSecret.utf8)) as? String
            else { return nil }
            secretContent = parsed
        } else {
            // Single-quoted JS string
            let inner = rawSecret.dropFirst().dropLast()
            secretContent = inner
                .replacingOccurrences(of: "\\'", with: "'")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return (SpotifyTOTP.secretFromString(secretContent), version)
    }

    // MARK: - WebView token fallback (403 case)

    private func fetchTokenViaWebView(
        params: [String: String],
        spDC: String,
        spKey: String?
    ) async throws -> [String: Any] {
        var urlComponents = URLComponents(string: tokenURL)!
        urlComponents.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = urlComponents.url else { throw SpotifyAuthError.invalidURL }

        var cookies: [HTTPCookie] = []
        if let c = HTTPCookie(properties: [
            .domain: ".spotify.com", .path: "/",
            .name: "sp_dc", .value: spDC,
            .secure: "TRUE", .expires: Date.distantFuture
        ]) { cookies.append(c) }
        if let key = spKey,
           let c = HTTPCookie(properties: [
               .domain: ".spotify.com", .path: "/",
               .name: "sp_key", .value: key,
               .secure: "TRUE", .expires: Date.distantFuture
           ]) { cookies.append(c) }

        return try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                let helper = TokenWebViewHelper(
                    url: url,
                    cookies: cookies,
                    continuation: continuation
                )
                helper.start()
            }
        }
    }

    // MARK: - Display name

    public func getDisplayName() async -> String? {
        guard let spDC = try? await loadSpDC() else { return nil }
        guard let url = URL(string: accountsURL) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(spotifyWebUA, forHTTPHeaderField: "User-Agent")
        request.setValue("sp_dc=\(spDC)", forHTTPHeaderField: "Cookie")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let html = String(data: data, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #""displayName":"([^"]+)""#),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html)
        else { return nil }
        return String(html[range])
    }
}

// MARK: - Login helper (MainActor)

@MainActor
private final class SpotifyLoginHelper: NSObject, WKHTTPCookieStoreObserver, WKNavigationDelegate, WKUIDelegate {
    nonisolated(unsafe) private static var current: SpotifyLoginHelper?

    private let continuation: CheckedContinuation<[String: String]?, Never>
    private var window: NSWindow?
    private weak var webView: WKWebView?
    private var captured: [String: String] = [:]
    private var pollTimer: Timer?
    private var resumed = false

    init(continuation: CheckedContinuation<[String: String]?, Never>) {
        self.continuation = continuation
    }

    func start() {
        SpotifyLoginHelper.current = self
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 860, height: 640), configuration: config)
        webView.customUserAgent = spotifyWebUA
        webView.navigationDelegate = self
        webView.uiDelegate = self
        self.webView = webView

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        win.title = "Spotify — 登录"
        win.initialFirstResponder = webView
        win.isReleasedWhenClosed = false
        win.contentView = webView
        win.center()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.makeMain()
        self.window = win

        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose),
                                               name: NSWindow.willCloseNotification, object: win)
        dataStore.httpCookieStore.add(self)
        webView.load(URLRequest(url: URL(string: loginURL)!))
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        cookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor [weak self] in self?.process(cookies) }
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        guard let webView else { return }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, !self.resumed else { self?.pollTimer?.invalidate(); return }
            store.getAllCookies { [weak self] cookies in
                Task { @MainActor [weak self] in self?.process(cookies) }
            }
        }
    }

    private func process(_ cookies: [HTTPCookie]) {
        guard !resumed else { return }
        for c in cookies {
            if c.name == "sp_dc"  { captured["sp_dc"]  = c.value }
            if c.name == "sp_key" { captured["sp_key"] = c.value }
        }
        if captured["sp_dc"] != nil {
            pollTimer?.invalidate(); pollTimer = nil
            finish(cookies: captured)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        applyFocus(webView); startPolling()
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        applyFocus(webView)
        return nil
    }

    func webViewDidClose(_ webView: WKWebView) { finish(cookies: captured["sp_dc"] == nil ? nil : captured) }

    @objc private func windowWillClose(_ notification: Notification) {
        finish(cookies: captured["sp_dc"] == nil ? nil : captured)
    }

    private func finish(cookies: [String: String]?) {
        guard !resumed else { return }
        resumed = true
        pollTimer?.invalidate(); pollTimer = nil
        NotificationCenter.default.removeObserver(self)
        continuation.resume(returning: cookies)
        webView?.uiDelegate = nil
        webView?.navigationDelegate = nil
        window?.close()
        webView = nil; window = nil
        SpotifyLoginHelper.current = nil
    }

    private func applyFocus(_ webView: WKWebView) {
        DispatchQueue.main.async { [weak self, weak webView] in
            guard let self, let webView, !self.resumed else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.window?.makeKeyAndOrderFront(nil)
            self.window?.makeMain()
            self.window?.makeFirstResponder(webView)
            webView.evaluateJavaScript(
                "(function(){var e=document.querySelector('input:not([type=hidden]),textarea');if(e){e.focus();e.click();}})()",
                completionHandler: nil
            )
        }
    }
}

// MARK: - WebView token fallback helper (MainActor)

@MainActor
private final class TokenWebViewHelper: NSObject, WKNavigationDelegate {
    private let url: URL
    private let cookies: [HTTPCookie]
    private let continuation: CheckedContinuation<[String: Any], Error>
    private var window: NSWindow?
    private var webView: WKWebView?
    private var resumed = false

    init(url: URL, cookies: [HTTPCookie], continuation: CheckedContinuation<[String: Any], Error>) {
        self.url = url
        self.cookies = cookies
        self.continuation = continuation
    }

    func start() {
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore

        let group = DispatchGroup()
        for cookie in cookies {
            group.enter()
            dataStore.httpCookieStore.setCookie(cookie) { group.leave() }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
            wv.customUserAgent = spotifyWebUA
            wv.navigationDelegate = self

            let win = NSWindow(
                contentRect: NSRect(x: -1000, y: 0, width: 1, height: 1),
                styleMask: [],
                backing: .buffered,
                defer: false
            )
            win.contentView = wv
            self.window = win
            self.webView = wv
            wv.load(URLRequest(url: self.url))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("document.body.innerText") { [weak self] result, _ in
            guard let self, !self.resumed else { return }
            let text = result as? String ?? ""
            let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
            self.finish(result: .success(json))
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(result: .failure(SpotifyAuthError.networkError(error)))
    }

    private func finish(result: Result<[String: Any], Error>) {
        guard !resumed else { return }
        resumed = true
        window?.close()
        window = nil
        switch result {
        case .success(let json): continuation.resume(returning: json)
        case .failure(let err):  continuation.resume(throwing: err)
        }
    }
}

// MARK: - Errors

public enum SpotifyAuthError: Error {
    case notAuthenticated
    case invalidURL
    case httpError(Int)
    case networkError(Error)
    case missingToken
}

// MARK: - OrderedSet utility (deduplicate while preserving order)

private struct OrderedSet<T: Hashable>: Sequence {
    private var set = Set<T>()
    private var array = [T]()

    mutating func insert(_ element: T) {
        if set.insert(element).inserted { array.append(element) }
    }

    func prefix(_ n: Int) -> [T] { Array(array.prefix(n)) }
    func makeIterator() -> IndexingIterator<[T]> { array.makeIterator() }
}

private extension OrderedSet where T == String {
    init(_ elements: [T]) {
        self.init()
        elements.forEach { insert($0) }
    }
}
