import SwiftUI

// MARK: - PlaylistPickerView
//
// Popover that lets the user pick a playlist to add a track to.

public struct PlaylistPickerView: View {
    let platform:    String
    @Binding var isPresented: Bool
    let onSelected:  (Playlist) -> Void

    @ObservedObject var ctrl: AppController
    @State private var playlists: [Playlist] = []
    @State private var isLoading = true
    @State private var error: String?

    public init(
        platform: String,
        isPresented: Binding<Bool>,
        ctrl: AppController,
        onSelected: @escaping (Playlist) -> Void
    ) {
        self.platform    = platform
        _isPresented     = isPresented
        self.ctrl        = ctrl
        self.onSelected  = onSelected
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("选择歌单")
                    .font(Theme.font(Theme.fontMD, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().background(Theme.divider)

            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = error {
                    Text(err)
                        .font(Theme.font(Theme.fontSM))
                        .foregroundStyle(Theme.mutedText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if playlists.isEmpty {
                    Text("暂无可用歌单")
                        .font(Theme.font(Theme.fontSM))
                        .foregroundStyle(Theme.mutedText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(playlists) { playlist in
                                playlistRow(playlist)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 280, height: 360)
        .background(Theme.bgElevated)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMD))
        .shadow(color: .black.opacity(0.4), radius: 20)
        .task { await loadPlaylists() }
    }

    @ViewBuilder
    private func playlistRow(_ playlist: Playlist) -> some View {
        HStack(spacing: 10) {
            // Cover thumbnail
            if let url = URL(string: playlist.coverURL), !playlist.coverURL.isEmpty {
                AsyncImage(url: url) { phase in
                    if case .success(let img) = phase {
                        img.resizable().scaledToFill()
                            .frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    } else {
                        coverPlaceholder
                    }
                }
            } else {
                coverPlaceholder
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(Theme.font(Theme.fontSM, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Text("\(playlist.trackCount) 首")
                    .font(Theme.font(Theme.fontXS))
                    .foregroundStyle(Theme.mutedText)
            }
            Spacer()
        }
        .frame(height: 52)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelected(playlist)
            isPresented = false
        }
    }

    private var coverPlaceholder: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Theme.bgBase)
            .frame(width: 36, height: 36)
            .overlay {
                Image(systemName: "music.note.list")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.mutedText)
            }
    }

    private func loadPlaylists() async {
        isLoading = true
        error = nil
        let result = await ctrl.getAddablePlaylists(for: platform)
        playlists = result
        isLoading = false
        if result.isEmpty { error = playlists.isEmpty ? nil : nil }
    }
}
