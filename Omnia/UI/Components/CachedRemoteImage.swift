import SwiftUI
import AppKit

public struct CachedRemoteImage: View {
    public let urlString: String
    public let contentMode: ContentMode

    @State private var image: NSImage?
    @State private var didFail = false

    public init(urlString: String, contentMode: ContentMode = .fill) {
        self.urlString = urlString
        self.contentMode = contentMode
    }

    public var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder
                    .task(id: urlString) {
                        await loadImage()
                    }
            }
        }
        .onChange(of: urlString) { _ in
            image = Self.cachedImage(for: urlString)
            didFail = false
        }
        .onAppear {
            image = Self.cachedImage(for: urlString)
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(Theme.bgElevated)
            .overlay {
                if !didFail {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.5)
                }
            }
    }

    private func loadImage() async {
        guard image == nil, !urlString.isEmpty, let url = URL(string: urlString) else {
            didFail = true
            return
        }

        if let cached = Self.cachedImage(for: urlString) {
            image = cached
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let downloaded = NSImage(data: data) else {
                didFail = true
                return
            }
            Self.cache.setObject(downloaded, forKey: urlString as NSString)
            image = downloaded
        } catch {
            didFail = true
        }
    }

    private static func cachedImage(for urlString: String) -> NSImage? {
        cache.object(forKey: urlString as NSString)
    }

    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        return cache
    }()
}
