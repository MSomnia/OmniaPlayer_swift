import SwiftUI
import AppKit

public struct PlatformIconView: View {
    public let platform: String

    public init(platform: String) {
        self.platform = platform
    }

    public var body: some View {
        Group {
            if let image = platformImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Circle()
                    .fill(Theme.platformColor(for: platform))
            }
        }
        .help(platformLabel)
    }

    private var platformImage: NSImage? {
        let urls = [
            Bundle.module.url(forResource: iconName, withExtension: "svg"),
            Bundle.module.url(forResource: iconName, withExtension: "svg", subdirectory: "icons")
        ]

        for url in urls.compactMap({ $0 }) {
            if let image = NSImage(contentsOf: url) {
                return image
            }
        }
        return nil
    }

    private var iconName: String {
        switch platform {
        case "netease": return "platform-netease"
        case "spotify": return "platform-spotify"
        case "ytmusic": return "platform-youtube-music"
        default: return ""
        }
    }

    private var platformLabel: String {
        switch platform {
        case "netease": return "网易云音乐"
        case "spotify": return "Spotify"
        case "ytmusic": return "YouTube Music"
        default: return platform
        }
    }
}
