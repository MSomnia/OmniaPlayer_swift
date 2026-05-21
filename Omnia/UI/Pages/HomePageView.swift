import SwiftUI

public struct HomePageView: View {
    @ObservedObject var ctrl: AppController
    @State private var selectedPlatform = "netease"

    private let platforms: [(id: String, label: String)] = [
        ("netease", "网易云音乐"),
        ("spotify", "Spotify"),
        ("ytmusic", "YouTube Music")
    ]

    public init(ctrl: AppController) { self.ctrl = ctrl }

    private func isAuthenticated(_ platform: String) -> Bool {
        switch platform {
        case "netease": return ctrl.isNeteaseAuthenticated
        case "spotify": return ctrl.isSpotifyAuthenticated
        case "ytmusic": return ctrl.isYTMusicAuthenticated
        default: return false
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            platformTabs
            Divider().background(Theme.divider)
            platformContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surfaceBackground(hasBackgroundImage: !ctrl.backgroundImagePath.isEmpty))
        .task(id: selectedPlatform) {
            await ctrl.prepareHome(for: selectedPlatform)
        }
        // Re-load when auth state changes (e.g. user just logged in while on this page)
        .onChange(of: ctrl.isNeteaseAuthenticated) { auth in
            if auth && selectedPlatform == "netease" { Task { await ctrl.prepareHome(for: "netease") } }
        }
        .onChange(of: ctrl.isSpotifyAuthenticated) { auth in
            if auth && selectedPlatform == "spotify" { Task { await ctrl.prepareHome(for: "spotify") } }
        }
        .onChange(of: ctrl.isYTMusicAuthenticated) { auth in
            if auth && selectedPlatform == "ytmusic" { Task { await ctrl.prepareHome(for: "ytmusic") } }
        }
    }

    private var platformTabs: some View {
        HStack(spacing: 0) {
            ForEach(platforms, id: \.id) { p in
                Button(action: { selectedPlatform = p.id }) {
                    Text(p.label)
                        .font(Theme.font(Theme.fontSM, weight: selectedPlatform == p.id ? .semibold : .regular))
                        .foregroundStyle(selectedPlatform == p.id ? Theme.primaryText : Theme.secondaryText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .overlay(alignment: .bottom) {
                            if selectedPlatform == p.id {
                                Rectangle()
                                    .fill(Theme.platformColor(for: p.id))
                                    .frame(height: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .background(Theme.panelBackground(hasBackgroundImage: !ctrl.backgroundImagePath.isEmpty))
    }

    @ViewBuilder
    private var platformContent: some View {
        if !isAuthenticated(selectedPlatform) {
            loginPrompt
        } else if ctrl.homeSections[selectedPlatform] == nil {
            ProgressView()
                .progressViewStyle(.circular)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let sections = ctrl.homeSections[selectedPlatform], !sections.isEmpty {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                        SectionRowView(
                            sectionTitle: section.0,
                            tracks: Array(section.1.prefix(8)),
                            ctrl: ctrl
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
        } else {
            Text("暂无内容")
                .font(Theme.font(Theme.fontMD))
                .foregroundStyle(Theme.mutedText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var loginPrompt: some View {
        let label = platforms.first(where: { $0.id == selectedPlatform })?.label ?? selectedPlatform
        return VStack(spacing: 16) {
            Button(action: { ctrl.requestLogin(for: selectedPlatform) }) {
                Text("登录 \(label)")
                    .font(Theme.font(Theme.fontMD, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Theme.platformColor(for: selectedPlatform))
                    .cornerRadius(Theme.radiusMD)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SectionRowView: View {
    let sectionTitle: String
    let tracks: [Track]
    @ObservedObject var ctrl: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(sectionTitle)
                .font(Theme.font(Theme.fontMD, weight: .semibold))
                .foregroundStyle(Theme.primaryText)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, track in
                        TrackCardView(track: track, allTracks: tracks, index: idx, ctrl: ctrl)
                    }
                }
            }
        }
    }
}

private struct TrackCardView: View {
    let track: Track
    let allTracks: [Track]
    let index: Int
    @ObservedObject var ctrl: AppController
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                CachedRemoteImage(urlString: track.albumCoverURL)
                .frame(width: 80, height: 80)
                .cornerRadius(Theme.radiusMD)
                .clipped()

                if isHovered {
                    RoundedRectangle(cornerRadius: Theme.radiusMD)
                        .fill(Color.black.opacity(0.3))
                        .frame(width: 80, height: 80)
                }
            }

            Text(track.title)
                .font(Theme.font(Theme.fontSM, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .frame(width: 80, alignment: .leading)

            Button(action: navigateToArtist) {
                Text(track.artist)
                    .font(Theme.font(Theme.fontXS))
                    .foregroundStyle(isHovered ? Theme.secondaryText : Theme.mutedText)
                    .lineLimit(1)
                    .frame(width: 80, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 80)
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) {
            ctrl.playQueueTracks(allTracks, startAt: index)
        }
        .contextMenu {
            Button("播放") { ctrl.playQueueTracks(allTracks, startAt: index) }
            Button("加入队列") { ctrl.addToQueue(track) }
        }
    }

    private func navigateToArtist() {
        ctrl.pageBeforeArtist = ctrl.currentPage
        Task { await ctrl.loadArtist(name: track.artist, platform: track.platform) }
        ctrl.currentPage = .artist
    }
}
