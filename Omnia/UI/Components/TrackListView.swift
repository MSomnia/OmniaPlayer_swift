import SwiftUI

// MARK: - TrackListView

public struct TrackListView: View {
    let tracks: [Track]
    let currentTrackID: String?
    let onPlay:          (Track) -> Void
    let onAddToQueue:    (Track) -> Void
    let onArtistClicked: (Track) -> Void
    let onAddToPlaylist: (Track) -> Void

    public init(
        tracks: [Track] = [],
        currentTrackID: String? = nil,
        onPlay:          @escaping (Track) -> Void = { _ in },
        onAddToQueue:    @escaping (Track) -> Void = { _ in },
        onArtistClicked: @escaping (Track) -> Void = { _ in },
        onAddToPlaylist: @escaping (Track) -> Void = { _ in }
    ) {
        self.tracks          = tracks
        self.currentTrackID  = currentTrackID
        self.onPlay          = onPlay
        self.onAddToQueue    = onAddToQueue
        self.onArtistClicked = onArtistClicked
        self.onAddToPlaylist = onAddToPlaylist
    }

    public var body: some View {
        if tracks.isEmpty {
            emptyView
        } else {
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

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 40))
                .foregroundStyle(Theme.mutedText)
            Text("暂无曲目")
                .font(Theme.font(Theme.fontMD))
                .foregroundStyle(Theme.mutedText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
