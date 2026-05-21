import SwiftUI

// MARK: - SearchPageView

public struct SearchPageView: View {
    @ObservedObject var ctrl: AppController

    // MARK: State

    @State private var query:            String    = ""
    @State private var selectedPlatform: String    = "netease"
    @State private var history:          [String]  = []
    @State private var isSearching:      Bool      = false
    @State private var debounceTask:     Task<Void, Never>? = nil

    /// When non-nil the album detail sheet is shown.
    @State private var selectedAlbum:    Album?    = nil
    /// Tracks loaded for the currently selected album.
    @State private var albumTracks:      [Track]?  = nil
    @State private var isLoadingAlbum:   Bool      = false

    public init(ctrl: AppController) { self.ctrl = ctrl }

    // MARK: - Derived

    private var platforms: [(id: String, label: String)] {
        [("netease", "网易云"), ("spotify", "Spotify"), ("ytmusic", "YouTube")]
    }

    private var currentAlbums: [Album] {
        ctrl.albumSearchResults[selectedPlatform] ?? []
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            // ── Platform tabs ──────────────────────────────────────────────
            platformTabBar
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            // ── Search field ───────────────────────────────────────────────
            searchField
                .padding(.horizontal, 20)
                .padding(.bottom, 14)

            Divider()
                .background(Theme.divider)

            // ── Main content ───────────────────────────────────────────────
            ZStack {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    historyView
                } else if isSearching {
                    loadingView
                } else {
                    resultsView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.surfaceBackground(hasBackgroundImage: !ctrl.backgroundImagePath.isEmpty))
        .task { await loadHistory() }
        .onChange(of: selectedPlatform) { _ in
            Task {
                await loadHistory()
                triggerDebounce()
            }
        }
        // Album detail sheet
        .sheet(item: $selectedAlbum) { album in
            AlbumDetailSheet(
                album: album,
                tracks: albumTracks,
                isLoading: isLoadingAlbum,
                currentTrackID: ctrl.playerState.currentTrack?.id,
                onPlayAll: {
                    if let tracks = albumTracks, !tracks.isEmpty {
                        ctrl.playQueueTracks(tracks, startAt: 0)
                        Task { await ctrl.addSearchHistory(query: query, platform: selectedPlatform) }
                    }
                },
                onPlay: { track in
                    if let tracks = albumTracks {
                        let idx = tracks.firstIndex(of: track) ?? 0
                        ctrl.playQueueTracks(tracks, startAt: idx)
                        Task { await ctrl.addSearchHistory(query: query, platform: selectedPlatform) }
                    }
                },
                onAddToQueue: { track in
                    ctrl.addToQueue(track)
                },
                onArtistClicked: { track in
                    navigateToArtist(track)
                },
                onAddToPlaylist: { _ in }
            )
        }
    }

    // MARK: - Platform tab bar

    private var platformTabBar: some View {
        HStack(spacing: 8) {
            ForEach(platforms, id: \.id) { platform in
                PlatformTab(
                    label: platform.label,
                    platformID: platform.id,
                    isSelected: selectedPlatform == platform.id
                ) {
                    selectedPlatform = platform.id
                }
            }
            Spacer()
        }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.secondaryText)
                .font(.system(size: 15, weight: .regular))

            TextField("搜索歌曲、艺术家…", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.font(Theme.fontMD))
                .foregroundStyle(Theme.primaryText)
                .onChange(of: query) { _ in triggerDebounce() }

            if isSearching {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 16, height: 16)
            } else if !query.isEmpty {
                Button {
                    query = ""
                    debounceTask?.cancel()
                    debounceTask = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.mutedText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.bgElevated)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMD))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusMD)
                .stroke(Theme.border, lineWidth: 1)
        )
    }

    // MARK: - History view

    private var historyView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if history.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 40))
                            .foregroundStyle(Theme.mutedText)
                        Text("搜索歌曲、专辑或艺术家")
                            .font(Theme.font(Theme.fontMD))
                            .foregroundStyle(Theme.mutedText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    HStack {
                        Text("搜索历史")
                            .font(Theme.font(Theme.fontSM, weight: .semibold))
                            .foregroundStyle(Theme.secondaryText)
                        Spacer()
                        Button("清除历史") {
                            Task {
                                await ctrl.clearSearchHistory(for: selectedPlatform)
                                history = []
                            }
                        }
                        .buttonStyle(.plain)
                        .font(Theme.font(Theme.fontSM))
                        .foregroundStyle(Theme.accentDim)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)

                    HistoryChipsView(items: history) { item in
                        query = item
                        triggerDebounce(delay: 0)
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    // MARK: - Loading view

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .scaleEffect(1.2)
            Text("搜索中…")
                .font(Theme.font(Theme.fontSM))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    // MARK: - Results view

    private var resultsView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Albums section
                if !currentAlbums.isEmpty {
                    SectionHeader(title: "专辑")
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 6)

                    AlbumResultListView(albums: currentAlbums) { album in
                        openAlbum(album)
                    }
                    .padding(.bottom, ctrl.searchResults.isEmpty ? 16 : 10)
                }

                // Tracks section
                if !ctrl.searchResults.isEmpty {
                    SectionHeader(title: "歌曲")
                        .padding(.horizontal, 20)
                        .padding(.top, currentAlbums.isEmpty ? 16 : 8)
                        .padding(.bottom, 6)

                    TrackListView(
                        tracks: ctrl.searchResults,
                        currentTrackID: ctrl.playerState.currentTrack?.id,
                        onPlay: { track in
                            let idx = ctrl.searchResults.firstIndex(of: track) ?? 0
                            ctrl.playQueueTracks(ctrl.searchResults, startAt: idx)
                            Task { await ctrl.addSearchHistory(query: query, platform: selectedPlatform) }
                        },
                        onAddToQueue: { track in
                            ctrl.addToQueue(track)
                        },
                        onArtistClicked: { track in
                            navigateToArtist(track)
                        },
                        onAddToPlaylist: { _ in }
                    )
                    // TrackListView has its own ScrollView internally, so we cap height
                    // by disabling the inner scroll and letting the outer one manage.
                    .frame(height: CGFloat(min(ctrl.searchResults.count, 10)) * 58)
                    .disabled(false)
                }

                // Empty state
                if ctrl.searchResults.isEmpty && currentAlbums.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 40))
                            .foregroundStyle(Theme.mutedText)
                        Text("未找到结果")
                            .font(Theme.font(Theme.fontMD))
                            .foregroundStyle(Theme.mutedText)
                        Text("请尝试其他关键词")
                            .font(Theme.font(Theme.fontSM))
                            .foregroundStyle(Theme.mutedText.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                }
            }
        }
    }

    // MARK: - Actions

    private func triggerDebounce(delay: UInt64 = 400) {
        debounceTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            isSearching = false
            return
        }
        let platform = selectedPlatform
        debounceTask = Task {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay * 1_000_000)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { isSearching = true }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { _ = await ctrl.search(query: trimmed, platform: platform) }
                group.addTask { await ctrl.searchAlbums(query: trimmed, platform: platform) }
            }
            await MainActor.run { isSearching = false }
        }
    }

    private func loadHistory() async {
        history = await ctrl.searchHistory(for: selectedPlatform)
    }

    private func navigateToArtist(_ track: Track) {
        ctrl.openArtist(name: track.artist, platform: track.platform)
    }

    private func openAlbum(_ album: Album) {
        selectedAlbum = album
        albumTracks = nil
        isLoadingAlbum = true
        Task {
            let tracks = await ctrl.getAlbumTracks(album)
            await MainActor.run {
                albumTracks = tracks
                isLoadingAlbum = false
            }
        }
    }
}

// MARK: - PlatformTab

private struct PlatformTab: View {
    let label:      String
    let platformID: String
    let isSelected: Bool
    let action:     () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Theme.font(Theme.fontSM, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Theme.platformColor(for: platformID) : Theme.secondaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    isSelected
                        ? Theme.platformColor(for: platformID).opacity(0.12)
                        : Color.clear
                )
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(
                            isSelected
                                ? Theme.platformColor(for: platformID).opacity(0.4)
                                : Theme.border,
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - SectionHeader

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(Theme.font(Theme.fontSM, weight: .semibold))
            .foregroundStyle(Theme.secondaryText)
            .textCase(.uppercase)
            .tracking(0.5)
    }
}

// MARK: - HistoryChipsView

/// A flow-layout row of clickable history chips.
private struct HistoryChipsView: View {
    let items:   [String]
    let onTap:   (String) -> Void

    var body: some View {
        // SwiftUI doesn't have a native flow layout before iOS 16 / macOS 13.
        // We use a wrapping approach via a measured grid.
        FlowLayout(spacing: 8) {
            ForEach(items, id: \.self) { item in
                HistoryChip(text: item) { onTap(item) }
            }
        }
    }
}

private struct HistoryChip: View {
    let text:   String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.mutedText)
                Text(text)
                    .font(Theme.font(Theme.fontSM))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isHovered ? Theme.bgHover : Theme.bgElevated)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - FlowLayout

/// A simple flow (wrapping) layout for chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > width && currentX > 0 {
                totalHeight += rowHeight + spacing
                currentX = 0
                currentY += rowHeight + spacing
                rowHeight = 0
            }
            currentX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                currentY += rowHeight + spacing
                currentX = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            currentX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - AlbumResultListView

private struct AlbumResultListView: View {
    let albums:   [Album]
    let onSelect: (Album) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(albums) { album in
                AlbumResultRow(album: album) { onSelect(album) }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
        }
    }
}

private struct AlbumResultRow: View {
    let album:    Album
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 7) {
                coverImage
                    .frame(width: 112, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMD))
                    .shadow(color: .black.opacity(0.24), radius: 4, y: 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(album.name)
                        .font(Theme.font(Theme.fontSM, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(2)
                        .frame(width: 112, alignment: .leading)

                    HStack(spacing: 5) {
                        Text(album.artist)
                            .font(Theme.font(Theme.fontXS))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)

                        if !album.year.isEmpty {
                            Text("·")
                                .font(Theme.font(Theme.fontXS))
                                .foregroundStyle(Theme.mutedText)
                            Text(album.year)
                                .font(Theme.font(Theme.fontXS))
                                .foregroundStyle(Theme.mutedText)
                                .lineLimit(1)
                        }
                    }
                    .frame(width: 112, alignment: .leading)
                }
            }
            .padding(8)
            .background(isHovered ? Theme.bgHover : Theme.bgElevated)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLG))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusLG)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusLG))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }

    @ViewBuilder private var coverImage: some View {
        AsyncImage(url: URL(string: album.coverURL)) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(1, contentMode: .fill)
            case .failure:
                fallbackCover
            case .empty:
                fallbackCover
                    .overlay(ProgressView().scaleEffect(0.55))
            @unknown default:
                fallbackCover
            }
        }
    }

    private var fallbackCover: some View {
        Rectangle()
            .fill(Theme.bgPanel)
            .overlay(
                Image(systemName: "opticaldisc")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.mutedText)
            )
    }
}

// MARK: - AlbumDetailSheet

private struct AlbumDetailSheet: View {
    let album:          Album
    let tracks:         [Track]?
    let isLoading:      Bool
    let currentTrackID: String?
    let onPlayAll:      () -> Void
    let onPlay:         (Track) -> Void
    let onAddToQueue:   (Track) -> Void
    let onArtistClicked:(Track) -> Void
    let onAddToPlaylist:(Track) -> Void

    @Environment(\.dismiss) private var dismiss

    private var canPlayAll: Bool {
        guard let tracks else { return false }
        return !tracks.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .top, spacing: 16) {
                AsyncImage(url: URL(string: album.coverURL)) { phase in
                    if case .success(let img) = phase {
                        img.resizable().aspectRatio(1, contentMode: .fill)
                    } else {
                        Rectangle().fill(Theme.bgPanel)
                            .overlay(
                                Image(systemName: "opticaldisc")
                                    .font(.system(size: 28))
                                    .foregroundStyle(Theme.mutedText)
                            )
                    }
                }
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMD))

                VStack(alignment: .leading, spacing: 4) {
                    Text(album.name)
                        .font(Theme.font(Theme.fontLG, weight: .bold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(2)
                    Text(album.artist)
                        .font(Theme.font(Theme.fontMD))
                        .foregroundStyle(Theme.secondaryText)
                    if !album.year.isEmpty {
                        Text(album.year)
                            .font(Theme.font(Theme.fontSM))
                            .foregroundStyle(Theme.mutedText)
                    }
                    if album.trackCount > 0 {
                        Text("\(album.trackCount) 首歌曲")
                            .font(Theme.font(Theme.fontSM))
                            .foregroundStyle(Theme.mutedText)
                    }
                }
                Spacer()

                Button(action: onPlayAll) {
                    Label("全部播放", systemImage: "play.fill")
                        .font(Theme.font(Theme.fontSM, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading || !canPlayAll)

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .background(Theme.bgPanel)

            Divider().background(Theme.divider)

            // Tracks
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("加载中…")
                        .font(Theme.font(Theme.fontSM))
                        .foregroundStyle(Theme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bgSurface)
            } else if let tracks {
                TrackListView(
                    tracks: tracks,
                    currentTrackID: currentTrackID,
                    onPlay:          onPlay,
                    onAddToQueue:    onAddToQueue,
                    onArtistClicked: onArtistClicked,
                    onAddToPlaylist: onAddToPlaylist
                )
                .background(Theme.bgSurface)
            } else {
                Spacer()
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .background(Theme.bgSurface)
    }
}
