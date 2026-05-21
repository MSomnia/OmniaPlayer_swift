import SwiftUI
import Foundation

// MARK: - StandbyPageView

public struct StandbyPageView: View {
    @ObservedObject var ctrl: AppController
    let bgImage: NSImage?

    @State private var now: Date = Date()
    @State private var clockTimer: Timer? = nil

    public init(ctrl: AppController, bgImage: NSImage? = nil) {
        self.ctrl = ctrl
        self.bgImage = bgImage
    }

    // MARK: - Computed helpers

    private var coverColor: Color {
        let (r, g, b) = ctrl.currentCoverColor
        return Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    private var isPlaying: Bool {
        ctrl.playerState.status == .playing
    }

    private var recentLyrics: [LyricLine] {
        guard !ctrl.currentLyrics.isEmpty else { return [] }
        let posMs = ctrl.playerState.positionMs
        let passed = ctrl.currentLyrics.filter { $0.startMs <= posMs }
        let visible = passed.isEmpty ? Array(ctrl.currentLyrics.prefix(3)) : Array(passed.suffix(3))
        return visible
    }

    // MARK: - Body

    public var body: some View {
        ZStack(alignment: .topLeading) {
            backgroundLayer

            HStack(spacing: 0) {
                songPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                    .background(Theme.divider.opacity(0.4))
                    .padding(.vertical, 48)

                clockPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 48)

            // Exit button — top left
            Button {
                ctrl.currentPage = .home
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.secondaryText.opacity(0.7))
            }
            .buttonStyle(.plain)
            .padding(20)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            ctrl.currentPage = .home
        }
        .ignoresSafeArea()
        .background(Theme.bgBase)
        .onAppear { startClockTimer() }
        .onDisappear { stopClockTimer() }
    }

    // MARK: - Background

    private var backgroundLayer: some View {
        ZStack {
            if let img = bgImage {
                // Clear background image in standby
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                // Subtle dark overlay for readability
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
            } else {
                Theme.bgBase.ignoresSafeArea()
            }

            // Cover color gradient overlay
            RadialGradient(
                gradient: Gradient(colors: [
                    coverColor.opacity(bgImage != nil ? 0.20 : 0.40),
                    Color.clear
                ]),
                center: .center,
                startRadius: 60,
                endRadius: 520
            )
            .ignoresSafeArea()
        }
    }

    // MARK: - Song panel (left)

    private var songPanel: some View {
        VStack(spacing: 0) {
            Spacer()

            CoverArtView(
                imageData: ctrl.currentCoverData,
                isPlaying: isPlaying,
                shadowColor: coverColor,
                cornerRadius: 20,
                size: 220,
                rotate: false
            )

            trackInfoBlock
                .padding(.top, 28)

            if !recentLyrics.isEmpty {
                lyricsBlock.padding(.top, 20)
            }

            Spacer()
        }
        .padding(.trailing, 24)
    }

    private var trackInfoBlock: some View {
        VStack(spacing: 6) {
            if let track = ctrl.playerState.currentTrack {
                Text(track.title)
                    .font(Theme.font(Theme.fontXL, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                Text(track.artist)
                    .font(Theme.font(Theme.fontLG))
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
            } else {
                Text("未在播放")
                    .font(Theme.font(Theme.fontXL, weight: .bold))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private var lyricsBlock: some View {
        VStack(spacing: 6) {
            ForEach(recentLyrics) { line in
                Text(line.text)
                    .font(Theme.font(Theme.fontLG))
                    .foregroundStyle(
                        isCurrentLine(line) ? Theme.lyricsActive : Theme.lyricsFuture
                    )
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .animation(.easeInOut(duration: 0.25), value: line.id)
            }
        }
        .padding(.horizontal, 12)
    }

    private func isCurrentLine(_ line: LyricLine) -> Bool {
        guard let last = recentLyrics.last else { return false }
        return line.id == last.id
    }

    // MARK: - Clock panel (right)

    private var clockPanel: some View {
        VStack(spacing: 24) {
            Spacer()
            AnalogClockView(date: now, accentColor: coverColor)
                .frame(width: 220, height: 220)
            dateLabel
            Spacer()
        }
        .padding(.leading, 24)
    }

    private var dateLabel: some View {
        let df = DateFormatter()
        df.dateFormat = "yyyy年M月d日 EEEE"
        df.locale = Locale(identifier: "zh_CN")
        return Text(df.string(from: now))
            .font(Theme.font(Theme.fontMD))
            .foregroundStyle(Theme.secondaryText)
    }

    // MARK: - Timer

    private func startClockTimer() {
        stopClockTimer()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            now = Date()
        }
        RunLoop.main.add(clockTimer!, forMode: .common)
    }

    private func stopClockTimer() {
        clockTimer?.invalidate()
        clockTimer = nil
    }
}

// MARK: - AnalogClockView

private struct AnalogClockView: View {
    let date: Date
    let accentColor: Color

    private var cal: Calendar { Calendar.current }

    private var secondAngle: Angle {
        let s = Double(cal.component(.second, from: date))
        return Angle(degrees: s / 60 * 360 - 90)
    }
    private var minuteAngle: Angle {
        let s = Double(cal.component(.second, from: date))
        let m = Double(cal.component(.minute, from: date)) + s / 60
        return Angle(degrees: m / 60 * 360 - 90)
    }
    private var hourAngle: Angle {
        let s = Double(cal.component(.second, from: date))
        let m = Double(cal.component(.minute, from: date)) + s / 60
        let h = Double(cal.component(.hour, from: date)).truncatingRemainder(dividingBy: 12) + m / 60
        return Angle(degrees: h / 12 * 360 - 90)
    }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let cx = geo.size.width / 2
            let cy = geo.size.height / 2
            let r = size / 2
            ClockFace(
                center: CGPoint(x: cx, y: cy),
                radius: r,
                hourAngle: hourAngle,
                minuteAngle: minuteAngle,
                secondAngle: secondAngle,
                accentColor: accentColor
            )
            .animation(.linear(duration: 1), value: secondAngle.degrees)
        }
    }
}

private struct ClockFace: View {
    let center: CGPoint
    let radius: CGFloat
    let hourAngle: Angle
    let minuteAngle: Angle
    let secondAngle: Angle
    let accentColor: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.05))
            Circle()
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 2)

            ClockTicks(center: center, radius: radius)

            ClockHand(angle: hourAngle,   length: radius * 0.52, width: 4,   color: Theme.primaryText, center: center)
            ClockHand(angle: minuteAngle, length: radius * 0.72, width: 2.5, color: Theme.primaryText, center: center)
            ClockHand(angle: secondAngle, length: radius * 0.78, width: 1.5, color: accentColor,       center: center)

            Circle()
                .fill(accentColor)
                .frame(width: 10, height: 10)
                .position(center)
        }
    }
}

private struct ClockTicks: View {
    let center: CGPoint
    let radius: CGFloat

    var body: some View {
        ZStack {
            ForEach(0..<12) { i in
                ClockTick(index: i, center: center, radius: radius)
            }
        }
    }
}

private struct ClockTick: View {
    let index: Int
    let center: CGPoint
    let radius: CGFloat

    var body: some View {
        let angle = Double(index) / 12 * .pi * 2 - .pi / 2
        let isQuarter = index % 3 == 0
        let tickLen: CGFloat = isQuarter ? radius * 0.12 : radius * 0.06
        let cosA = CGFloat(Foundation.cos(angle))
        let sinA = CGFloat(Foundation.sin(angle))
        let outer = CGPoint(x: center.x + cosA * (radius - 2),
                            y: center.y + sinA * (radius - 2))
        let inner = CGPoint(x: center.x + cosA * (radius - 2 - tickLen),
                            y: center.y + sinA * (radius - 2 - tickLen))
        return Path { p in
            p.move(to: outer)
            p.addLine(to: inner)
        }
        .stroke(Color.white.opacity(isQuarter ? 0.7 : 0.35),
                lineWidth: isQuarter ? 2 : 1)
    }
}

// MARK: - ClockHand

private struct ClockHand: View {
    let angle: Angle
    let length: CGFloat
    let width: CGFloat
    let color: Color
    let center: CGPoint

    var body: some View {
        let rad = angle.radians
        let tip = CGPoint(
            x: center.x + CGFloat(Foundation.cos(rad)) * length,
            y: center.y + CGFloat(Foundation.sin(rad)) * length
        )
        return Path { p in
            p.move(to: center)
            p.addLine(to: tip)
        }
        .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
    }
}
