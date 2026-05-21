import SwiftUI

// MARK: - ArtistPageView

public struct ArtistPageView: View {
    @ObservedObject var ctrl: AppController

    public init(ctrl: AppController) {
        self.ctrl = ctrl
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Navigation bar
            navBar

            if let artist = ctrl.artistInfo {
                // Artist header + track list
                ScrollView {
                    VStack(spacing: 0) {
                        artistHeader(artist)
                        Divider()
                            .background(Theme.divider)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 8)

                        TrackListView(
                            tracks: ctrl.artistTracks,
                            currentTrackID: ctrl.playerState.currentTrack?.id,
                            onPlay: { track in
                                guard let idx = ctrl.artistTracks.firstIndex(where: { $0.id == track.id }) else { return }
                                ctrl.playQueueTracks(ctrl.artistTracks, startAt: idx)
                            },
                            onAddToQueue: { track in
                                ctrl.addToQueue(track)
                            },
                            onArtistClicked: { track in
                                ctrl.pageBeforeArtist = .artist
                                Task {
                                    await ctrl.loadArtist(name: track.artist, platform: track.platform)
                                    ctrl.currentPage = .artist
                                }
                            },
                            onAddToPlaylist: { _ in }
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Loading state
                loadingView
            }
        }
        .background(Theme.surfaceBackground(hasBackgroundImage: !ctrl.backgroundImagePath.isEmpty))
        .foregroundStyle(Theme.primaryText)
    }

    // MARK: - Navigation Bar

    private var navBar: some View {
        HStack(spacing: 12) {
            Button {
                ctrl.currentPage = ctrl.pageBeforeArtist
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: Theme.fontSM, weight: .semibold))
                    Text("返回")
                        .font(Theme.font(Theme.fontMD))
                }
                .foregroundStyle(Theme.secondaryText)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.bgHover.opacity(0.0))
            .contentShape(Rectangle())
            .hoverEffect()

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Theme.panelBackground(hasBackgroundImage: !ctrl.backgroundImagePath.isEmpty))
        .overlay(alignment: .bottom) {
            Divider().background(Theme.divider)
        }
    }

    // MARK: - Artist Header

    @ViewBuilder
    private func artistHeader(_ artist: Artist) -> some View {
        HStack(spacing: 20) {
            // Artist avatar
            AsyncImage(url: URL(string: artist.imageURL)) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure, .empty:
                    Circle()
                        .fill(Theme.bgElevated)
                        .overlay {
                            Image(systemName: "person.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(Theme.mutedText)
                        }
                @unknown default:
                    Circle()
                        .fill(Theme.bgElevated)
                }
            }
            .frame(width: 80, height: 80)
            .clipShape(Circle())
            .shadow(color: Theme.platformColor(for: artist.platform).opacity(0.4), radius: 16, x: 0, y: 4)

            VStack(alignment: .leading, spacing: 6) {
                Text(artist.name)
                    .font(Theme.font(Theme.fontXL, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(2)

                platformBadge(platform: artist.platform)
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    @ViewBuilder
    private func platformBadge(platform: String) -> some View {
        let label = platform == "netease" ? "网易云" : platform == "spotify" ? "Spotify" : "YouTube Music"
        Text(label)
            .font(Theme.font(Theme.fontXS, weight: .semibold))
            .foregroundStyle(Theme.platformColor(for: platform))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.platformColor(for: platform).opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM))
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
                .tint(Theme.accent)
            Text("正在加载…")
                .font(Theme.font(Theme.fontMD))
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Hover Effect helper (no-op on macOS without UIKit)

private extension View {
    @ViewBuilder func hoverEffect() -> some View {
        self
    }
}
