import SwiftUI

// MARK: - LibraryPageView

public struct LibraryPageView: View {
    @ObservedObject var ctrl: AppController

    // MARK: State

    @State private var selectedPlaylist: Playlist? = nil
    @State private var playlistTracks: [Track] = []
    @State private var isLoadingLibrary: Bool = false
    @State private var isLoadingTracks: Bool = false
    @State private var showPlaylistPicker: Bool = false
    @State private var trackForPlaylist: Track? = nil
    @State private var toastMessage: String = ""
    @State private var toastVisible: Bool = false

    public init(ctrl: AppController) {
        self.ctrl = ctrl
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            // ── Platform header ────────────────────────────────────────────
            platformHeader

            Divider().background(Theme.divider)

            // ── Main content split ─────────────────────────────────────────
            HStack(spacing: 0) {
                playlistColumn
                    .frame(width: 220)

                Divider().background(Theme.divider)

                trackColumn
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.surfaceBackground(hasBackgroundImage: !ctrl.backgroundImagePath.isEmpty))
        .overlay(alignment: .top) {
            if toastVisible { toastView.padding(.top, 12) }
        }
        .onChange(of: ctrl.libraryPlatform) { _ in
            selectedPlaylist = nil
            playlistTracks = []
        }
        .onChange(of: ctrl.lastPlaylistError) { err in
            guard !err.isEmpty else { return }
            showToast(err)
        }
        .onChange(of: ctrl.isNeteaseAuthenticated) { auth in
            if auth && ctrl.libraryPlatform == "netease" { Task { await prepareLibrary() } }
        }
        .onChange(of: ctrl.isSpotifyAuthenticated) { auth in
            if auth && ctrl.libraryPlatform == "spotify" { Task { await prepareLibrary() } }
        }
        .onChange(of: ctrl.isYTMusicAuthenticated) { auth in
            if auth && ctrl.libraryPlatform == "ytmusic" { Task { await prepareLibrary() } }
        }
        .task(id: ctrl.libraryPlatform) { await prepareLibrary() }
    }

    // MARK: - Platform Header

    private var platformHeader: some View {
        HStack(spacing: 10) {
            PlatformIconView(platform: ctrl.libraryPlatform)
                .frame(width: 16, height: 16)
            Text(platformLabel(ctrl.libraryPlatform))
                .font(Theme.font(Theme.fontMD, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            Text("歌单库")
                .font(Theme.font(Theme.fontMD))
                .foregroundStyle(Theme.secondaryText)
            Spacer()
            if isLoadingLibrary {
                ProgressView().scaleEffect(0.7)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.panelBackground(hasBackgroundImage: !ctrl.backgroundImagePath.isEmpty))
    }

    private func platformLabel(_ platform: String) -> String {
        switch platform {
        case "netease": return "网易云音乐"
        case "spotify": return "Spotify"
        case "ytmusic": return "YouTube Music"
        default: return platform
        }
    }

    // MARK: - Playlist Column

    private var playlistColumn: some View {
        VStack(spacing: 0) {
            HStack {
                Text("歌单")
                    .font(Theme.font(Theme.fontSM, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider().background(Theme.divider)

            if !isAuthenticated(for: ctrl.libraryPlatform) {
                notAuthenticatedView
            } else if isLoadingLibrary && (ctrl.library[ctrl.libraryPlatform] ?? []).isEmpty {
                loadingView
            } else {
                playlistListContent
            }
        }
        .background(Theme.panelBackground(hasBackgroundImage: !ctrl.backgroundImagePath.isEmpty))
    }

    @ViewBuilder
    private var playlistListContent: some View {
        let playlists = ctrl.library[ctrl.libraryPlatform] ?? []
        if playlists.isEmpty && !isLoadingLibrary {
            VStack(spacing: 8) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.mutedText)
                Text("暂无歌单")
                    .font(Theme.font(Theme.fontSM))
                    .foregroundStyle(Theme.mutedText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(playlists) { playlist in
                        playlistRow(playlist)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func playlistRow(_ playlist: Playlist) -> some View {
        let isSelected = selectedPlaylist?.id == playlist.id
        HStack(spacing: 10) {
            playlistCover(url: playlist.coverURL)

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(Theme.font(Theme.fontSM, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.primaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("\(playlist.trackCount) 首")
                    .font(Theme.font(Theme.fontXS))
                    .foregroundStyle(Theme.mutedText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusSM)
                .fill(isSelected ? Theme.accent.opacity(0.12) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusSM)
                .strokeBorder(isSelected ? Theme.accent.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if selectedPlaylist?.id != playlist.id {
                selectedPlaylist = playlist
                Task { await loadTracks(for: playlist) }
            }
        }
    }

    @ViewBuilder
    private func playlistCover(url: String) -> some View {
        if let imageURL = URL(string: url), !url.isEmpty {
            AsyncImage(url: imageURL) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM))
                default:
                    playlistCoverPlaceholder
                }
            }
        } else {
            playlistCoverPlaceholder
        }
    }

    private var playlistCoverPlaceholder: some View {
        RoundedRectangle(cornerRadius: Theme.radiusSM)
            .fill(Theme.bgElevated)
            .frame(width: 40, height: 40)
            .overlay {
                Image(systemName: "music.note.list")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.mutedText)
            }
    }

    private var notAuthenticatedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 32))
                .foregroundStyle(Theme.mutedText)
            Text("未登录")
                .font(Theme.font(Theme.fontSM))
                .foregroundStyle(Theme.mutedText)
            Button {
                ctrl.requestLogin(for: ctrl.libraryPlatform)
            } label: {
                Text("登录")
                    .font(Theme.font(Theme.fontSM, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radiusSM)
                            .fill(Theme.platformColor(for: ctrl.libraryPlatform))
                    )
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingView: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("加载中…")
                .font(Theme.font(Theme.fontSM))
                .foregroundStyle(Theme.mutedText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Track Column

    @ViewBuilder
    private var trackColumn: some View {
        if let playlist = selectedPlaylist {
            VStack(spacing: 0) {
                trackColumnHeader(playlist: playlist)

                Divider().background(Theme.divider)

                if isLoadingTracks {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("加载歌曲…")
                            .font(Theme.font(Theme.fontSM))
                            .foregroundStyle(Theme.mutedText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    LibraryTrackListView(
                        tracks: playlistTracks,
                        playlist: playlist,
                        currentTrackID: ctrl.playerState.currentTrack?.id,
                        onPlay: { track in
                            if let idx = playlistTracks.firstIndex(of: track) {
                                ctrl.playQueueTracks(playlistTracks, startAt: idx)
                            }
                        },
                        onAddToQueue: { track in
                            ctrl.addToQueue(track)
                        },
                        onArtistClicked: { track in
                            ctrl.pageBeforeArtist = ctrl.currentPage
                            Task {
                                await ctrl.loadArtist(name: track.artist, platform: track.platform)
                                ctrl.currentPage = .artist
                            }
                        },
                        onAddToPlaylist: { track in
                            trackForPlaylist = track
                            showPlaylistPicker = true
                        },
                        onRemoveFromPlaylist: { track in
                            Task {
                                let ok = await ctrl.removeTrackFromPlaylist(track, from: playlist)
                                if ok {
                                    await loadTracks(for: playlist, forceReload: true)
                                }
                            }
                        }
                    )
                    .popover(isPresented: $showPlaylistPicker) {
                        if let track = trackForPlaylist {
                            PlaylistPickerView(
                                platform: track.platform,
                                isPresented: $showPlaylistPicker,
                                ctrl: ctrl,
                                onSelected: { targetPlaylist in
                                    Task {
                                        let ok = await ctrl.addTrackToPlaylist(track, to: targetPlaylist)
                                        if ok { showToast("已加入 \(targetPlaylist.name)") }
                                    }
                                }
                            )
                        }
                    }
                }
            }
            .background(Theme.surfaceBackground(hasBackgroundImage: !ctrl.backgroundImagePath.isEmpty))
        } else {
            VStack(spacing: 12) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.mutedText)
                Text("选择一个歌单")
                    .font(Theme.font(Theme.fontMD))
                    .foregroundStyle(Theme.mutedText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.surfaceBackground(hasBackgroundImage: !ctrl.backgroundImagePath.isEmpty))
        }
    }

    @ViewBuilder
    private func trackColumnHeader(playlist: Playlist) -> some View {
        HStack(spacing: 12) {
            playlistCover(url: playlist.coverURL)
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name)
                    .font(Theme.font(Theme.fontMD, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Text("\(playlistTracks.isEmpty ? playlist.trackCount : playlistTracks.count) 首歌曲")
                    .font(Theme.font(Theme.fontSM))
                    .foregroundStyle(Theme.mutedText)
            }

            Spacer()

            if !playlistTracks.isEmpty {
                Button {
                    ctrl.playQueueTracks(playlistTracks, startAt: 0)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11))
                        Text("播放全部")
                            .font(Theme.font(Theme.fontSM, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radiusSM)
                            .fill(Theme.accent)
                    )
                }
                .buttonStyle(.plain)
            }

            Button {
                Task {
                    if let playlist = selectedPlaylist {
                        await loadTracks(for: playlist, forceReload: true)
                    }
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
            }
            .buttonStyle(.plain)
            .help("刷新歌曲列表")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    private func isAuthenticated(for platform: String) -> Bool {
        switch platform {
        case "netease": return ctrl.isNeteaseAuthenticated
        case "spotify": return ctrl.isSpotifyAuthenticated
        case "ytmusic": return ctrl.isYTMusicAuthenticated
        default: return false
        }
    }

    private func prepareLibrary() async {
        let platform = ctrl.libraryPlatform
        if ctrl.hasLibraryContent(for: platform) {
            isLoadingLibrary = false
            await ctrl.prepareLibrary(for: platform)
        } else {
            isLoadingLibrary = true
            await ctrl.prepareLibrary(for: platform)
            isLoadingLibrary = false
        }
    }

    private func loadTracks(for playlist: Playlist, forceReload: Bool = false) async {
        isLoadingTracks = true
        let tracks = await ctrl.getPlaylistTracks(playlist, forceReload: forceReload)
        playlistTracks = tracks
        isLoadingTracks = false
    }

    // MARK: - Toast

    private var toastView: some View {
        Text(toastMessage)
            .font(Theme.font(Theme.fontSM))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.8))
            .clipShape(Capsule())
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func showToast(_ message: String) {
        toastMessage = message
        withAnimation { toastVisible = true }
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation { toastVisible = false }
        }
    }
}

// MARK: - LibraryTrackListView

private struct LibraryTrackListView: View {
    let tracks: [Track]
    let playlist: Playlist
    let currentTrackID: String?
    let onPlay:               (Track) -> Void
    let onAddToQueue:         (Track) -> Void
    let onArtistClicked:      (Track) -> Void
    let onAddToPlaylist:      (Track) -> Void
    let onRemoveFromPlaylist: (Track) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, track in
                    TrackRowView(
                        track: track,
                        index: idx + 1,
                        isCurrentTrack: track.id == currentTrackID,
                        onPlay:          { onPlay(track) },
                        onAddToQueue:    { onAddToQueue(track) },
                        onArtistClicked: { onArtistClicked(track) },
                        onAddToPlaylist: { onAddToPlaylist(track) }
                    )
                    .contextMenu {
                        Button("播放") { onPlay(track) }
                        Button("加入队列") { onAddToQueue(track) }
                        Divider()
                        Button("加入歌单…") { onAddToPlaylist(track) }
                        Button("查看艺术家") { onArtistClicked(track) }
                        Divider()
                        Button("从歌单移除") { onRemoveFromPlaylist(track) }
                    }
                    if idx < tracks.count - 1 {
                        Divider()
                            .background(Theme.divider)
                            .padding(.leading, 52)
                    }
                }
            }
        }
    }
}
