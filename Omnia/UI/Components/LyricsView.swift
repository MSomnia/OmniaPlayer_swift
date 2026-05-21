import SwiftUI
import AppKit

// MARK: - LyricsView

public struct LyricsView: View {
    let ctrl: AppController

    @State private var lines: [LyricLine] = []
    @State private var currentLineIdx: Int = -1
    @State private var coverRGB: (Int, Int, Int) = (0, 0, 0)
    @State private var coverData: Data? = nil

    public init(ctrl: AppController) { self.ctrl = ctrl }

    private var coverColor: Color {
        let (r, g, b) = coverRGB
        return Color(red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255)
    }

    public var body: some View {
        ZStack {
            backgroundView

            if lines.isEmpty {
                emptyState
            } else {
                lyricsScroller
            }
        }
        .background(Theme.bgBase)
        .onAppear {
            lines = ctrl.currentLyrics
            currentLineIdx = Self.lineIndex(in: ctrl.currentLyrics,
                                             positionMs: ctrl.playerState.positionMs)
            coverRGB = ctrl.currentCoverColor
            coverData = ctrl.currentCoverData
        }
        .onReceive(ctrl.$currentLyrics) { newLines in
            lines = newLines
            currentLineIdx = Self.lineIndex(in: newLines,
                                             positionMs: ctrl.playerState.positionMs)
        }
        .onReceive(ctrl.$currentCoverColor) { color in
            coverRGB = color
        }
        .onReceive(ctrl.$currentCoverData) { data in
            coverData = data
        }
        // Read ctrl.currentLyrics directly (not the @State copy) to guarantee
        // a fresh array even if the onReceive closure captured a stale @State.
        .onReceive(ctrl.$playerState.map(\.positionMs).removeDuplicates()) { position in
            let idx = Self.lineIndex(in: ctrl.currentLyrics, positionMs: position)
            if idx != currentLineIdx {
                currentLineIdx = idx
            }
        }
    }

    // MARK: - Background

    private var backgroundView: some View {
        ZStack {
            Theme.bgBase

            if let coverData, let image = NSImage(data: coverData) {
                GeometryReader { geo in
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(1.18)
                        .blur(radius: 70)
                        .opacity(0.7)
                        .clipped()
                }
            } else {
                LinearGradient(
                    colors: [coverColor.opacity(0.4), Theme.bgBase],
                    startPoint: .top, endPoint: .bottom
                )
            }

            LinearGradient(
                colors: [
                    Theme.bgBase.opacity(0.25),
                    Theme.bgBase.opacity(0.56),
                    Theme.bgBase.opacity(0.86),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
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
                        .id(idx)
                    }

                    Color.clear.frame(height: 120)
                }
                .padding(.horizontal, 40)
            }
            // Jump immediately to the current line each time the view appears
            // (initial open + every re-navigation to the lyrics page).
            .onAppear {
                guard currentLineIdx >= 0 else { return }
                proxy.scrollTo(currentLineIdx, anchor: .center)
            }
            // Scroll on every line change. DispatchQueue.main.async defers the
            // call to the next run-loop cycle so it fires after the current
            // SwiftUI layout pass commits (synchronous scrollTo is dropped).
            .onChange(of: currentLineIdx) { idx in
                guard idx >= 0 else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        proxy.scrollTo(idx, anchor: .center)
                    }
                }
            }
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

// MARK: - LyricLineView

struct LyricLineView: View {
    let line:      LyricLine
    let isCurrent: Bool

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
