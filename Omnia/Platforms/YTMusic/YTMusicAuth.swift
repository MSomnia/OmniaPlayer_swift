import Foundation
import CryptoKit
import WebKit
import AppKit

// MARK: - Constants

private let ytmLoginURL = "https://music.youtube.com"
private let ytmOrigin   = "https://music.youtube.com"

// Safari UA: matches WKWebView's actual engine, avoids Chrome-UA/WebKit mismatch detection.
let ytmSafariUA =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
    "AppleWebKit/605.1.15 (KHTML, like Gecko) " +
    "Version/17.6 Safari/605.1.15"

// Auto-close login window when any of these cookies appear.
private let authCookieNames: Set<String> = [
    "__Secure-3PAPISID", "SAPISID", "__Secure-1PAPISID"
]

// Set via environment variable INNERTUBE_API_KEY or replace at build time.
let ytmInnertubeKey = ProcessInfo.processInfo.environment["INNERTUBE_API_KEY"] ?? ""

// MARK: - YTMusicAuth

public actor YTMusicAuth {
    private let repository: AppRepository

    public init(repository: AppRepository) {
        self.repository = repository
    }

    // MARK: - Credential management

    public func loadAuth() async throws -> [String: String]? {
        try await repository.loadCredential("ytmusic")
    }

    public func logout() async throws {
        try await repository.deleteCredential("ytmusic")
    }

    public func ensureAuthenticated() async throws -> [String: String]? {
        if let auth = try await loadAuth(), auth["Cookie"] != nil { return auth }
        return await login()
    }

    // MARK: - WKWebView Login

    /// Open a WKWebView window for the user to sign in to music.youtube.com.
    /// Returns the headers dict ready to persist, or nil if cancelled.
    public func login() async -> [String: String]? {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                let helper = YTMusicLoginHelper(continuation: continuation)
                helper.start()
            }
        }
    }

    // MARK: - Display name

    public func getDisplayName() async -> String? {
        guard let headers = try? await loadAuth(),
              let cookieStr = headers["Cookie"] else { return nil }
        let sapisid = extractCookieValue("__Secure-3PAPISID", from: cookieStr)
            ?? extractCookieValue("__Secure-1PAPISID", from: cookieStr)
            ?? extractCookieValue("SAPISID", from: cookieStr)
            ?? ""
        let body: [String: Any] = ["context": YTMusicAuth.innertubeContext()]
        guard let url = URL(string: "https://music.youtube.com/youtubei/v1/account/account_menu?key=\(ytmInnertubeKey)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(ytmSafariUA, forHTTPHeaderField: "User-Agent")
        request.setValue(cookieStr, forHTTPHeaderField: "Cookie")
        request.setValue(YTMusicAuth.makeSapisidhash(sapisid), forHTTPHeaderField: "Authorization")
        request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        request.setValue(ytmOrigin, forHTTPHeaderField: "x-origin")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let actions = json["actions"] as? [[String: Any]] ?? []
        for action in actions {
            if let header = ((((action["openPopupAction"] as? [String: Any])?["popup"] as? [String: Any])?["multiPageMenuRenderer"] as? [String: Any])?["header"] as? [String: Any])?["activeAccountHeaderRenderer"] as? [String: Any],
               let runs = (header["accountName"] as? [String: Any])?["runs"] as? [[String: Any]],
               let text = runs.first?["text"] as? String {
                return text
            }
        }
        return nil
    }

    // MARK: - Static helpers (used by YTMusicClient)

    /// Compute Authorization: SAPISIDHASH header value.
    public static func makeSapisidhash(_ sapisid: String) -> String {
        let ts = Int(Date().timeIntervalSince1970)
        let message = "\(ts) \(sapisid) \(ytmOrigin)"
        let digest = Insecure.SHA1.hash(data: Data(message.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(ts)_\(hex)"
    }

    /// Build headers dict from captured cookies (to persist in AppRepository).
    public static func buildHeaders(from cookies: [String: String]) -> [String: String] {
        var normalizedCookies = cookies
        if normalizedCookies["SOCS"] == nil {
            normalizedCookies["SOCS"] = "CAI"
        }
        let cookieStr = normalizedCookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        let sapisid = cookies["__Secure-3PAPISID"]
            ?? cookies["__Secure-1PAPISID"]
            ?? cookies["SAPISID"]
            ?? ""
        return [
            "User-Agent":      ytmSafariUA,
            "Accept":          "*/*",
            "Accept-Language": "en-US,en;q=0.5",
            "Content-Type":    "application/json",
            "Authorization":   makeSapisidhash(sapisid),
            "X-Goog-AuthUser": "0",
            "x-origin":        ytmOrigin,
            "Cookie":          cookieStr,
        ]
    }

    public static func innertubeContext() -> [String: Any] {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return [
            "client": [
                "clientName":    "WEB_REMIX",
                "clientVersion": "1.\(formatter.string(from: Date())).01.00",
                "hl":            "en",
            ] as [String: Any],
            "user": [:] as [String: Any],
        ]
    }
}

// MARK: - Login helper (MainActor)

@MainActor
private final class YTMusicLoginHelper: NSObject, WKHTTPCookieStoreObserver, WKNavigationDelegate, WKUIDelegate {
    nonisolated(unsafe) private static var current: YTMusicLoginHelper?

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
        YTMusicLoginHelper.current = self
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 660), configuration: config)
        webView.customUserAgent = ytmSafariUA
        webView.navigationDelegate = self
        webView.uiDelegate = self
        self.webView = webView

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 660),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "YouTube Music — 登录"
        win.initialFirstResponder = webView
        win.isReleasedWhenClosed = false
        win.contentView = webView
        win.center()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.makeMain()
        self.window = win
        focus(webView)

        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose),
            name: NSWindow.willCloseNotification, object: win
        )
        dataStore.httpCookieStore.add(self)
        webView.load(URLRequest(url: URL(string: ytmLoginURL)!))
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
        for c in cookies { captured[c.name] = c.value }
        let hasAuth = authCookieNames.contains { captured[$0] != nil }
        if hasAuth {
            pollTimer?.invalidate(); pollTimer = nil
            finish(with: captured)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        focus(webView); startPolling()
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        focus(webView)
        return nil
    }

    func webViewDidClose(_ webView: WKWebView) {
        finish(with: captured.isEmpty ? nil : captured)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        finish(with: captured.isEmpty ? nil : captured)
    }

    private func finish(with cookies: [String: String]?) {
        guard !resumed else { return }
        resumed = true
        pollTimer?.invalidate(); pollTimer = nil
        NotificationCenter.default.removeObserver(self)
        let headers = cookies.map { YTMusicAuth.buildHeaders(from: $0) }
        continuation.resume(returning: headers)
        webView?.uiDelegate = nil
        webView?.navigationDelegate = nil
        window?.close()
        webView = nil; window = nil
        YTMusicLoginHelper.current = nil
    }

    private func focus(_ webView: WKWebView) {
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

// MARK: - Cookie helpers (shared with YTMusicClient)

func extractCookieValue(_ name: String, from cookieStr: String) -> String? {
    for part in cookieStr.components(separatedBy: ";") {
        let trimmed = part.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix(name + "=") {
            return String(trimmed.dropFirst(name.count + 1))
        }
    }
    return nil
}
