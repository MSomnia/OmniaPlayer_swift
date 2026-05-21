import SwiftUI
import AppKit

// MARK: - AppDelegate
// Ensures NSApp has .regular activation policy and is fully active
// before any window or keyboard event handling begins.

final class OmniaAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - OmniaApp

@main
struct OmniaApp: App {
    @NSApplicationDelegateAdaptor(OmniaAppDelegate.self) private var appDelegate
    @StateObject private var ctrl = AppController()

    var body: some Scene {
        WindowGroup {
            MainWindowView(ctrl: ctrl)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands { OmniaCommands(ctrl: ctrl) }
    }
}

// MARK: - OmniaCommands

struct OmniaCommands: Commands {
    @ObservedObject var ctrl: AppController

    var body: some Commands {
        CommandMenu("播放") {
            Button("播放 / 暂停") { ctrl.togglePlayPause() }
            Button("上一首") { Task { await ctrl.playPrev() } }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button("下一首") { Task { await ctrl.playNext() } }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Divider()
            Button("随机播放") { ctrl.toggleShuffle() }
                .keyboardShortcut("s", modifiers: .command)
            Button("循环模式") { ctrl.cycleRepeatMode() }
                .keyboardShortcut("r", modifiers: .command)
        }
    }
}
