import SwiftUI

// MARK: - TrackRowView

public struct TrackRowView: View {
    let track:           Track
    let index:           Int
    let isCurrentTrack:  Bool
    let onPlay:          () -> Void
    let onAddToQueue:    () -> Void
    let onArtistClicked: () -> Void
    let onAddToPlaylist: () -> Void

    @State private var isHovered = false

    public init(
        track: Track,
        index: Int = 0,
        isCurrentTrack: Bool = false,
        onPlay:          @escaping () -> Void = {},
        onAddToQueue:    @escaping () -> Void = {},
        onArtistClicked: @escaping () -> Void = {},
        onAddToPlaylist: @escaping () -> Void = {}
    ) {
        self.track           = track
        self.index           = index
        self.isCurrentTrack  = isCurrentTrack
        self.onPlay          = onPlay
        self.onAddToQueue    = onAddToQueue
        self.onArtistClicked = onArtistClicked
        self.onAddToPlaylist = onAddToPlaylist
    }

    public var body: some View {
        HStack(spacing: 0) {

            // ── Index / Play icon (40px) ──────────────────────────────────────
            indexCell
                .frame(width: 40)

            // ── Cover thumbnail (32x32) ───────────────────────────────────────
            coverCell
                .frame(width: 44)

            // ── Title + Artist (flex) ─────────────────────────────────────────
            titleArtistCell
                .frame(maxWidth: .infinity, alignment: .leading)

            // ── Album (160px, hidden on narrow) ──────────────────────────────
            Text(track.album)
                .font(Theme.font(Theme.fontSM))
                .foregroundStyle(Theme.mutedText)
                .lineLimit(1)
                .frame(width: 160, alignment: .leading)
                .padding(.trailing, 8)

            // ── Duration ──────────────────────────────────────────────────────
            Text(formatMs(track.durationMs))
                .font(Theme.font(Theme.fontSM))
                .foregroundStyle(Theme.mutedText)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
                .padding(.trailing, 12)

            // ── Platform badge ────────────────────────────────────────────────
            platformBadge
                .frame(width: 28)
                .padding(.trailing, 8)
        }
        .frame(height: 44)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) { onPlay() }
        .contextMenu { contextMenuItems }
    }

    // MARK: Index cell

    @ViewBuilder private var indexCell: some View {
        Group {
            if isHovered || isCurrentTrack {
                Button(action: onPlay) {
                    Image(systemName: isCurrentTrack ? "waveform" : "play.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(isCurrentTrack ? Theme.accent : Theme.primaryText)
                }
                .buttonStyle(.plain)
            } else {
                Text("\(index)")
                    .font(Theme.font(Theme.fontSM))
                    .foregroundStyle(Theme.mutedText)
                    .monospacedDigit()
            }
        }
        .frame(width: 40, alignment: .center)
    }

    // MARK: Cover thumbnail

    @ViewBuilder private var coverCell: some View {
        if let url = URL(string: track.albumCoverURL), !track.albumCoverURL.isEmpty {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                default:
                    placeholderCover
                }
            }
        } else {
            placeholderCover
        }
    }

    private var placeholderCover: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Theme.bgElevated)
            .frame(width: 32, height: 32)
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.mutedText)
            }
    }

    // MARK: Title + Artist

    @ViewBuilder private var titleArtistCell: some View {
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

    // MARK: Platform badge

    @ViewBuilder private var platformBadge: some View {
        let color = Theme.platformColor(for: track.platform)
        Circle()
            .fill(color.opacity(0.8))
            .frame(width: 8, height: 8)
            .help(platformLabel(track.platform))
    }

    private func platformLabel(_ platform: String) -> String {
        switch platform {
        case "netease": return "网易云音乐"
        case "spotify": return "Spotify"
        case "ytmusic": return "YouTube Music"
        default: return platform
        }
    }

    // MARK: Row background

    private var rowBackground: Color {
        if isCurrentTrack { return Theme.accent.opacity(0.08) }
        if isHovered       { return Theme.bgHover }
        return Color.clear
    }

    // MARK: Context menu

    @ViewBuilder private var contextMenuItems: some View {
        Button("播放") { onPlay() }
        Button("加入队列") { onAddToQueue() }
        Divider()
        Button("加入歌单…") { onAddToPlaylist() }
        Button("查看艺术家") { onArtistClicked() }
    }

    // MARK: Helpers

    private func formatMs(_ ms: Int) -> String {
        let s = ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
