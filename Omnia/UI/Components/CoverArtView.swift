import SwiftUI

// MARK: - CoverArtView
//
// Displays the album cover with:
//   • Rounded corners (cornerRadius configurable, default 12)
//   • Colored drop shadow from the dominant cover color
//   • Optional continuous rotation animation while playing

public struct CoverArtView: View {
    var imageData:    Data?
    var isPlaying:    Bool
    var shadowColor:  Color
    var cornerRadius: CGFloat
    var size:         CGFloat
    var rotate:       Bool

    @State private var rotation: Double = 0
    @State private var timer: Timer?

    public init(
        imageData:    Data?    = nil,
        isPlaying:    Bool     = false,
        shadowColor:  Color    = Color(hex: "#1DB954"),
        cornerRadius: CGFloat  = 12,
        size:         CGFloat  = 220,
        rotate:       Bool     = true
    ) {
        self.imageData    = imageData
        self.isPlaying    = isPlaying
        self.shadowColor  = shadowColor
        self.cornerRadius = cornerRadius
        self.size         = size
        self.rotate       = rotate
    }

    public var body: some View {
        coverImage
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .shadow(color: shadowColor.opacity(0.7), radius: 40, x: 0, y: 8)
            .rotationEffect(.degrees(rotation))
            .onChange(of: isPlaying) { playing in
                updateRotation(playing: playing)
            }
            .onAppear { updateRotation(playing: isPlaying) }
            .onDisappear { stopTimer() }
    }

    // MARK: Image

    @ViewBuilder private var coverImage: some View {
        if let data = imageData, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
        } else {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Theme.bgElevated)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.25))
                        .foregroundStyle(Theme.mutedText)
                }
        }
    }

    // MARK: Rotation (smooth 20s per revolution, stops when paused)

    private func updateRotation(playing: Bool) {
        stopTimer()
        guard rotate, playing else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            rotation += 0.9
            if rotation >= 360 { rotation -= 360 }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
