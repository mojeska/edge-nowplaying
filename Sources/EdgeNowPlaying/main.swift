import AppKit
import ServiceManagement
import SwiftUI

/// Keeps a borderless window filling the Xeneon Edge, with a menu bar icon to quit or start at login.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let music = MusicModel()
    private var window: NSWindow?
    private var status: NSStatusItem?

    func applicationDidFinishLaunching(_ note: Notification) {
        music.start()
        setUpMenu()
        place()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.place() }
            }
    }

    /// The Edge, by name; otherwise any screen at least 3 times wider than tall.
    private func edgeScreen() -> NSScreen? {
        NSScreen.screens.first { $0.localizedName.localizedCaseInsensitiveContains("XENEON EDGE") }
            ?? NSScreen.screens.first { $0.frame.width >= 3 * $0.frame.height }
    }

    private func place() {
        guard let screen = edgeScreen() else { window?.orderOut(nil); return }
        if window == nil {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.contentView = NSHostingView(rootView: NowPlayingView(music: music))
            w.backgroundColor = .black
            w.isOpaque = true
            w.hasShadow = false
            w.ignoresMouseEvents = true      // touches land on the main display anyway
            w.isReleasedWhenClosed = false
            w.level = .statusBar             // above the Edge's own menu bar
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            window = w
        }
        window?.setFrame(screen.frame, display: true)
        window?.orderFrontRegardless()
    }

    private func setUpMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "music.note.tv", accessibilityDescription: "Edge Now Playing")
        let menu = NSMenu()
        menu.addItem(withTitle: "Edge Now Playing", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        status = item
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            NSLog("Login item change failed: %@", error.localizedDescription)
        }
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}

/// `EdgeNowPlaying --render out.png [artwork.jpg]` draws the layout with sample data, for checking
/// the design without the Edge attached.
@MainActor func render(to path: String, art: String?) {
    let m = MusicModel()
    m.state = .playing
    m.title = "Under Water"; m.artist = "On Mars"; m.album = "Life After Dark"
    m.duration = 245; m.position = 92; m.positionAt = Date()
    m.artwork = art.flatMap { NSImage(contentsOfFile: $0) }
    let r = ImageRenderer(content: NowPlayingView(music: m).frame(width: 2560, height: 720))
    r.scale = 1
    guard let cg = r.cgImage,
          let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}

MainActor.assumeIsolated {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
        render(to: args[i + 1], art: i + 2 < args.count ? args[i + 2] : nil)
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
