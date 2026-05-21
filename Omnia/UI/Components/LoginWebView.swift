import SwiftUI
import WebKit

// MARK: - Platform login configuration

/// Describes one platform's login URL and cookie expectations.
/// Identifiable so it can be used with `.sheet(item:)`.
public struct PlatformLoginConfig: Identifiable {
    public let id: String                  // platform id: "netease" | "spotify" | "ytmusic"
    public let title: String
    public let url: URL
    /// Auto-close when ALL of these cookies appear.
    public let targetCookies: Set<String>
    /// Capture every cookie (not just target ones). Used by YTMusic.
    public let captureAll: Bool
    /// Show a "手动输入 Cookie" fallback text field.
    public let showManualEntry: Bool

    // MARK: Preset configurations

    public static var netease: PlatformLoginConfig {
        PlatformLoginConfig(
            id: "netease",
            title: "网易云音乐 — 登录",
            url: URL(string: "https://music.163.com/#/login")!,
            targetCookies: ["MUSIC_U", "__csrf"],
            captureAll: false,
            showManualEntry: false
        )
    }

    public static var spotify: PlatformLoginConfig {
        PlatformLoginConfig(
            id: "spotify",
            title: "Spotify — 登录",
            url: URL(string: "https://open.spotify.com/")!,
            targetCookies: ["sp_dc"],
            captureAll: false,
            showManualEntry: false
        )
    }

    public static var ytMusic: PlatformLoginConfig {
        PlatformLoginConfig(
            id: "ytmusic",
            title: "YouTube Music — 登录",
            url: URL(string: "https://music.youtube.com")!,
            targetCookies: ["__Secure-3PAPISID", "SAPISID", "__Secure-1PAPISID"],
            captureAll: true,
            showManualEntry: true   // Google may block WKWebView; show manual fallback
        )
    }
}

// MARK: - LoginWebView (NSViewRepresentable)

/// WKWebView wrapper that observes cookies and fires `onCookiesCaptured`
/// when target cookies are all present (or on every change when no target set).
///
/// All platforms use Safari-like UA: WKWebView runs WebKit/JavaScriptCore;
/// a Chrome UA would mismatch the engine and trigger detection.
private let kLoginUA =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"

// WKWebView subclass for macOS SwiftUI sheets.
// Keyboard input requires the WebKit content process to be running before
// makeFirstResponder has any effect, so we defer it to the next run-loop turn
// (viewDidMoveToWindow) and again after the first navigation completes.
private final class FocusableWebView: WKWebView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Deferred so the window is fully set up when we call makeFirstResponder.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.window?.makeFirstResponder(self)
        }
    }
}

public struct LoginWebView: NSViewRepresentable {
    let url: URL
    let targetCookies: Set<String>
    let captureAll: Bool
    /// Called once when target cookies are all present; or on every change if targetCookies is empty.
    let onCookiesCaptured: ([String: String]) -> Void

    public init(
        url: URL,
        targetCookies: Set<String> = [],
        captureAll: Bool = false,
        onCookiesCaptured: @escaping ([String: String]) -> Void
    ) {
        self.url = url
        self.targetCookies = targetCookies
        self.captureAll = captureAll
        self.onCookiesCaptured = onCookiesCaptured
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            targetCookies: targetCookies,
            captureAll: captureAll,
            onCaptured: onCookiesCaptured
        )
    }

    public func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()

        let webView = FocusableWebView(frame: .zero, configuration: config)
        webView.customUserAgent = kLoginUA
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        config.websiteDataStore.httpCookieStore.add(context.coordinator)
        webView.load(URLRequest(url: url))
        return webView
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {}

    public static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.uiDelegate = nil
        nsView.navigationDelegate = nil
        nsView.configuration.websiteDataStore.httpCookieStore.remove(coordinator)
    }

    // MARK: - Coordinator

    public final class Coordinator: NSObject, WKHTTPCookieStoreObserver, WKNavigationDelegate, WKUIDelegate {
        // Re-assert first responder after each page load (handles redirects too).
        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            focus(webView)
        }

        public func webView(
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

        private let targetCookies: Set<String>
        private let captureAll: Bool
        private let onCaptured: ([String: String]) -> Void

        private(set) var captured: [String: String] = [:]
        private var fired = false

        init(
            targetCookies: Set<String>,
            captureAll: Bool,
            onCaptured: @escaping ([String: String]) -> Void
        ) {
            self.targetCookies = targetCookies
            self.captureAll    = captureAll
            self.onCaptured    = onCaptured
        }

        public nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let cookies = await cookieStore.allCookies()
                for cookie in cookies {
                    if self.captureAll || self.targetCookies.contains(cookie.name) {
                        self.captured[cookie.name] = cookie.value
                    }
                }
                // Auto-fire when all target cookies have arrived
                if !self.targetCookies.isEmpty,
                   self.targetCookies.isSubset(of: Set(self.captured.keys)),
                   !self.fired {
                    self.fired = true
                    self.onCaptured(self.captured)
                }
            }
        }

        /// Returns a current snapshot of captured cookies (for manual-done path).
        func snapshot() -> [String: String] { captured }

        private func focus(_ webView: WKWebView) {
            DispatchQueue.main.async { [weak webView] in
                guard let webView else { return }
                NSApp.activate(ignoringOtherApps: true)
                webView.window?.makeKeyAndOrderFront(nil)
                webView.window?.makeFirstResponder(webView)
            }
        }
    }
}

// MARK: - LoginSheet

/// A SwiftUI sheet containing a `LoginWebView` with a title bar and action buttons.
/// Present via `.sheet(item: $ctrl.loginSheetConfig)`.
public struct LoginSheet: View {
    let config: PlatformLoginConfig
    let onComplete: ([String: String]?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var capturedCookies: [String: String] = [:]
    @State private var showManualEntry = false
    @State private var manualText = ""

    public init(config: PlatformLoginConfig, onComplete: @escaping ([String: String]?) -> Void) {
        self.config = config
        self.onComplete = onComplete
    }

    public var body: some View {
        VStack(spacing: 0) {
            titleBar
            if showManualEntry { manualEntryPanel }
            LoginWebView(
                url: config.url,
                targetCookies: config.targetCookies,
                captureAll: config.captureAll,
                onCookiesCaptured: { cookies in
                    capturedCookies.merge(cookies) { _, new in new }
                    // Auto-close when all target cookies present
                    if !config.targetCookies.isEmpty,
                       config.targetCookies.isSubset(of: Set(capturedCookies.keys)) {
                        finish(with: capturedCookies)
                    }
                }
            )
        }
        .frame(width: 900, height: 660)
        .background(Theme.bgBase)
    }

    // MARK: Title bar

    private var titleBar: some View {
        HStack(spacing: 10) {
            Text(config.title)
                .font(Theme.font(Theme.fontMD, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            Spacer()
            // Manual-entry toggle (YTMusic fallback)
            if config.showManualEntry {
                Button(showManualEntry ? "隐藏 Cookie 输入" : "手动输入 Cookie") {
                    showManualEntry.toggle()
                }
                .buttonStyle(.bordered)
                .font(Theme.font(Theme.fontSM))
                .foregroundStyle(Theme.secondaryText)
            }
            Button("取消") { finish(with: nil) }
                .buttonStyle(.bordered)
                .font(Theme.font(Theme.fontSM))
            Button("我已登录") { finish(with: capturedCookies.isEmpty ? nil : capturedCookies) }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .font(Theme.font(Theme.fontSM, weight: .semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.bgElevated)
    }

    // MARK: Manual entry fallback

    private var manualEntryPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("从浏览器开发者工具 → Network → 任意请求 → Request Headers → Cookie 处复制：")
                .font(Theme.font(Theme.fontSM))
                .foregroundStyle(Theme.secondaryText)
            HStack(spacing: 8) {
                TextEditor(text: $manualText)
                    .font(.system(size: Theme.fontXS, design: .monospaced))
                    .frame(height: 56)
                    .scrollContentBackground(.hidden)
                    .background(Theme.bgBase)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Theme.border, lineWidth: 1)
                    )
                Button("应用") { applyManualCookies() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .font(Theme.font(Theme.fontSM))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.bgSurface)
    }

    // MARK: Helpers

    private func applyManualCookies() {
        var text = manualText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("cookie:") {
            text = String(text.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        var parsed: [String: String] = [:]
        for part in text.components(separatedBy: ";") {
            let t = part.trimmingCharacters(in: .whitespaces)
            guard let eq = t.firstIndex(of: "=") else { continue }
            let name = String(t[..<eq]).trimmingCharacters(in: .whitespaces)
            let val  = String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !val.isEmpty { parsed[name] = val }
        }
        if !parsed.isEmpty {
            capturedCookies.merge(parsed) { _, new in new }
        }
    }

    private func finish(with cookies: [String: String]?) {
        onComplete(cookies)
        dismiss()
    }
}
