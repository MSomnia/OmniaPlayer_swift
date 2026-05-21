import SwiftUI

// MARK: - LyricsView

public struct LyricsView: View {
    let ctrl: AppController

    @State private var lines: [LyricLine] = []
    @State private var currentLineIdx: Int = -1
    @State private var coverRGB: (Int, Int, Int) = (0, 0, 0)

    public init(ctrl: AppController) { self.ctrl = ctrl }

    private var coverColor: Color {
        let (r, g, b) = coverRGB
        return Color(red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255)
    }

    public var body: some View {
        ZStack {
            LinearGradient(
                colors: [coverColor.opacity(0.4), Theme.bgBase],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            if lines.isEmpty {
                emptyState
            } else {
                lyricsScroller
            }
        }
        .background(Theme.bgBase)
        .onAppear {
            lines = ctrl.currentLyrics
            currentLineIdx = Self.lineIndex(in: ctrl.currentLyrics, positionMs: ctrl.playerState.positionMs)
            coverRGB = ctrl.currentCoverColor
        }
        .onReceive(ctrl.$currentLyrics) { newLines in
            lines = newLines
            currentLineIdx = Self.lineIndex(in: newLines, positionMs: ctrl.playerState.positionMs)
        }
        .onReceive(ctrl.$currentCoverColor) { color in
            coverRGB = color
        }
        .onReceive(ctrl.$playerState.map(\.positionMs).removeDuplicates()) { position in
            let idx = Self.lineIndex(in: lines, positionMs: position)
            if idx != currentLineIdx {
                currentLineIdx = idx
            }
        }
    }

    // MARK: Scroller

    private var lyricsScroller: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // VStack (not LazyVStack) so that scrollTo can resolve item positions
                // instantly without needing to realize off-screen items first.
                // For typical lyric counts (50-500 lines), the upfront layout cost
                // is negligible and eliminates per-scroll O(n) work.
                VStack(spacing: 4) {
                    Color.clear.frame(height: 120)

                    ForEach(lines.indices, id: \.self) { idx in
                        LyricLineView(
                            line:      lines[idx],
                            isCurrent: idx == currentLineIdx
                        )
                        .equatable()
                        .id(idx)
                    }

                    Color.clear.frame(height: 120)
                }
                .padding(.horizontal, 40)
            }
            // Jump to the current line without animation when the view first appears
            // (covers both initial open and re-navigation from another page).
            .onAppear {
                guard currentLineIdx >= 0 else { return }
                proxy.scrollTo(currentLineIdx, anchor: .center)
            }
            // Animate scroll on each subsequent line change.
            .onChange(of: currentLineIdx) { idx in
                guard idx >= 0 else { return }
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo(idx, anchor: .center)
                }
            }
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 44))
                .foregroundStyle(Theme.mutedText)
            Text("暂无歌词")
                .font(Theme.font(Theme.fontLG))
                .foregroundStyle(Theme.mutedText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func lineIndex(in lines: [LyricLine], positionMs: Int) -> Int {
        LyricsEngine(lines: lines).currentLineIndex(positionMs: positionMs) ?? -1
    }
}

extension LyricsView: Equatable {
    public static func == (lhs: LyricsView, rhs: LyricsView) -> Bool {
        lhs.ctrl === rhs.ctrl
    }
}

// MARK: - LyricLineView

struct LyricLineView: View, Equatable {
    let line:      LyricLine
    let isCurrent: Bool

    static func == (lhs: LyricLineView, rhs: LyricLineView) -> Bool {
        lhs.line == rhs.line &&
        lhs.isCurrent == rhs.isCurrent
    }

    var body: some View {
        Text(line.text)
            .font(isCurrent
                ? Theme.font(Theme.fontLyrics, weight: .bold)
                : Theme.font(Theme.fontLG))
            .foregroundStyle(isCurrent ? Theme.lyricsActive : Theme.lyricsFuture)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(isCurrent ? 1.0 : 0.5)
            .padding(.vertical, 4)
            .animation(.easeInOut(duration: 0.2), value: isCurrent)
    }
}
