import SwiftUI

// MARK: - Scroll proxy holder

// A reference-type holder so the scroll view proxy can be accessed from
// outside the ScrollViewReader closure (i.e. from onReceive handlers).
private final class LyricScrollProxy: ObservableObject {
    var proxy: ScrollViewProxy?  // intentionally NOT @Published
}

// MARK: - LyricsView

public struct LyricsView: View {
    let ctrl: AppController

    @State private var lines: [LyricLine] = []
    @State private var currentLineIdx: Int = -1
    @State private var coverRGB: (Int, Int, Int) = (0, 0, 0)

    // Holds the ScrollViewProxy so onReceive can scroll without going through
    // onChange inside the ScrollViewReader closure (which is unreliable because
    // the closure is recreated on every body evaluation, losing onChange state).
    @StateObject private var scrollProxy = LyricScrollProxy()

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
            let idx = Self.lineIndex(in: ctrl.currentLyrics, positionMs: ctrl.playerState.positionMs)
            currentLineIdx = idx
            coverRGB = ctrl.currentCoverColor
            scheduleScroll(to: idx)
        }
        .onReceive(ctrl.$currentLyrics) { newLines in
            lines = newLines
            let idx = Self.lineIndex(in: newLines, positionMs: ctrl.playerState.positionMs)
            currentLineIdx = idx
            scheduleScroll(to: idx)
        }
        .onReceive(ctrl.$currentCoverColor) { color in
            coverRGB = color
        }
        .onReceive(ctrl.$playerState.map(\.positionMs).removeDuplicates()) { position in
            let idx = Self.lineIndex(in: lines, positionMs: position)
            if idx != currentLineIdx {
                currentLineIdx = idx
                scheduleScroll(to: idx)
            }
        }
    }

    // MARK: - Scroll helper

    // Dispatch the scroll to the next run-loop cycle so it always runs after
    // the current SwiftUI layout pass has committed (proxy.scrollTo called
    // synchronously inside onChange fires during the layout pass and is dropped).
    private func scheduleScroll(to idx: Int) {
        guard idx >= 0 else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.4)) {
                scrollProxy.proxy?.scrollTo(idx, anchor: .center)
            }
        }
    }

    // MARK: - Scroller

    private var lyricsScroller: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
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
            .onAppear {
                // Store the proxy so scheduleScroll can reach it from outside
                // this closure. Also do an immediate (no-animation) jump so
                // the view opens at the right line every time.
                scrollProxy.proxy = proxy
                guard currentLineIdx >= 0 else { return }
                proxy.scrollTo(currentLineIdx, anchor: .center)
            }
            // No onChange here — scroll is driven via scheduleScroll / scrollProxy
        }
    }

    // MARK: - Empty state

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
