import Foundation
import Combine

public struct AppToast: Identifiable, Equatable {
    public let id = UUID()
    public let message: String
}

// MARK: - Constants

private let homeCacheTTL:    TimeInterval = 600   // 10 min
private let libraryCacheTTL: TimeInterval = 300   // 5 min
private let tracksCacheTTL:  TimeInterval = 300   // 5 min
private let tracksCacheMax   = 30
private let streamURLCacheTTL: TimeInterval = 20 * 60
private let streamURLCacheMax = 80

private let prefetchThresholds: [String: Int] = [
    "netease": 5_000,
    "ytmusic": 25_000,
    "spotify": 20_000,
]
private let prefetchFallbackMs = 30_000

// Cycle order matches Python: none → all → one → none
private let repeatCycle: [RepeatMode] = [.none, .all, .one]

// MARK: - AppController

@MainActor
public final class AppController: ObservableObject {

    // MARK: Published state

    @Published public private(set) var playerState: PlayerState = PlayerState()
    @Published public private(set) var queue: [Track] = []
    @Published public private(set) var queueIndex: Int = -1
    @Published public private(set) var currentLyrics: [LyricLine] = []
    @Published public private(set) var currentCoverColor: (Int, Int, Int) = (0, 0, 0)
    @Published public private(set) var currentCoverData: Data? = nil
    @Published public private(set) var isNeteaseAuthenticated: Bool = false
    @Published public private(set) var isYTMusicAuthenticated: Bool = false
    @Published public private(set) var isSpotifyAuthenticated: Bool = false
    @Published public private(set) var displayName: String = "Omnia"
    @Published public private(set) var backgroundImagePath: String = ""
    @Published public private(set) var homeSections: [String: [(String, [Track])]] = [:]
    @Published public private(set) var library: [String: [Playlist]] = [:]
    @Published public private(set) var searchResults: [Track] = []
    @Published public private(set) var albumSearchResults: [String: [Album]] = [:]
    @Published public private(set) var artistInfo: Artist? = nil
    @Published public private(set) var artistTracks: [Track] = []
    @Published public private(set) var updateStatus: UpdateStatus? = nil
    @Published public private(set) var canCheckForUpdates: Bool = false
    @Published public private(set) var lastPlaylistError: String = ""
    @Published public private(set) var centerToast: AppToast? = nil

    /// Set to show a LoginSheet; cleared by `handleLoginResult`.
    @Published public var loginSheetConfig: PlatformLoginConfig? = nil

    /// Current visible page — pages can write this to trigger navigation.
    @Published public var currentPage: PageID = .home
    /// Page to return to after leaving the artist page.
    @Published public var pageBeforeArtist: PageID = .home
    /// Page to return to after leaving the lyrics page.
    @Published public var pageBeforeLyrics: PageID = .home
    /// Platform whose library is currently shown in LibraryPageView.
    @Published public var libraryPlatform: String = "netease"

    // MARK: Sub-systems

    internal let repo: AppRepository
    private let playerMachine: PlayerStateMachine
    private let playQueue: PlayQueue
    private let vlc: VLCBackend
    private let librespotBackend: LibrespotBackend
    private var neteaseClient: NeteaseClient?
    private var ytmClient: YTMusicClient?
    private var spotifyClient: SpotifyClient?
    private let neteaseAuth: NeteaseAuth
    private let ytmAuth: YTMusicAuth
    private let spotifyAuth: SpotifyAuth
    private let librespotBridge: LibrespotBridge
    private let macosMedia: MacOSMediaHandler
    private let releaseUpdater: GitHubReleaseUpdateService

    // MARK: Caches

    private var homeCache:    [String: (Date, [(String, [Track])])] = [:]
    private var libraryCache: [String: (Date, [Playlist])]          = [:]
    private var tracksCache:  [String: (Date, [Track])]             = [:]
    private var streamURLCache: [String: (Date, String)]            = [:]
    private var streamURLTasks: [String: Task<String, Error>]        = [:]

    // MARK: Prefetch

    private var prefetchTask: Task<Void, Never>?
    private var prefetchDone = false
    private var prefetchedAutoplay: [Track]?
    private var initialContentPreloadTask: Task<Void, Never>?
    private var centerToastTask: Task<Void, Never>?
    private var autoAdvanceKey: String?

    // Seek suppression: VLC keeps polling the old position for ~300-500 ms after
    // a seek command, causing positionMs (and lyric highlight) to briefly revert.
    // Track the seek target so the VLC callback can discard stale pre-seek reports.
    private var pendingSeekTarget: Int? = nil
    private var pendingSeekTime: Date? = nil

    // MARK: Cancellables

    private var cancellables = Set<AnyCancellable>()

    public var appVersionText: String {
        releaseUpdater.currentVersionText
    }

    public var updateSourceText: String {
        releaseUpdater.updateSourceText
    }

    // MARK: - Init

    public init() {
        let db = AppDatabase.shared
        repo = AppRepository(database: db)

        let bridge = LibrespotBridge()
        librespotBridge = bridge
        librespotBackend = LibrespotBackend(bridge: bridge)

        playerMachine = PlayerStateMachine()
        playQueue     = PlayQueue()
        vlc           = VLCBackend()
        neteaseAuth   = NeteaseAuth(repository: repo)
        ytmAuth       = YTMusicAuth(repository: repo)
        spotifyAuth   = SpotifyAuth(repository: repo)
        macosMedia    = MacOSMediaHandler()
        releaseUpdater = GitHubReleaseUpdateService()

        // Mirror PlayerStateMachine.state into our @Published playerState
        playerMachine.$state
            .receive(on: RunLoop.main)
            .assign(to: &$playerState)

        // Mirror PlayQueue into @Published queue / queueIndex
        playQueue.$tracks
            .receive(on: RunLoop.main)
            .assign(to: &$queue)
        playQueue.$currentIndex
            .receive(on: RunLoop.main)
            .assign(to: &$queueIndex)

        releaseUpdater.$status
            .receive(on: RunLoop.main)
            .assign(to: &$updateStatus)

        releaseUpdater.$canCheckForUpdates
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    // MARK: - Initialization

    public func initialize() async throws {
        try await AppDatabase.shared.setup()

        // Restore display name and background
        displayName         = (try? await repo.getSetting("display_name")) ?? "Omnia"
        let savedBgPath     = (try? await repo.getSetting("background_image_path")) ?? ""
        backgroundImagePath = savedBgPath.isEmpty
            ? (Bundle.module.path(forResource: "default", ofType: "PNG", inDirectory: "pics") ?? "")
            : savedBgPath

        // Restore volume / shuffle / repeat
        if let volStr = try? await repo.getSetting("volume"), let vol = Int(volStr) {
            let restoredVolume = max(0, min(vol, 100))
            playerMachine.setVolume(restoredVolume)
            applyVolumeToBackends(restoredVolume)
        } else {
            applyVolumeToBackends(playerMachine.state.volume)
        }
        if let shuffle = try? await repo.getSetting("shuffle") {
            playerMachine.setShuffle(shuffle == "true")
        }
        if let repeatStr = try? await repo.getSetting("repeat_mode"),
           let mode = RepeatMode(rawValue: repeatStr) {
            playerMachine.setRepeatMode(mode)
        }

        // Wire audio backend callbacks
        wireBackendCallbacks()

        // Restore Netease session
        if let cookies = try? await neteaseAuth.loadCookies(), cookies["MUSIC_U"] != nil {
            neteaseClient = NeteaseClient(cookies: cookies)
            isNeteaseAuthenticated = true
        }

        // Restore YTMusic session
        if let headers = try? await ytmAuth.loadAuth(), headers["Cookie"] != nil {
            ytmClient = YTMusicClient(headers: headers)
            isYTMusicAuthenticated = true
        }

        // Restore Spotify session
        if (try? await spotifyAuth.loadSpDC()) != nil {
            spotifyClient = SpotifyClient(auth: spotifyAuth)
            isSpotifyAuthenticated = true
            warmUpSpotifyPlayback()
            // Attempt to restore librespot credentials (non-blocking)
            if librespotBridge.hasSession() {
                // credentials.json already present — librespot can start directly
            }
        }

        macosMedia.setup(controller: self)
    }

    public func preloadInitialContent() {
        initialContentPreloadTask?.cancel()
        initialContentPreloadTask = Task { [weak self] in
            guard let self else { return }
            await self.preloadAuthenticatedPlatformContent()
            await MainActor.run { self.initialContentPreloadTask = nil }
        }
    }

    private func preloadAuthenticatedPlatformContent() async {
        let platforms = authenticatedPlatforms()
        guard !platforms.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            for platform in platforms {
                group.addTask { [weak self] in
                    await self?.loadHome(for: platform, reportErrors: false)
                }
                group.addTask { [weak self] in
                    await self?.loadLibrary(for: platform, reportErrors: false)
                }
            }
        }
    }

    private func authenticatedPlatforms() -> [String] {
        var platforms: [String] = []
        if isNeteaseAuthenticated { platforms.append("netease") }
        if isSpotifyAuthenticated { platforms.append("spotify") }
        if isYTMusicAuthenticated { platforms.append("ytmusic") }
        return platforms
    }

    // MARK: - Backend wiring

    private func wireBackendCallbacks() {
        // VLC → state machine
        vlc.onPositionChanged = { [weak self] ms in
            guard let self else { return }
            // Discard stale pre-seek positions that arrive while VLC is still
            // seeking (poll fires with old position for ~300–500 ms after seek).
            if let target = self.pendingSeekTarget, let seekTime = self.pendingSeekTime {
                if Date().timeIntervalSince(seekTime) > 0.8 {
                    self.pendingSeekTarget = nil
                    self.pendingSeekTime = nil
                } else if ms < target - 500 {
                    return
                }
            }
            self.playerMachine.updatePosition(ms)
            self.onPositionTick(ms)
        }
        vlc.onDurationChanged = { [weak self] ms in
            self?.playerMachine.updateDuration(ms)
        }
        vlc.onEndReached = { [weak self] in
            Task { await self?.playNext() }
        }
        vlc.onError = { [weak self] msg in
            self?.playerMachine.onLoadError(msg)
        }

        // librespot → state machine
        librespotBackend.onPlaybackStarted = { [weak self] in
            self?.playerMachine.onLoadSuccess()
        }
        librespotBackend.onPositionChanged = { [weak self] ms in
            self?.playerMachine.updatePosition(ms)
            self?.onPositionTick(ms)
        }
        librespotBackend.onEndReached = { [weak self] in
            Task { await self?.playNext() }
        }
        librespotBackend.onError = { [weak self] msg in
            guard let self else { return }
            self.lastPlaylistError = "[spotify] \(msg)"
            self.playerMachine.onPlaybackError(msg)
        }
    }

    private func onPositionTick(_ ms: Int) {
        let state = playerMachine.state
        macosMedia.updatePosition(ms, isPlaying: state.status == .playing)
        autoAdvanceIfNeeded(positionMs: ms, state: state)

        // Prefetch logic (mirrors Python _on_position_changed)
        guard state.status == .playing,
              let track = state.currentTrack,
              !prefetchDone,
              prefetchTask == nil else { return }

        let threshold = prefetchThresholds[track.platform] ?? prefetchFallbackMs
        let shouldPrefetch: Bool
        if state.durationMs > 0 {
            shouldPrefetch = (state.durationMs - ms) <= threshold
        } else {
            shouldPrefetch = ms >= prefetchFallbackMs
        }

        if shouldPrefetch {
            prefetchDone = true
            prefetchTask = Task { [weak self] in
                await self?.prefetchNext()
                await MainActor.run { self?.prefetchTask = nil }
            }
        }
    }

    private func autoAdvanceIfNeeded(positionMs ms: Int, state: PlayerState) {
        guard state.status == .playing,
              let track = state.currentTrack,
              state.durationMs > 0,
              playQueue.peekNext(repeatMode: state.repeatMode) != nil else { return }

        let remainingMs = state.durationMs - ms
        guard remainingMs <= 500 else { return }

        let key = "\(track.platform):\(track.id):\(playQueue.currentIndex)"
        guard autoAdvanceKey != key else { return }
        autoAdvanceKey = key

        Task { [weak self] in
            await self?.playNext()
        }
    }

    // MARK: - SwiftUI sheet-based login

    /// Open the NSWindow-based login for the given platform.
    /// Uses the proven native-window path (not SwiftUI sheet) for reliable keyboard input
    /// and cookie capture.
    public func requestLogin(for platform: String) {
        Task {
            switch platform {
            case "netease":
                guard let cookies = await neteaseAuth.login(),
                      cookies["MUSIC_U"] != nil else {
                    NSLog("[AppController] ✗ Netease login returned nil or missing MUSIC_U")
                    return
                }
                NSLog("[AppController] ✓ Netease login success, cookies: \(cookies.keys.sorted())")
                try? await repo.saveCredential("netease", data: cookies)
                neteaseClient = NeteaseClient(cookies: cookies)
                isNeteaseAuthenticated = true
                NSLog("[AppController]   neteaseClient set, loading home + library…")
                await loadHome(for: "netease")
                await loadLibrary(for: "netease")
            case "spotify":
                guard let cookies = await spotifyAuth.loginCookies(),
                      cookies["sp_dc"] != nil else { return }
                try? await repo.saveCredential("spotify", data: cookies)
                spotifyClient = SpotifyClient(auth: spotifyAuth)
                isSpotifyAuthenticated = true
                warmUpSpotifyPlayback()
                await loadHome(for: "spotify")
                await loadLibrary(for: "spotify")
            case "ytmusic":
                guard let headers = await ytmAuth.login() else { return }
                try? await repo.saveCredential("ytmusic", data: headers)
                ytmClient = YTMusicClient(headers: headers)
                isYTMusicAuthenticated = true
                await loadHome(for: "ytmusic")
                await loadLibrary(for: "ytmusic")
            default: break
            }
        }
    }

    /// Called by `LoginSheet.onComplete` — processes captured cookies.
    public func handleLoginResult(platform: String, cookies: [String: String]?) async {
        loginSheetConfig = nil
        guard let cookies, !cookies.isEmpty else { return }
        switch platform {
        case "netease":
            try? await repo.saveCredential("netease", data: cookies)
            neteaseClient = NeteaseClient(cookies: cookies)
            isNeteaseAuthenticated = true
        case "spotify":
            if let spDC = cookies["sp_dc"] {
                var cred: [String: String] = ["sp_dc": spDC]
                if let spKey = cookies["sp_key"] { cred["sp_key"] = spKey }
                try? await repo.saveCredential("spotify", data: cred)
                spotifyClient = SpotifyClient(auth: spotifyAuth)
                isSpotifyAuthenticated = true
                warmUpSpotifyPlayback()
            }
        case "ytmusic":
            let headers = YTMusicAuth.buildHeaders(from: cookies)
            try? await repo.saveCredential("ytmusic", data: headers)
            ytmClient = YTMusicClient(headers: headers)
            isYTMusicAuthenticated = true
        default: break
        }
        preloadInitialContent()
    }

    // MARK: - Authentication

    public func ensureNeteaseAuth() async -> Bool {
        if neteaseClient != nil { return true }
        guard let cookies = await neteaseAuth.login(),
              cookies["MUSIC_U"] != nil else { return false }
        try? await repo.saveCredential("netease", data: cookies)
        neteaseClient = NeteaseClient(cookies: cookies)
        isNeteaseAuthenticated = true
        return true
    }

    public func ensureYTMusicAuth() async -> Bool {
        if ytmClient != nil { return true }
        guard let headers = await ytmAuth.login() else { return false }
        try? await repo.saveCredential("ytmusic", data: headers)
        ytmClient = YTMusicClient(headers: headers)
        isYTMusicAuthenticated = true
        return true
    }

    public func ensureSpotifyAuth() async -> Bool {
        if spotifyClient != nil { return true }
        guard let cookies = await spotifyAuth.loginCookies(),
              cookies["sp_dc"] != nil else { return false }
        try? await repo.saveCredential("spotify", data: cookies)
        spotifyClient = SpotifyClient(auth: spotifyAuth)
        isSpotifyAuthenticated = true
        warmUpSpotifyPlayback()
        Task { try? await librespotBridge.createSessionWithToken(
            (try? await spotifyAuth.getAccessToken()) ?? ""
        ) }
        return true
    }

    public func logoutNetease() async {
        try? await neteaseAuth.logout()
        neteaseClient = nil
        isNeteaseAuthenticated = false
        evictCache(for: "netease")
    }

    public func logoutYTMusic() async {
        try? await ytmAuth.logout()
        ytmClient = nil
        isYTMusicAuthenticated = false
        evictCache(for: "ytmusic")
    }

    public func logoutSpotify() async {
        try? await spotifyAuth.logout()
        spotifyClient = nil
        isSpotifyAuthenticated = false
        evictCache(for: "spotify")
    }

    public func getAccountName(for platform: String) async -> String? {
        switch platform {
        case "netease": return await neteaseAuth.getDisplayName()
        case "ytmusic": return await ytmAuth.getDisplayName()
        case "spotify": return await spotifyAuth.getDisplayName()
        default: return nil
        }
    }

    // MARK: - Search

    public func search(query: String, platform: String) async -> [Track] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let tracks = await searchTracks(query: trimmed, platform: platform)
        searchResults = tracks
        return tracks
    }

    public func searchTracks(query: String, platform: String, limit: Int? = nil) async -> [Track] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        if platform == "netease" {
            NSLog("[AppController] search('\(trimmed)') neteaseClient=\(neteaseClient != nil), isAuth=\(isNeteaseAuthenticated)")
        }
        do {
            let tracks: [Track]
            switch platform {
            case "netease":
                guard let c = neteaseClient else {
                    NSLog("[AppController] ✗ neteaseClient is nil — not logged in")
                    return []
                }
                tracks = try await c.search(query: trimmed)
            case "ytmusic":
                guard let c = ytmClient else { return [] }
                tracks = try await c.search(query: trimmed)
            case "spotify":
                guard let c = spotifyClient else { return [] }
                tracks = try await c.search(query: trimmed)
            default: return []
            }
            if let limit {
                return Array(tracks.prefix(limit))
            }
            return tracks
        } catch {
            lastPlaylistError = apiErrorMessage(error, platform: platform)
            return []
        }
    }

    public func searchAlbums(query: String, platform: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { albumSearchResults[platform] = []; return }
        do {
            let albums: [Album]
            switch platform {
            case "netease":
                guard let c = neteaseClient else { albumSearchResults[platform] = []; return }
                albums = try await c.searchAlbums(query: trimmed)
            case "ytmusic":
                guard let c = ytmClient else { albumSearchResults[platform] = []; return }
                albums = try await c.searchAlbums(query: trimmed)
            case "spotify":
                guard let c = spotifyClient else { albumSearchResults[platform] = []; return }
                albums = try await c.searchAlbums(query: trimmed)
            default: albumSearchResults[platform] = []; return
            }
            albumSearchResults[platform] = albums
        } catch {
            albumSearchResults[platform] = []
        }
    }

    public func getAlbumTracks(_ album: Album) async -> [Track] {
        do {
            switch album.platform {
            case "netease":
                return try await neteaseClient?.getAlbumTracks(albumId: album.id) ?? []
            case "ytmusic":
                return try await ytmClient?.getAlbumTracks(albumId: album.id) ?? []
            case "spotify":
                return try await spotifyClient?.getAlbumTracks(albumId: album.id) ?? []
            default: return []
            }
        } catch { return [] }
    }

    // MARK: - Search history

    private static let historyMax = 15

    public func searchHistory(for platform: String) async -> [String] {
        guard let raw = try? await repo.getSetting("search_history_\(platform)"),
              let list = try? JSONDecoder().decode([String].self, from: Data(raw.utf8))
        else { return [] }
        return list
    }

    public func addSearchHistory(query: String, platform: String) async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        var history = await searchHistory(for: platform)
        history.removeAll { $0 == q }
        history.insert(q, at: 0)
        history = Array(history.prefix(Self.historyMax))
        if let data = try? JSONEncoder().encode(history),
           let str = String(data: data, encoding: .utf8) {
            try? await repo.setSetting("search_history_\(platform)", value: str)
        }
    }

    public func clearSearchHistory(for platform: String) async {
        try? await repo.setSetting("search_history_\(platform)", value: "[]")
    }

    // MARK: - Playback

    public func playTrack(_ track: Track) async {
        // Reset prefetch
        prefetchTask?.cancel(); prefetchTask = nil
        prefetchDone = false; prefetchedAutoplay = nil
        autoAdvanceKey = nil

        // Ensure track is in queue
        if playQueue.currentTrack?.id != track.id {
            playQueue.setTracks([track], startAt: 0)
        }

        playerMachine.load(track)
        currentLyrics = []

        do {
            if track.platform == "spotify" {
                vlc.stop()
                let token = try await spotifyAuth.getAccessToken()
                try await librespotBackend.play(trackId: track.id, accessToken: token, durationMs: track.durationMs)
                // onPlaybackStarted callback will call playerMachine.onLoadSuccess()
            } else {
                librespotBackend.stop()
                if track.platform == "netease", !VLCBackend.usesVLCKit {
                    throw AppControllerError.vlcKitRequired
                }
                let url: String
                url = try await resolveStreamURL(for: track)
                let ua: String?
                let headers: [String: String]
                switch track.platform {
                case "ytmusic":
                    ua = ytmWindowsChromeUA
                    headers = [:]
                case "netease":
                    ua = neteaseUserAgent
                    headers = [
                        "Referer": "https://music.163.com/",
                        "Origin": "https://music.163.com",
                        "Accept": "*/*",
                        "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
                    ]
                default:
                    ua = nil
                    headers = [:]
                }
                vlc.play(url: url, httpUA: ua, httpHeaders: headers)
                playerMachine.onLoadSuccess()
            }
        } catch {
            let msg = apiErrorMessage(error, platform: track.platform)
            NSLog("[AppController] playTrack error: \(msg)")
            playerMachine.onLoadError(msg)
            lastPlaylistError = msg
            return
        }

        // Async side effects
        Task { await fetchLyrics(track) }
        Task { await fetchCoverArt(track) }
        Task { [weak self] in await self?.prefetchQueuedNextIfAvailable() }
        macosMedia.updateNowPlaying(
            track: track,
            positionMs: 0,
            isPlaying: true
        )
    }

    private func resolveStreamURL(for track: Track) async throws -> String {
        if let cached = cachedStreamURL(for: track) {
            return cached
        }

        let key = streamCacheKey(for: track)
        if let task = streamURLTasks[key] {
            let url = try await task.value
            cacheStreamURL(url, for: track)
            return url
        }

        let task = Task { [weak self] in
            guard let self else { throw AppControllerError.noClient }
            return try await self.getStreamURL(track)
        }
        streamURLTasks[key] = task

        do {
            let url = try await task.value
            cacheStreamURL(url, for: track)
            streamURLTasks[key] = nil
            return url
        } catch {
            streamURLTasks[key] = nil
            throw error
        }
    }

    private func getStreamURL(_ track: Track) async throws -> String {
        switch track.platform {
        case "netease":
            guard let c = neteaseClient else { throw AppControllerError.noClient }
            return try await c.getStreamURL(track: track)
        case "ytmusic":
            guard let c = ytmClient else { throw AppControllerError.noClient }
            return try await c.getStreamURL(track: track)
        default:
            throw AppControllerError.noClient
        }
    }

    public func playNext() async {
        let repeatMode = playerMachine.state.repeatMode
        if let next = playQueue.next(repeatMode: repeatMode) {
            await playTrack(next)
            return
        }
        // Queue exhausted — use prefetched recommendations if available
        if let recs = prefetchedAutoplay, !recs.isEmpty {
            prefetchedAutoplay = nil
            vlc.stop(); librespotBackend.stop(); playerMachine.stop()
            playQueue.setTracks(recs, startAt: 0)
            await playTrack(recs[0])
            return
        }
        // Auto-play from recommendations
        if let seed = playerMachine.state.currentTrack {
            vlc.stop(); librespotBackend.stop(); playerMachine.stop()
            Task { await autoplay(seed: seed) }
        }
    }

    public func playPrev() async {
        if let prev = playQueue.previous() {
            await playTrack(prev)
        }
    }

    public func togglePlayPause() {
        let status = playerMachine.state.status
        let isSpotify = playerMachine.state.currentTrack?.platform == "spotify"
        switch status {
        case .playing:
            if isSpotify { librespotBackend.pause() } else { vlc.pause() }
            playerMachine.pause()
        case .paused:
            if isSpotify { librespotBackend.resume() } else { vlc.resume() }
            playerMachine.resume()
        default: break
        }
        macosMedia.updateNowPlaying(
            track: playerMachine.state.currentTrack,
            positionMs: playerMachine.state.positionMs,
            isPlaying: playerMachine.state.status == .playing
        )
    }

    public func seek(to ms: Int) {
        let isSpotify = playerMachine.state.currentTrack?.platform == "spotify"
        playerMachine.seek(to: ms)
        if !isSpotify {
            // Record seek target so the VLC poll callback can suppress stale
            // pre-seek position reports for the next ~800 ms.
            pendingSeekTarget = ms
            pendingSeekTime = Date()
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if isSpotify {
                self.librespotBackend.seek(to: ms)
            } else {
                self.vlc.seek(to: ms)
            }
        }
    }

    public func setVolume(_ volume: Int) {
        let v = max(0, min(volume, 100))
        applyVolumeToBackends(v)
        playerMachine.setVolume(v)
        Task { try? await repo.setSetting("volume", value: String(v)) }
    }

    private func applyVolumeToBackends(_ volume: Int) {
        let v = max(0, min(volume, 100))
        vlc.setVolume(v)
        librespotBackend.setVolume(v)
    }

    public func toggleShuffle() {
        let newVal = !playerMachine.state.shuffle
        playerMachine.setShuffle(newVal)
        if newVal { playQueue.shuffle() } else { playQueue.unshuffle() }
        Task { try? await repo.setSetting("shuffle", value: newVal ? "true" : "false") }
    }

    public func cycleRepeatMode() {
        let current = playerMachine.state.repeatMode
        let idx = repeatCycle.firstIndex(of: current) ?? 0
        let next = repeatCycle[(idx + 1) % repeatCycle.count]
        playerMachine.setRepeatMode(next)
        Task { try? await repo.setSetting("repeat_mode", value: next.rawValue) }
    }

    // MARK: - Queue

    public func addToQueue(_ track: Track) {
        playQueue.add(track)
    }

    public func playQueueTracks(_ tracks: [Track], startAt index: Int = 0) {
        guard !tracks.isEmpty else { return }
        playQueue.setTracks(tracks, startAt: index)
        Task { await playTrack(tracks[index]) }
    }

    public func jumpToQueueIndex(_ index: Int) async {
        guard playQueue.tracks.indices.contains(index) else { return }
        playQueue.setTracks(playQueue.tracks, startAt: index)
        await playTrack(playQueue.tracks[index])
    }

    public func removeFromQueue(at index: Int) {
        playQueue.remove(at: index)
    }

    // MARK: - Home & Library

    public func loadHome(for platform: String, reportErrors: Bool = true) async {
        if let cached = homeCache[platform] {
            homeSections[platform] = cached.1
            if Date().timeIntervalSince(cached.0) < homeCacheTTL { return }
        }
        do {
            let sections: [(String, [Track])]
            switch platform {
            case "netease":
                guard let c = neteaseClient else { return }
                sections = try await c.getHome()
            case "ytmusic":
                guard let c = ytmClient else { return }
                sections = try await c.getHome()
            case "spotify":
                guard let c = spotifyClient else { return }
                sections = try await c.getHome()
            default: return
            }
            homeCache[platform] = (Date(), sections)
            homeSections[platform] = sections
        } catch {
            if reportErrors {
                lastPlaylistError = apiErrorMessage(error, platform: platform)
            }
        }
    }

    public func prepareHome(for platform: String) async {
        if homeSections[platform] == nil {
            await loadHome(for: platform)
            return
        }

        await refreshHomeIfStale(for: platform)
    }

    public func hasHomeContent(for platform: String) -> Bool {
        homeSections[platform] != nil || homeCache[platform] != nil
    }

    private func refreshHomeIfStale(for platform: String) async {
        guard let cached = homeCache[platform],
              Date().timeIntervalSince(cached.0) >= homeCacheTTL else { return }

        do {
            let sections = try await fetchHomeSections(for: platform)
            homeCache[platform] = (Date(), sections)
            if !homeSectionsEqual(homeSections[platform] ?? cached.1, sections) {
                homeSections[platform] = sections
            }
        } catch {
            // Background refresh is intentionally quiet; the visible cached page remains usable.
        }
    }

    public func loadLibrary(for platform: String, reportErrors: Bool = true) async {
        if let cached = libraryCache[platform] {
            library[platform] = cached.1
            if Date().timeIntervalSince(cached.0) < libraryCacheTTL { return }
        }
        do {
            let playlists: [Playlist]
            switch platform {
            case "netease":
                guard let c = neteaseClient else { return }
                playlists = try await c.getLibraryPlaylists()
            case "ytmusic":
                guard let c = ytmClient else { return }
                playlists = try await c.getLibraryPlaylists()
            case "spotify":
                guard let c = spotifyClient else { return }
                playlists = try await c.getLibraryPlaylists()
            default: return
            }
            libraryCache[platform] = (Date(), playlists)
            library[platform] = playlists
        } catch {
            if reportErrors {
                lastPlaylistError = apiErrorMessage(error, platform: platform)
            }
        }
    }

    public func prepareLibrary(for platform: String) async {
        if library[platform] == nil {
            await loadLibrary(for: platform)
            return
        }

        await refreshLibraryIfStale(for: platform)
    }

    public func hasLibraryContent(for platform: String) -> Bool {
        library[platform] != nil || libraryCache[platform] != nil
    }

    private func refreshLibraryIfStale(for platform: String) async {
        guard let cached = libraryCache[platform],
              Date().timeIntervalSince(cached.0) >= libraryCacheTTL else { return }

        do {
            let playlists = try await fetchLibraryPlaylists(for: platform)
            libraryCache[platform] = (Date(), playlists)
            if (library[platform] ?? cached.1) != playlists {
                library[platform] = playlists
            }
        } catch {
            // Keep the cached library visible when a background refresh fails.
        }
    }

    public func getPlaylistTracks(_ playlist: Playlist, forceReload: Bool = false) async -> [Track] {
        let key = "\(playlist.platform):\(playlist.id)"
        if !forceReload,
           let cached = tracksCache[key],
           Date().timeIntervalSince(cached.0) < tracksCacheTTL {
            return cached.1
        }
        do {
            let tracks: [Track]
            switch playlist.platform {
            case "netease":
                guard let c = neteaseClient else { return [] }
                tracks = try await c.getPlaylistTracks(playlistId: playlist.id)
            case "ytmusic":
                guard let c = ytmClient else { return [] }
                tracks = try await c.getPlaylistTracks(playlistId: playlist.id)
            case "spotify":
                guard let c = spotifyClient else { return [] }
                tracks = try await c.getPlaylistTracks(playlistId: playlist.id)
            default: return []
            }
            tracksCache[key] = (Date(), tracks)
            if tracksCache.count > tracksCacheMax {
                let oldest = tracksCache.min { $0.value.0 < $1.value.0 }?.key
                if let k = oldest { tracksCache.removeValue(forKey: k) }
            }
            return tracks
        } catch { return [] }
    }

    private func fetchHomeSections(for platform: String) async throws -> [(String, [Track])] {
        switch platform {
        case "netease":
            guard let c = neteaseClient else { throw AppControllerError.noClient }
            return try await c.getHome()
        case "ytmusic":
            guard let c = ytmClient else { throw AppControllerError.noClient }
            return try await c.getHome()
        case "spotify":
            guard let c = spotifyClient else { throw AppControllerError.noClient }
            return try await c.getHome()
        default:
            throw AppControllerError.noClient
        }
    }

    private func fetchLibraryPlaylists(for platform: String) async throws -> [Playlist] {
        switch platform {
        case "netease":
            guard let c = neteaseClient else { throw AppControllerError.noClient }
            return try await c.getLibraryPlaylists()
        case "ytmusic":
            guard let c = ytmClient else { throw AppControllerError.noClient }
            return try await c.getLibraryPlaylists()
        case "spotify":
            guard let c = spotifyClient else { throw AppControllerError.noClient }
            return try await c.getLibraryPlaylists()
        default:
            throw AppControllerError.noClient
        }
    }

    private func homeSectionsEqual(_ lhs: [(String, [Track])], _ rhs: [(String, [Track])]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (left, right) in zip(lhs, rhs) {
            if left.0 != right.0 || left.1 != right.1 { return false }
        }
        return true
    }

    public func getAddablePlaylists(for platform: String) async -> [Playlist] {
        do {
            switch platform {
            case "netease":
                return try await neteaseClient?.getAddablePlaylists() ?? []
            case "ytmusic":
                return try await ytmClient?.getAddablePlaylists() ?? []
            case "spotify":
                return try await spotifyClient?.getAddablePlaylists() ?? []
            default: return []
            }
        } catch { return [] }
    }

    public func addTrackToPlaylist(_ track: Track, to playlist: Playlist) async -> Bool {
        lastPlaylistError = ""
        guard track.platform == playlist.platform else {
            lastPlaylistError = "歌曲和歌单不属于同一平台"
            return false
        }
        do {
            let ok: Bool
            switch track.platform {
            case "netease":
                guard let c = neteaseClient else { lastPlaylistError = "需要先登录"; return false }
                ok = try await c.addTrackToPlaylist(playlistId: playlist.id, track: track)
            case "ytmusic":
                guard let c = ytmClient else { lastPlaylistError = "需要先登录"; return false }
                ok = try await c.addTrackToPlaylist(playlistId: playlist.id, track: track)
            case "spotify":
                guard let c = spotifyClient else { lastPlaylistError = "需要先登录"; return false }
                ok = try await c.addTrackToPlaylist(playlistId: playlist.id, track: track)
            default: return false
            }
            if ok {
                libraryCache.removeValue(forKey: track.platform)
                tracksCache.removeValue(forKey: "\(track.platform):\(playlist.id)")
                showCenterToast("已加入 \(playlist.name)")
            } else {
                lastPlaylistError = "加入歌单失败"
            }
            return ok
        } catch { lastPlaylistError = "加入歌单失败"; return false }
    }

    public func removeTrackFromPlaylist(_ track: Track, from playlist: Playlist) async -> Bool {
        guard track.platform == playlist.platform else { return false }
        do {
            let ok: Bool
            switch track.platform {
            case "netease":
                guard let c = neteaseClient else { return false }
                ok = try await c.removeTrackFromPlaylist(playlistId: playlist.id, track: track)
            case "ytmusic":
                guard let c = ytmClient else { return false }
                ok = try await c.removeTrackFromPlaylist(playlistId: playlist.id, track: track)
            case "spotify":
                guard let c = spotifyClient else { return false }
                ok = try await c.removeTrackFromPlaylist(playlistId: playlist.id, track: track)
            default: return false
            }
            if ok { tracksCache.removeValue(forKey: "\(track.platform):\(playlist.id)") }
            return ok
        } catch { return false }
    }

    public func openArtist(name: String, platform: String) {
        if currentPage != .artist {
            pageBeforeArtist = currentPage
        }
        currentPage = .artist
        Task { await loadArtist(name: name, platform: platform) }
    }

    public func openLyricsPage() {
        if currentPage != .lyrics {
            pageBeforeLyrics = currentPage
        }
        currentPage = .lyrics
    }

    public func returnFromArtistPage() {
        currentPage = pageBeforeArtist
    }

    public func returnFromLyricsPage() {
        currentPage = pageBeforeLyrics
    }

    private func showCenterToast(_ message: String) {
        centerToastTask?.cancel()
        centerToast = AppToast(message: message)
        centerToastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.centerToast = nil }
        }
    }

    // MARK: - Artist

    public func loadArtist(name: String, platform: String) async {
        artistInfo = nil; artistTracks = []
        do {
            let artist: Artist?
            switch platform {
            case "netease":
                artist = try await neteaseClient?.searchArtist(name: name)
            case "ytmusic":
                artist = try await ytmClient?.searchArtist(name: name)
            case "spotify":
                artist = try await spotifyClient?.searchArtist(name: name)
            default: return
            }
            guard let artist else { return }
            artistInfo = artist
            let tracks: [Track]
            switch platform {
            case "netease":
                tracks = try await neteaseClient?.getArtistTopTracks(artistId: artist.id) ?? []
            case "ytmusic":
                tracks = try await ytmClient?.getArtistTopTracks(artistId: artist.id) ?? []
            case "spotify":
                tracks = try await spotifyClient?.getArtistTopTracks(artistId: artist.id) ?? []
            default: tracks = []
            }
            artistTracks = tracks
        } catch {}
    }

    // MARK: - Autoplay / Prefetch

    public func autoplay(seed: Track) async {
        do {
            let recs: [Track]
            switch seed.platform {
            case "netease":
                recs = try await neteaseClient?.getRecommendations(track: seed) ?? []
            case "ytmusic":
                recs = try await ytmClient?.getRecommendations(track: seed) ?? []
            case "spotify":
                recs = try await spotifyClient?.getRecommendations(track: seed) ?? []
            default: recs = []
            }
            let filtered = recs.filter { $0.id != seed.id }
            guard !filtered.isEmpty else { return }
            playQueue.setTracks(filtered, startAt: 0)
            await playTrack(filtered[0])
        } catch {}
    }

    private func prefetchNext() async {
        let state = playerMachine.state
        guard let current = state.currentTrack else { return }

        if let next = playQueue.peekNext(repeatMode: state.repeatMode) {
            await prefetchStreamURLIfNeeded(for: next)
        } else {
            // No queue next — pre-load autoplay recommendations
            do {
                let recs: [Track]
                switch current.platform {
                case "netease":
                    recs = try await neteaseClient?.getRecommendations(track: current) ?? []
                case "ytmusic":
                    recs = try await ytmClient?.getRecommendations(track: current) ?? []
                case "spotify":
                    recs = try await spotifyClient?.getRecommendations(track: current) ?? []
                default: recs = []
                }
                let filtered = recs.filter { $0.id != current.id }
                prefetchedAutoplay = filtered
                if let first = filtered.first {
                    await prefetchStreamURLIfNeeded(for: first)
                }
            } catch {}
        }
    }

    private func prefetchQueuedNextIfAvailable() async {
        let state = playerMachine.state
        guard let current = state.currentTrack,
              let next = playQueue.peekNext(repeatMode: state.repeatMode),
              next.platform != "spotify",
              !(next.platform == current.platform && next.id == current.id) else { return }
        await prefetchStreamURLIfNeeded(for: next)
    }

    private func prefetchStreamURLIfNeeded(for track: Track) async {
        guard track.platform != "spotify",
              cachedStreamURL(for: track) == nil else { return }
        do {
            _ = try await resolveStreamURL(for: track)
        } catch {
            NSLog("[AppController] stream prefetch failed for \(track.platform):\(track.id): \(error.localizedDescription)")
        }
    }

    // MARK: - Lyrics & Cover

    private func fetchLyrics(_ track: Track) async {
        do {
            let lines: [LyricLine]
            switch track.platform {
            case "netease":
                guard let c = neteaseClient else { currentLyrics = []; return }
                lines = try await c.getLyrics(track: track)
            case "ytmusic":
                guard let c = ytmClient else { currentLyrics = []; return }
                lines = try await c.getLyrics(track: track)
            case "spotify":
                guard let c = spotifyClient else { currentLyrics = []; return }
                lines = try await c.getLyrics(track: track)
            default: currentLyrics = []; return
            }
            currentLyrics = lines
        } catch { currentLyrics = [] }
    }

    private func fetchCoverArt(_ track: Track) async {
        guard !track.albumCoverURL.isEmpty,
              let url = URL(string: track.albumCoverURL) else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
        currentCoverData = data
        macosMedia.setCoverArt(data: data)
        if let color = await DominantColor.extract(from: data) {
            currentCoverColor = color
        }
    }

    // MARK: - Settings

    public func loadSettings() async -> [String: String] {
        let keys = ["volume", "repeat_mode", "shuffle", "display_name",
                    "background_image_path", "background_pure_black",
                    "auto_standby_minutes", "auto_update"]
        var result: [String: String] = [:]
        for key in keys {
            result[key] = (try? await repo.getSetting(key)) ?? ""
        }
        return result
    }

    public func saveSetting(key: String, value: String) async {
        let v: String
        switch key {
        case "display_name":
            v = value.trimmingCharacters(in: .whitespaces).isEmpty ? "Omnia" : value.trimmingCharacters(in: .whitespaces)
            displayName = v
        case "background_image_path":
            v = value
            backgroundImagePath = v
        case "background_pure_black":
            let on = value.lowercased() == "true"
            backgroundImagePath = on ? "" : ((try? await repo.getSetting("background_image_path")) ?? "")
            v = on ? "true" : "false"
        default:
            v = value
        }
        try? await repo.setSetting(key, value: v)
    }

    // MARK: - Update check

    public func checkForUpdate() async {
        await releaseUpdater.checkForUpdates()
    }

    public func applyUpdate() async {
        releaseUpdater.openLatestReleasePage()
    }

    // MARK: - Cleanup

    public func close() {
        prefetchTask?.cancel()
        streamURLTasks.values.forEach { $0.cancel() }
        streamURLTasks.removeAll()
        vlc.stop()
        librespotBackend.stopDaemon()
        Task { await librespotBridge.close() }
        macosMedia.close()
    }

    // MARK: - Private helpers

    private func evictCache(for platform: String) {
        homeCache.removeValue(forKey: platform)
        libraryCache.removeValue(forKey: platform)
        let prefix = "\(platform):"
        tracksCache = tracksCache.filter { !$0.key.hasPrefix(prefix) }
        streamURLCache = streamURLCache.filter { !$0.key.hasPrefix(prefix) }
        homeSections.removeValue(forKey: platform)
        library.removeValue(forKey: platform)
    }

    private func warmUpSpotifyPlayback() {
        librespotBackend.warmUpRuntime()
        Task { [weak self] in
            guard let self else { return }
            guard let token = try? await self.spotifyAuth.getAccessToken() else { return }
            let vol = self.playerMachine.state.volume
            await self.librespotBackend.startDaemon(accessToken: token, volume: vol)
        }
    }

    private func streamCacheKey(for track: Track) -> String {
        "\(track.platform):\(track.id)"
    }

    private func cachedStreamURL(for track: Track) -> String? {
        if let url = track.streamURL, !url.isEmpty {
            cacheStreamURL(url, for: track)
            return url
        }

        let key = streamCacheKey(for: track)
        guard let cached = streamURLCache[key] else { return nil }
        if Date().timeIntervalSince(cached.0) < streamURLCacheTTL {
            return cached.1
        }
        streamURLCache.removeValue(forKey: key)
        return nil
    }

    private func cacheStreamURL(_ url: String, for track: Track) {
        guard !url.isEmpty else { return }
        streamURLCache[streamCacheKey(for: track)] = (Date(), url)
        if streamURLCache.count > streamURLCacheMax {
            let oldest = streamURLCache.min { $0.value.0 < $1.value.0 }?.key
            if let oldest { streamURLCache.removeValue(forKey: oldest) }
        }
    }

    /// Build a human-readable error string shown in the UI toast.
    private func apiErrorMessage(_ error: Error, platform: String) -> String {
        switch error {
        case AppControllerError.vlcKitRequired:
            return "[\(platform)] 网易云播放需要 VLCKit。请集成 Vendor/VLCKit/VLCKit.xcframework 后重新构建。"
        case NeteaseClientError.apiError(let code, let msg):
            return "[\(platform)] API错误 \(code): \(msg)"
        case NeteaseClientError.httpError(let code):
            return "[\(platform)] HTTP \(code)"
        case YTMusicClientError.httpError(let code):
            return "[\(platform)] HTTP \(code)"
        default:
            return "[\(platform)] \(error.localizedDescription)"
        }
    }
}

// MARK: - Error

public enum AppControllerError: Error {
    case noClient
    case noStreamURL
    case vlcKitRequired
}
