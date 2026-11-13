import AppKit
import Combine

/// What Music is playing. Track changes arrive as Music's own notifications; the position and
/// artwork come from AppleScript. Music is never launched by this app: it's only asked while running.
@MainActor
final class MusicModel: ObservableObject {
    enum State: String { case off, stopped, paused, playing }

    @Published var state: State = .off
    @Published var title = ""
    @Published var artist = ""
    @Published var album = ""
    @Published var duration: Double = 0
    @Published var artwork: NSImage?
    /// Position when last read, and when it was read; the view extrapolates while playing.
    @Published var position: Double = 0
    @Published var positionAt = Date()
    /// A bright colour taken from the artwork, for the visualizer.
    @Published var accent = NSColor(calibratedRed: 0.55, green: 0.6, blue: 1, alpha: 1)
    let tap = AudioTap()

    private var trackKey = ""
    private var timer: Timer?
    private let sep = "\u{1F}"

    private lazy var infoScript: NSAppleScript = NSAppleScript(source: """
        tell application "Music"
          set s to player state as text
          if s is "stopped" then return s
          set t to current track
          set a to ""
          try
            set a to (album of t)
          end try
          return s & "\(sep)" & (name of t) & "\(sep)" & (artist of t) & "\(sep)" & a & "\(sep)" & (player position as text) & "\(sep)" & (duration of t as text) & "\(sep)" & (count of artworks of t)
        end tell
        """)!
    private lazy var artScript: NSAppleScript = NSAppleScript(source: """
        tell application "Music" to return raw data of artwork 1 of current track
        """)!

    func start() {
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    private var musicApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first
    }

    func refresh() {
        guard let app = musicApp else { tap.stop(); return clear(.off) }
        var err: NSDictionary?
        guard let out = infoScript.executeAndReturnError(&err).stringValue else {
            if let err { NSLog("Music info failed: %@", err) }
            return clear(.off)
        }
        let f = out.components(separatedBy: sep)
        guard f.count >= 7 else { return clear(f.first.flatMap(State.init(rawValue:)) ?? .stopped) }
        state = State(rawValue: f[0]) ?? .paused
        if state == .playing && tap.pid != app.processIdentifier { tap.start(pid: app.processIdentifier) }
        position = Self.num(f[4]); positionAt = Date()
        let key = [f[1], f[2], f[3], f[5]].joined(separator: "|")
        guard key != trackKey else { return }
        trackKey = key
        title = f[1]; artist = f[2]; album = f[3]; duration = Self.num(f[5])
        artwork = (Int(f[6]) ?? 0) > 0 ? loadArtwork() : nil
        if let a = artwork.flatMap(Self.accent(of:)) { accent = a }
    }

    /// Average colour of the artwork, pushed bright and saturated so it reads on black.
    static func accent(of img: NSImage) -> NSColor? {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let c = NSColor(calibratedRed: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
        var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
        return NSColor(calibratedHue: h, saturation: max(sat, 0.35) * 0.9 + 0.1, brightness: max(b, 0.85), alpha: 1)
    }

    private func loadArtwork() -> NSImage? {
        var err: NSDictionary?
        let d = artScript.executeAndReturnError(&err).data
        return d.isEmpty ? nil : NSImage(data: d)
    }

    private func clear(_ s: State) {
        state = s
        guard !trackKey.isEmpty else { return }
        trackKey = ""; title = ""; artist = ""; album = ""; duration = 0; position = 0; artwork = nil
    }

    /// AppleScript writes numbers with the locale's decimal mark.
    private static func num(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
}
