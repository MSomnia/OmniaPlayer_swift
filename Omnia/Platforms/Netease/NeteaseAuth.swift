import Foundation
import WebKit
import AppKit

private let loginURL                = "https://music.163.com/#/login"
private let accountURL              = "https://music.163.com/weapi/nuser/account/get"
private let authenticatedCookieName = "MUSIC_U"
private let capturedCookieNames     = Set(["MUSIC_U", "__csrf"])

public actor NeteaseAuth {
    private let repository: AppRepository

    public init(repository: AppRepository) { self.repository = repository }

    public func loadCookies() async throws -> [String: String]? {
        try await repository.loadCredential("netease")
    }

    public func logout() async throws {
        try await repository.deleteCredential("netease")
    }

    public func login() async -> [String: String]? {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                let helper = NeteaseLoginHelper(continuation: continuation)
                helper.start()
            }
        }
    }

    public func getDisplayName() async -> String? {
        guard let cookies = try? await loadCookies(), cookies["MUSIC_U"] != nil else { return nil }
        guard let payload = try? NeteaseCrypto.weapiEncrypt(["csrf_token": cookies["__csrf"] ?? ""])
        else { return nil }
        var request = URLRequest(url: URL(string: accountURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(neteaseUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue(cookieHeader(cookies), forHTTPHeaderField: "Cookie")
        request.httpBody = formEncode(payload)
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let nickname = (json["profile"] as? [String: Any])?["nickname"] as? String
        let userName = (json["account"] as? [String: Any])?["userName"] as? String
        return nickname ?? userName
    }

    public func ensureAuthenticated() async throws -> [String: String]? {
        if let c = try await loadCookies(), c["MUSIC_U"] != nil { return c }
        let captured = await login()
        if let captured { try await repository.saveCredential("netease", data: captured) }
        return captured
    }
}

// MARK: - Login helper (MainActor)

@MainActor
private final class NeteaseLoginHelper: NSObject, WKHTTPCookieStoreObserver, WKNavigationDelegate, WKUIDelegate {

    // Holds strong ref so WebKit's weak delegate/observer pointers don't drop us.
    nonisolated(unsafe) private static var current: NeteaseLoginHelper?

    private let continuation: CheckedContinuation<[String: String]?, Never>
    private var window: NSWindow?
    private weak var webView: WKWebView?
    private var captured: [String: String] = [:]
    private var pollTimer: Timer?
    private var resumed = false

    init(continuation: CheckedContinuation<[String: String]?, Never>) {
        self.continuation = continuation
    }

    // MARK: Setup

    func start() {
        NeteaseLoginHelper.current = self
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 860, height: 640), configuration: config)
        webView.customUserAgent = neteaseUserAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self
        self.webView = webView

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        win.title = "网易云音乐 — 登录"
        win.initialFirstResponder = webView
        win.isReleasedWhenClosed = false
        win.contentView = webView
        win.center()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.makeMain()
        self.window = win

        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: win)
        // Register cookie observer as a fast-path secondary trigger.
        dataStore.httpCookieStore.add(self)
        webView.load(URLRequest(url: URL(string: loginURL)!))
    }

    // MARK: Cookie detection

    /// Secondary: fires when WebKit updates the cookie store.
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        cookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor [weak self] in self?.process(cookies) }
        }
    }

    /// Primary: 1-second poll via traditional callback API, started after first page load.
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
        let before = captured.keys.sorted()
        for c in cookies where capturedCookieNames.contains(c.name) {
            captured[c.name] = c.value
        }
        let after = captured.keys.sorted()
        if after != before {
            NSLog("[NeteaseAuth] cookies captured so far: \(after)")
        }
        if captured[authenticatedCookieName] != nil {
            NSLog("[NeteaseAuth] ✓ auth cookie detected, captured: \(captured.keys.sorted())")
            pollTimer?.invalidate(); pollTimer = nil
            finish(result: captured)
        }
    }

    // MARK: Navigation delegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        applyFocus(webView)
        startPolling()
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        applyFocus(webView)
        return nil
    }

    func webViewDidClose(_ webView: WKWebView) { finish(result: captured.isEmpty ? nil : captured) }

    // MARK: Teardown

    @objc private func windowWillClose(_ notification: Notification) {
        finish(result: captured.isEmpty ? nil : captured)
    }

    private func finish(result: [String: String]?) {
        guard !resumed else { return }
        resumed = true
        pollTimer?.invalidate(); pollTimer = nil
        NotificationCenter.default.removeObserver(self)
        NSLog("[NeteaseAuth] finish: result keys = \(result?.keys.sorted() ?? [])")
        continuation.resume(returning: result)
        webView?.uiDelegate = nil
        webView?.navigationDelegate = nil
        window?.close()
        webView = nil; window = nil
        NeteaseLoginHelper.current = nil
    }

    // MARK: Focus

    private func applyFocus(_ webView: WKWebView) {
        DispatchQueue.main.async { [weak self, weak webView] in
            guard let self, let webView, !self.resumed else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.window?.makeKeyAndOrderFront(nil)
            self.window?.makeMain()
            self.window?.makeFirstResponder(webView)
            webView.evaluateJavaScript(
                "(function(){var e=document.querySelector('input:not([type=hidden]),textarea');if(e){e.focus();e.click();}})()",
                completionHandler: nil)
        }
    }
}

// MARK: - Shared HTTP helpers

let neteaseUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

func cookieHeader(_ cookies: [String: String]) -> String {
    cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
}

private func percentEncode(_ s: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
}

func formEncode(_ dict: [String: String]) -> Data {
    Data(dict.map { "\(percentEncode($0.key))=\(percentEncode($0.value))" }.joined(separator: "&").utf8)
}
