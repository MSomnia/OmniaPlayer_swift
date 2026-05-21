import SwiftUI
import AppKit

// MARK: - PageID

public enum PageID: String, Hashable {
    case home, search, aggregateSearch, library, settings, lyrics, artist, standby
}

// MARK: - MainWindowView

public struct MainWindowView: View {
    @ObservedObject var ctrl: AppController

    @State private var toastMessage: String = ""
    @State private var toastVisible: Bool = false

    @State private var bgImage: NSImage? = nil

    // Idle standby
    @State private var lastInteraction: Date = Date()
    @State private var idleCheckTimer: Timer?
    @State private var autoStandbyMinutes: Int = 0  // 0 = disabled

    public init(ctrl: AppController) { self.ctrl = ctrl }

    public var body: some View {
        HStack(spacing: 0) {

            // ── Sidebar ────────────────────────────────────────────────────
            SidebarView(currentPage: $ctrl.currentPage, ctrl: ctrl)
                .frame(width: 200)

            // ── Content area ───────────────────────────────────────────────
            ZStack {
                FrostedPanel()
                    .allowsHitTesting(false)
                contentView
                    .animation(.easeInOut(duration: 0.18), value: ctrl.currentPage)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            NowPlayingBarView(ctrl: ctrl)
        }
        // Window-owned background image/base color. Translucent UI layers sample this,
        // not whatever is behind the app window.
        .background {
            ZStack {
                Theme.bgBase
                windowBackground
            }
            .ignoresSafeArea()
        }
        // Full-screen standby overlay (covers sidebar + NowPlayingBar)
        .overlay {
            if ctrl.currentPage == .standby {
                StandbyPageView(ctrl: ctrl, bgImage: bgImage)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: ctrl.currentPage)
            }
        }
        .overlay {
            if let toast = ctrl.centerToast {
                centerToastView(toast.message)
                    .id(toast.id)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: ctrl.centerToast?.id)
        .overlay(alignment: .top) {
            if toastVisible { toastView }
        }
        .foregroundStyle(Theme.primaryText)
        .frame(minWidth: 900, minHeight: 600)
        .onContinuousHover { _ in resetIdle() }
        .task { await setup() }
        .onChange(of: ctrl.backgroundImagePath) { path in loadBgImage(path) }
        .sheet(item: $ctrl.loginSheetConfig) { config in
            LoginSheet(config: config) { cookies in
                Task { await ctrl.handleLoginResult(platform: config.id, cookies: cookies) }
            }
        }
        .onChange(of: ctrl.playerState.status) { status in
            if status == .error {
                let title = ctrl.playerState.currentTrack?.title ?? "当前曲目"
                showToast("播放出错：\(title)")
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    await ctrl.playNext()
                }
            }
        }
        .onChange(of: ctrl.lastPlaylistError) { err in
            guard !err.isEmpty else { return }
            showToast(err)
        }
    }

    // MARK: - Background image (blurred, shown only when a path is set)

    @ViewBuilder private var windowBackground: some View {
        if let img = bgImage {
            Image(nsImage: img)
                .resizable()
                .scaledToFill()
                .blur(radius: 28, opaque: true)
                .overlay(Color.black.opacity(0.30))
        }
        // No image → Theme.bgBase from the outer background is the fallback.
    }

    // MARK: - Page routing

    @ViewBuilder private var contentView: some View {
        switch ctrl.currentPage {
        case .home:            HomePageView(ctrl: ctrl)
        case .search:          SearchPageView(ctrl: ctrl)
        case .aggregateSearch: AggregateSearchPageView(ctrl: ctrl)
        case .library:         LibraryPageView(ctrl: ctrl)
        case .settings:        SettingsPageView(ctrl: ctrl)
        case .lyrics:          LyricsView(ctrl: ctrl)
        case .artist:          ArtistPageView(ctrl: ctrl)
        case .standby:         HomePageView(ctrl: ctrl)  // underlying page; standby shown via overlay
        }
    }

    // MARK: - Setup

    private func setup() async {
        try? await ctrl.initialize()
        loadBgImage(ctrl.backgroundImagePath)
        loadAutoStandbyMinutes()
        startIdleTimer()
        ctrl.preloadInitialContent()
    }

    private func loadBgImage(_ path: String) {
        guard !path.isEmpty else { bgImage = nil; return }
        bgImage = NSImage(contentsOfFile: path)
    }

    // MARK: - Toast

    private var toastView: some View {
        Text(toastMessage)
            .font(Theme.font(Theme.fontSM))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.85))
            .clipShape(Capsule())
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func centerToastView(_ message: String) -> some View {
        Text(message)
            .font(Theme.font(Theme.fontMD, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(Color.black.opacity(0.86))
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }

    func showToast(_ message: String) {
        toastMessage = message
        withAnimation { toastVisible = true }
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation { toastVisible = false }
        }
    }

    // MARK: - Idle / auto-standby

    private func loadAutoStandbyMinutes() {
        Task {
            if let val = try? await ctrl.repo_getSetting("auto_standby_minutes"),
               let mins = Int(val) {
                autoStandbyMinutes = mins
            }
        }
    }

    private func startIdleTimer() {
        idleCheckTimer?.invalidate()
        idleCheckTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in checkIdle() }
        }
    }

    private func resetIdle() {
        lastInteraction = Date()
    }

    private func checkIdle() {
        guard autoStandbyMinutes > 0 else { return }
        guard ctrl.playerState.status == .playing else { return }
        guard ctrl.currentPage != .settings else { return }
        let elapsed = Date().timeIntervalSince(lastInteraction)
        if elapsed >= Double(autoStandbyMinutes * 60) {
            ctrl.currentPage = .standby
        }
    }
}

// MARK: - AppController repo_getSetting helper for MainWindowView

extension AppController {
    func repo_getSetting(_ key: String) async throws -> String? {
        try await repo.getSetting(key)
    }
}
