import AppKit
import ServiceManagement
import SwiftUI

/// Keeps a borderless window filling the Xeneon Edge, with a menu bar icon to quit or start at login.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let music = MusicModel()
    private var window: NSWindow?
    private var status: NSStatusItem?

    /// Dock icon on (the default) makes it quit like any app: right-click in the Dock, or ⌘Q.
    private var showInDock: Bool {
        get { UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showInDock"); applyDockSetting() }
    }

    /// Display options, read by NowPlayingView through @AppStorage.
    private static let displayOptions = [("Show Clock", "showClock")]

    private func displayItems() -> [NSMenuItem] {
        Self.displayOptions.map { title, key in
            let i = NSMenuItem(title: title, action: #selector(toggleOption(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = key
            i.state = option(key) ? .on : .off
            return i
        }
    }

    @objc private func toggleOption(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        setOption(key, sender.state != .on)
    }

    private func option(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// Saves the option and ticks it in the menu bar menu; the right-click menu is rebuilt each time.
    private func setOption(_ key: String, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: key)
        status?.menu?.items.first { $0.representedObject as? String == key }?.state = on ? .on : .off
    }

    private func applyDockSetting() {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
        if let item = status?.menu?.items.first(where: { $0.title == "Show in Dock" }) { item.state = showInDock ? .on : .off }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        music.start()
        setUpMainMenu()
        setUpMenu()
        applyDockSetting()
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
            // A non-activating panel, so clicking it doesn't pull the app to the front.
            let w = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            let view = EdgeView(content: NSHostingView(rootView: NowPlayingView(music: music)))
            view.makeMenu = { [weak self] in self?.edgeMenu() }
            w.contentView = view
            w.backgroundColor = .black
            w.isOpaque = true
            w.hasShadow = false
            w.hidesOnDeactivate = false
            w.isReleasedWhenClosed = false
            w.level = .statusBar             // above the Edge's own menu bar
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            window = w
        }
        window?.setFrame(screen.frame, display: true)
        window?.orderFrontRegardless()
    }

    /// App menu shown while the app is in front (Dock icon on).
    private func setUpMainMenu() {
        let main = NSMenu(), appItem = NSMenuItem()
        main.addItem(appItem)
        let m = NSMenu()
        m.addItem(withTitle: "Edge Now Playing Settings…", action: #selector(openControls), keyEquivalent: ",").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Hide Edge Now Playing", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        m.addItem(withTitle: "Quit Edge Now Playing", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = m
        NSApp.mainMenu = main
    }

    /// Right-click menu on the Edge: player controls, then the app's own settings.
    private func edgeMenu() -> NSMenu {
        let m = NSMenu(), active = music.state != .off
        m.autoenablesItems = false
        if active {
            m.addItem(withTitle: music.sourceName, action: nil, keyEquivalent: "").isEnabled = false
        }
        let items: [(String, MusicModel.Command)] = [
            (music.state == .playing ? "Pause" : "Play", .playPause), ("Next Track", .next), ("Previous Track", .previous)]
        for (title, c) in items {
            let i = m.addItem(withTitle: title, action: #selector(sendCommand(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = c.rawValue; i.isEnabled = active
        }
        m.addItem(.separator())
        displayItems().forEach(m.addItem)
        m.addItem(.separator())
        m.addItem(withTitle: "Settings…", action: #selector(openControls), keyEquivalent: "").target = self
        m.addItem(withTitle: "Quit Edge Now Playing", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        return m
    }

    @objc private func sendCommand(_ sender: NSMenuItem) {
        if let c = (sender.representedObject as? String).flatMap(MusicModel.Command.init) { music.send(c) }
    }

    @objc private func openControls() { showControls() }

    @objc private func toggleDock(_ sender: NSMenuItem) { showInDock.toggle() }

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
        let dock = NSMenuItem(title: "Show in Dock", action: #selector(toggleDock(_:)), keyEquivalent: "")
        dock.target = self
        menu.addItem(dock)
        menu.addItem(.separator())
        displayItems().forEach(menu.addItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        status = item
    }

    /// Opening the app again while it runs (Finder, Spotlight, Launchpad) shows its controls,
    /// since the menu bar icon can be hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showControls(); return false
    }

    private func showControls() {
        let a = NSAlert()
        a.messageText = "Edge Now Playing is running"
        a.informativeText = edgeScreen() == nil ? "No Xeneon Edge found." : "Showing on the Xeneon Edge."
        a.addButton(withTitle: "Keep Running")
        a.addButton(withTitle: "Quit")
        let login = NSButton(checkboxWithTitle: "Start at Login", target: nil, action: nil)
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let dock = NSButton(checkboxWithTitle: "Show in Dock (quit from the Dock or with ⌘Q)", target: nil, action: nil)
        dock.state = showInDock ? .on : .off
        let options = Self.displayOptions.map { title, key in
            let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            b.state = option(key) ? .on : .off
            return (b, key)
        }
        let box = NSStackView(views: [login, dock] + options.map(\.0))
        box.orientation = .vertical; box.alignment = .leading; box.spacing = 6
        box.frame = NSRect(x: 0, y: 0, width: 320, height: CGFloat(box.views.count) * 23)
        a.accessoryView = box
        NSApp.activate(ignoringOtherApps: true)
        let r = a.runModal()
        setLogin(login.state == .on)
        if (dock.state == .on) != showInDock { showInDock = dock.state == .on }
        for (b, key) in options { setOption(key, b.state == .on) }
        if let item = status?.menu?.items.first(where: { $0.title == "Start at Login" }) {
            item.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
        if r == .alertSecondButtonReturn { NSApp.terminate(nil) }
    }

    private func setLogin(_ on: Bool) {
        guard on != (SMAppService.mainApp.status == .enabled) else { return }
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { NSLog("Login item change failed: %@", error.localizedDescription) }
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        setLogin(SMAppService.mainApp.status != .enabled)
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}

/// Holds the SwiftUI view and takes every click itself, so right-clicks show the app's menu
/// instead of falling through to Finder's desktop menu. Left clicks do nothing.
final class EdgeView: NSView {
    var makeMenu: (() -> NSMenu?)?

    init(content: NSView) {
        super.init(frame: .zero)
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event) }
    }
    override func rightMouseDown(with event: NSEvent) {
        if let m = makeMenu?() { NSMenu.popUpContextMenu(m, with: event, for: self) }
    }
}

/// `EdgeNowPlaying --render out.png [artwork.jpg]` draws the layout with sample data, for checking
/// the design without the Edge attached.
@MainActor func render(to path: String, art: String?) {
    let m = MusicModel()
    m.state = .playing
    m.title = "Sample Song"; m.artist = "Sample Artist"; m.album = "Sample Album"
    m.duration = 245; m.position = 92; m.positionAt = Date()
    m.artwork = art.flatMap { NSImage(contentsOfFile: $0) }
    if let a = m.artwork.flatMap(MusicModel.accent(of:)) { m.accent = a }
    // a typical music spectrum: strong bass, a mid bump, falling treble, some jitter
    for ch in 0..<2 {
        m.tap.spectrum.write(ch, (0..<Spectrum.bandCount).map { i in
            let x = Float(i) / Float(Spectrum.bandCount)
            return max(0, min(1, 0.85 - 0.6 * x + 0.25 * sin(x * 14 + Float(ch)) + Float.random(in: -0.08...0.08)))
        })
    }
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
    app.run()
}
