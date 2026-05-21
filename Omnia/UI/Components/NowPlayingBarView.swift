import SwiftUI

public struct NowPlayingBarView: View {
    @ObservedObject var ctrl: AppController

    @State private var showQueue          = false
    @State private var showPlaylistPicker = false
    // Debounce guard: prevents re-opening queue immediately after close
    @State private var queueClosedAt: Date = .distantPast

    public init(ctrl: AppController) { self.ctrl = ctrl }

    private var state:     PlayerState { ctrl.playerState }
    private var track:     Track?      { state.currentTrack }
    private var isPlaying: Bool        { state.status == .playing }

    public var body: some View {
        HStack(spacing: 0) {

            // ── Left: cover + track info ───────────────────────────────────
            HStack(spacing: 12) { coverView; trackInfoView }
                .frame(width: 260, alignment: .leading)
                .padding(.leading, 18)

            Spacer()

            // ── Center: transport + seek bar ────────────────────────────────
            VStack(spacing: 6) { transportControls; seekBar }
                .frame(maxWidth: 480)

            Spacer()

            // ── Right: mode + navigation + volume ───────────────────────────
            HStack(spacing: 14) {
                shuffleButton
                repeatButton
                Divider().frame(height: 16).background(Theme.border)
                lyricsButton
                queueButton
                playlistButton
                Divider().frame(height: 16).background(Theme.border)
                volumeSlider
            }
            .frame(width: 300, alignment: .trailing)
            .padding(.trailing, 18)
        }
        .frame(height: 90)
        .background(Theme.panelBackground(hasBackgroundImage: !ctrl.backgroundImagePath.isEmpty))
        .overlay(alignment: .top) { Divider().background(Theme.divider) }
    }

    // MARK: Cover

    @ViewBuilder private var coverView: some View {
        Group {
            if let data = ctrl.currentCoverData, let img = NSImage(data: data) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: Theme.radiusSM)
                    .fill(Theme.bgElevated)
                    .overlay { Image(systemName: "music.note").foregroundStyle(Theme.mutedText) }
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM))
    }

    // MARK: Track info

    @ViewBuilder private var trackInfoView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(track?.title ?? "未在播放")
                .font(Theme.font(Theme.fontMD, weight: .semibold))
                .foregroundStyle(Theme.primaryText).lineLimit(1)
            Button {
                guard let t = track else { return }
                ctrl.pageBeforeArtist = ctrl.currentPage
                Task {
                    await ctrl.loadArtist(name: t.artist, platform: t.platform)
                    ctrl.currentPage = .artist
                }
            } label: {
                Text(track?.artist ?? "选择一首歌曲开始")
                    .font(Theme.font(Theme.fontSM))
                    .foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Transport

    @ViewBuilder private var transportControls: some View {
        HStack(spacing: 24) {
            iconBtn("backward.fill", size: 16) { Task { await ctrl.playPrev() } }
            Button { ctrl.togglePlayPause() } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 36)).foregroundStyle(Theme.primaryText)
            }.buttonStyle(.plain)
            iconBtn("forward.fill", size: 16) { Task { await ctrl.playNext() } }
        }
    }

    private func iconBtn(_ name: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: size)).foregroundStyle(Theme.secondaryText)
        }.buttonStyle(.plain)
    }

    // MARK: Seek bar

    @ViewBuilder private var seekBar: some View {
        let dur = max(state.durationMs, 1)
        let pct = max(0, min(Double(state.positionMs) / Double(dur), 1))
        HStack(spacing: 8) {
            Text(formatMs(state.positionMs))
                .font(Theme.font(Theme.fontXS)).foregroundStyle(Theme.mutedText)
                .monospacedDigit().frame(width: 36, alignment: .trailing)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.bgHover).frame(height: 4)
                    Capsule().fill(Theme.primaryText)
                        .frame(width: geo.size.width * pct, height: 4)
                }
                .contentShape(Rectangle())
                .simultaneousGesture(
                    SpatialTapGesture()
                        .onEnded { val in
                            let p = max(0, min(val.location.x / geo.size.width, 1))
                            ctrl.seek(to: Int(p * Double(dur)))
                        }
                )
                .gesture(
                    DragGesture(minimumDistance: 6)
                        .onEnded { val in
                            let p = max(0, min(val.location.x / geo.size.width, 1))
                            ctrl.seek(to: Int(p * Double(dur)))
                        }
                )
            }.frame(height: 8)
            Text(formatMs(dur))
                .font(Theme.font(Theme.fontXS)).foregroundStyle(Theme.mutedText)
                .monospacedDigit().frame(width: 36, alignment: .leading)
        }
    }

    // MARK: Mode buttons

    private var shuffleButton: some View {
        Button { ctrl.toggleShuffle() } label: {
            Image(systemName: "shuffle")
                .foregroundStyle(state.shuffle ? Theme.accent : Theme.secondaryText)
        }.buttonStyle(.plain)
    }

    private var repeatButton: some View {
        Button { ctrl.cycleRepeatMode() } label: {
            Image(systemName: state.repeatMode == .one ? "repeat.1" : "repeat")
                .foregroundStyle(state.repeatMode == .none ? Theme.secondaryText : Theme.accent)
        }.buttonStyle(.plain)
    }

    // MARK: Navigation / panel buttons

    private var lyricsButton: some View {
        Button {
            if ctrl.currentPage == .lyrics {
                ctrl.currentPage = ctrl.pageBeforeLyrics == .lyrics ? .home : ctrl.pageBeforeLyrics
            } else {
                ctrl.pageBeforeLyrics = ctrl.currentPage
                ctrl.currentPage = .lyrics
            }
        } label: {
            Image(systemName: "text.alignleft")
                .foregroundStyle(ctrl.currentPage == .lyrics ? Theme.accent : Theme.secondaryText)
        }.buttonStyle(.plain)
        .help("歌词")
    }

    private var queueButton: some View {
        Button {
            // Guard: don't re-open if we just closed it (prevents button-release reopening)
            let elapsed = Date().timeIntervalSince(queueClosedAt)
            guard elapsed > 0.25 else { return }
            showQueue.toggle()
        } label: {
            Image(systemName: "list.bullet")
                .foregroundStyle(showQueue ? Theme.accent : Theme.secondaryText)
        }
        .buttonStyle(.plain)
        .help("队列")
        .popover(isPresented: $showQueue, arrowEdge: .top) {
            QueuePanelView(ctrl: ctrl, isPresented: $showQueue)
        }
        .onChange(of: showQueue) { open in
            if !open { queueClosedAt = Date() }
        }
    }

    private var playlistButton: some View {
        Button { showPlaylistPicker.toggle() } label: {
            Image(systemName: "music.note.list")
                .foregroundStyle(showPlaylistPicker ? Theme.accent : Theme.secondaryText)
        }
        .buttonStyle(.plain)
        .help("加入歌单")
        .disabled(track == nil)
        .popover(isPresented: $showPlaylistPicker, arrowEdge: .top) {
            if let t = track {
                PlaylistPickerView(
                    platform: t.platform,
                    isPresented: $showPlaylistPicker,
                    ctrl: ctrl
                ) { playlist in
                    Task { _ = await ctrl.addTrackToPlaylist(t, to: playlist) }
                }
            }
        }
    }

    // MARK: Volume

    private var volumeSlider: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.fill").font(.system(size: 11)).foregroundStyle(Theme.mutedText)
            Slider(
                value: Binding(
                    get: { Double(state.volume) },
                    set: { ctrl.setVolume(Int($0)) }
                ),
                in: 0...100
            ).tint(Theme.primaryText).frame(width: 80)
        }
    }

    private func formatMs(_ ms: Int) -> String {
        let s = ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
