import SwiftUI
import AppKit

// MARK: - AggregateSearchPageView

public struct AggregateSearchPageView: View {
    @ObservedObject var ctrl: AppController

    @State private var query: String = ""
    @State private var resultsByPlatform: [String: [Track]] = [:]
    @State private var isSearching = false
    @State private var debounceTask: Task<Void, Never>? = nil

    private let platforms: [(id: String, label: String)] = [
        ("netease", "网易云音乐"),
        ("spotify", "Spotify"),
        ("ytmusic", "YouTube Music")
    ]
    private let perPlatformResultLimit = 10

    public init(ctrl: AppController) {
        self.ctrl = ctrl
    }

    public var body: some View {
        VStack(spacing: 0) {
            header

            Divider().background(Theme.divider)

            ZStack {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    emptyPrompt
                } else if isSearching && interleavedItems.isEmpty {
                    loadingView
                } else {
                    resultsView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.surfaceBackground(hasBackgroundImage: !ctrl.backgroundImagePath.isEmpty))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("聚合搜索")
                .font(Theme.font(Theme.fontLG, weight: .bold))
                .foregroundStyle(Theme.primaryText)

            searchField
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panelBackground(hasBackgroundImage: !ctrl.backgroundImagePath.isEmpty))
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondaryText)

            TextField("同时搜索网易云、Spotify、YouTube Music…", text: $query)
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
                    resultsByPlatform = [:]
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
        .background(Theme.elevatedBackground(hasBackgroundImage: !ctrl.backgroundImagePath.isEmpty))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMD))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusMD)
                .stroke(Theme.border, lineWidth: 1)
        )
    }

    private var resultsView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if interleavedItems.isEmpty {
                    noResultsView
                } else {
                    ForEach(Array(interleavedItems.enumerated()), id: \.element.id) { idx, item in
                        AggregateTrackRow(
                            track: item.track,
                            rank: item.rank,
                            currentTrackID: ctrl.playerState.currentTrack?.id,
                            hasBackgroundImage: !ctrl.backgroundImagePath.isEmpty,
                            onPlay: {
                                let tracks = interleavedItems.map(\.track)
                                ctrl.playQueueTracks(tracks, startAt: idx)
                            },
                            onAddToQueue: {
                                ctrl.addToQueue(item.track)
                            },
                            onArtistClicked: {
                                navigateToArtist(item.track)
                            }
                        )

                        if idx < interleavedItems.count - 1 {
                            Divider()
                                .background(Theme.divider)
                                .padding(.leading, 80)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    private var interleavedItems: [AggregateSearchItem] {
        var items: [AggregateSearchItem] = []
        for rank in 0..<perPlatformResultLimit {
            for platform in platforms {
                let platformTracks = resultsByPlatform[platform.id] ?? []
                if platformTracks.indices.contains(rank) {
                    items.append(AggregateSearchItem(track: platformTracks[rank], rank: rank + 1))
                }
            }
        }
        return items
    }

    private var emptyPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 40))
                .foregroundStyle(Theme.mutedText)
            Text("输入关键词进行聚合搜索")
                .font(Theme.font(Theme.fontMD))
                .foregroundStyle(Theme.mutedText)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .scaleEffect(1.2)
            Text("正在搜索三个平台…")
                .font(Theme.font(Theme.fontSM))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private var noResultsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 40))
                .foregroundStyle(Theme.mutedText)
            Text("未找到结果")
                .font(Theme.font(Theme.fontMD))
                .foregroundStyle(Theme.mutedText)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func triggerDebounce(delay: UInt64 = 400) {
        debounceTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            isSearching = false
            resultsByPlatform = [:]
            return
        }

        debounceTask = Task {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay * 1_000_000)
            }
            guard !Task.isCancelled else { return }

            await MainActor.run { isSearching = true }
            let searchResults = await searchAllPlatforms(query: trimmed)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                resultsByPlatform = searchResults
                isSearching = false
            }
        }
    }

    private func searchAllPlatforms(query: String) async -> [String: [Track]] {
        await withTaskGroup(of: (String, [Track]).self) { group in
            for platform in platforms {
                group.addTask {
                    let tracks = await ctrl.searchTracks(query: query, platform: platform.id, limit: perPlatformResultLimit)
                    return (platform.id, tracks)
                }
            }

            var grouped: [String: [Track]] = [:]
            for await (platform, tracks) in group {
                grouped[platform] = tracks
            }
            return grouped
        }
    }

    private func navigateToArtist(_ track: Track) {
        ctrl.openArtist(name: track.artist, platform: track.platform)
    }
}

private struct AggregateSearchItem: Identifiable, Hashable {
    let track: Track
    let rank: Int

    var id: String {
        "\(track.platform)-\(track.id)-\(rank)"
    }
}

// MARK: - AggregateTrackRow

private struct AggregateTrackRow: View {
    let track: Track
    let rank: Int
    let currentTrackID: String?
    let hasBackgroundImage: Bool
    let onPlay: () -> Void
    let onAddToQueue: () -> Void
    let onArtistClicked: () -> Void

    @State private var isHovered = false

    private var isCurrentTrack: Bool {
        track.id == currentTrackID
    }

    var body: some View {
        HStack(spacing: 0) {
            rankCell
                .frame(width: 36)

            PlatformIconView(platform: track.platform)
                .frame(width: 28)
                .padding(.trailing, 10)

            coverCell
                .frame(width: 44)

            titleArtistCell
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(track.album)
                .font(Theme.font(Theme.fontSM))
                .foregroundStyle(Theme.mutedText)
                .lineLimit(1)
                .frame(width: 160, alignment: .leading)
                .padding(.trailing, 8)

            Text(formatMs(track.durationMs))
                .font(Theme.font(Theme.fontSM))
                .foregroundStyle(Theme.mutedText)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
                .padding(.trailing, 12)
        }
        .frame(height: 48)
        .padding(.horizontal, 8)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) { onPlay() }
        .contextMenu {
            Button("播放") { onPlay() }
            Button("加入队列") { onAddToQueue() }
            Divider()
            Button("查看艺术家") { onArtistClicked() }
        }
    }

    @ViewBuilder private var rankCell: some View {
        if isHovered || isCurrentTrack {
            Button(action: onPlay) {
                Image(systemName: isCurrentTrack ? "waveform" : "play.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(isCurrentTrack ? Theme.accent : Theme.primaryText)
            }
            .buttonStyle(.plain)
        } else {
            Text("\(rank)")
                .font(Theme.font(Theme.fontSM))
                .foregroundStyle(Theme.mutedText)
                .monospacedDigit()
        }
    }

    @ViewBuilder private var coverCell: some View {
        if !track.albumCoverURL.isEmpty, URL(string: track.albumCoverURL) != nil {
            CachedRemoteImage(urlString: track.albumCoverURL)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            placeholderCover
        }
    }

    private var placeholderCover: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Theme.elevatedBackground(hasBackgroundImage: hasBackgroundImage))
            .frame(width: 34, height: 34)
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.mutedText)
            }
    }

    private var titleArtistCell: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(track.title)
                .font(Theme.font(Theme.fontMD, weight: isCurrentTrack ? .semibold : .regular))
                .foregroundStyle(isCurrentTrack ? Theme.accent : Theme.primaryText)
                .lineLimit(1)

            Button(action: onArtistClicked) {
                Text(track.artist)
                    .font(Theme.font(Theme.fontSM))
                    .foregroundStyle(isHovered ? Theme.secondaryText.opacity(0.8) : Theme.secondaryText)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 4)
    }

    private var rowBackground: Color {
        if isCurrentTrack { return Theme.accent.opacity(0.08) }
        if isHovered { return Theme.hoverBackground(hasBackgroundImage: hasBackgroundImage) }
        return Color.clear
    }

    private func formatMs(_ ms: Int) -> String {
        let s = ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
