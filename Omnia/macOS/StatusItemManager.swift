import AppKit
import Foundation

// MARK: - StatusItemManager
//
// Mirrors Python core/macos_media.py status-bar section.
// Displays  ♪/Ⅱ + scrolling track title in the macOS menu bar.
//
// Constants (matching Python):
//   _STATUS_VISIBLE_TEXT_CHARS = 12
//   _STATUS_SCROLL_INTERVAL_MS = 500
//   _STATUS_ITEM_WIDTH         = 155.0
//   _STATUS_SCROLL_GAP         = "   "

@MainActor
public final class StatusItemManager {

    // MARK: - Constants

    private static let visibleChars    = 12
    private static let scrollIntervalS = 0.5
    private static let scrollGap       = "   "
    private static let itemWidth: CGFloat = 155.0

    // MARK: - State

    private var statusItem: NSStatusItem?
    private var scrollTimer: Timer?
    private var scrollOffset: Int = 0
    private var scrollKey: String = ""
    private weak var controller: AppController?

    private var currentTrack: Track?
    private var currentIsPlaying: Bool = false

    // MARK: - Setup / teardown

    public init() {}

    public func setup(controller: AppController?) {
        self.controller = controller
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: Self.itemWidth)
        item.button?.target = self
        item.button?.action = #selector(buttonClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        buildMenu(for: item)
        statusItem = item
    }

    public func teardown() {
        scrollTimer?.invalidate()
        scrollTimer = nil
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    // MARK: - Public update

    public func updateTitle(track: Track?, isPlaying: Bool) {
        currentTrack   = track
        currentIsPlaying = isPlaying

        // Reset scroll when track changes
        let key = scrollKeyFor(track)
        if key != scrollKey {
            scrollKey    = key
            scrollOffset = 0
        }

        guard let item = statusItem else { return }

        if track == nil {
            item.button?.isHidden = true
            stopScrollTimer()
            return
        }
        item.button?.isHidden = false
        renderTitle()
        syncScrollTimer(for: track)
        updateMenu(isPlaying: isPlaying, hasTrack: track != nil)
    }

    // MARK: - Rendering

    private func renderTitle() {
        guard let track = currentTrack, let button = statusItem?.button else { return }
        button.title   = formatTitle(track: track, isPlaying: currentIsPlaying, offset: scrollOffset)
        button.toolTip = formatTooltip(track: track)
    }

    private func formatTitle(track: Track, isPlaying: Bool, offset: Int) -> String {
        let prefix = isPlaying ? "♪" : "Ⅱ"
        let text   = baseText(track: track)
        if text.count > Self.visibleChars {
            let marquee = text + Self.scrollGap
            let chars   = Array(marquee + marquee)
            let start   = offset % marquee.count
            let window  = String(chars[start..<(start + Self.visibleChars)])
            return "\(prefix) \(window)"
        }
        return "\(prefix) \(text)"
    }

    private func formatTooltip(track: Track) -> String {
        var parts = [track.title.trimmingCharacters(in: .whitespaces)]
        let artist = track.artist.trimmingCharacters(in: .whitespaces)
        let album  = track.album.trimmingCharacters(in: .whitespaces)
        if !artist.isEmpty { parts.append(artist) }
        if !album.isEmpty  { parts.append(album)  }
        return parts.joined(separator: "\n")
    }

    private func baseText(track: Track) -> String {
        let title  = track.title.trimmingCharacters(in: .whitespaces)
        let artist = track.artist.trimmingCharacters(in: .whitespaces)
        return artist.isEmpty ? title : "\(title) - \(artist)"
    }

    private func scrollKeyFor(_ track: Track?) -> String {
        guard let t = track else { return "" }
        return "\(t.platform):\(t.id):\(t.title):\(t.artist)"
    }

    // MARK: - Scroll timer

    private func syncScrollTimer(for track: Track?) {
        guard let track else { stopScrollTimer(); return }
        if baseText(track: track).count > Self.visibleChars {
            startScrollTimer()
        } else {
            stopScrollTimer()
        }
    }

    private func startScrollTimer() {
        guard scrollTimer == nil else { return }
        scrollTimer = Timer.scheduledTimer(
            withTimeInterval: Self.scrollIntervalS,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.advanceScroll()
            }
        }
    }

    private func stopScrollTimer() {
        scrollTimer?.invalidate()
        scrollTimer = nil
    }

    private func advanceScroll() {
        guard let track = currentTrack,
              baseText(track: track).count > Self.visibleChars else {
            stopScrollTimer(); return
        }
        let marqueeLen = baseText(track: track).count + Self.scrollGap.count
        scrollOffset = (scrollOffset + 1) % marqueeLen
        renderTitle()
    }

    // MARK: - Context menu

    private func buildMenu(for item: NSStatusItem) {
        let menu = NSMenu(title: "Omnia")
        menu.autoenablesItems = false

        let prev  = NSMenuItem(title: "上一首",   action: #selector(prevTrack),  keyEquivalent: "")
        let play  = NSMenuItem(title: "播放",      action: #selector(playPause),  keyEquivalent: "")
        let next  = NSMenuItem(title: "下一首",   action: #selector(nextTrack),  keyEquivalent: "")
        let sep   = NSMenuItem.separator()
        let quit  = NSMenuItem(title: "退出 Omnia", action: #selector(quitApp),  keyEquivalent: "")

        [prev, play, next, quit].forEach { $0.target = self }

        menu.addItem(prev); menu.addItem(play); menu.addItem(next)
        menu.addItem(sep);  menu.addItem(quit)

        item.menu = menu
    }

    private func updateMenu(isPlaying: Bool, hasTrack: Bool) {
        guard let menu = statusItem?.menu else { return }
        menu.item(at: 0)?.isEnabled = hasTrack          // 上一首
        menu.item(at: 1)?.title     = isPlaying ? "暂停" : "播放"
        menu.item(at: 1)?.isEnabled = hasTrack
        menu.item(at: 2)?.isEnabled = hasTrack          // 下一首
    }

    // MARK: - Button / menu actions

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        // Menu is attached to the item — NSStatusItem will show it automatically.
        // This handler fires for left-click when no menu is auto-handled.
    }

    @objc private func prevTrack() {
        Task { await controller?.playPrev() }
    }

    @objc private func playPause() {
        controller?.togglePlayPause()
    }

    @objc private func nextTrack() {
        Task { await controller?.playNext() }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
