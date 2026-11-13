import AppKit
import Combine

/// A player app the display can follow. Only asked while running: never launched by this app.
struct Source {
    let name: String
    let bundleID: String
    let notification: String
    /// Returns state, or state·title·artist·album·position·duration·art, separated by `sep`.
    let info: String
    /// Music only: raw artwork data of the current track.
    let artData: String?
    /// Duration unit: Music reports seconds, Spotify milliseconds.
    let durationScale: Double

    static let sep = "\u{1F}"

    static let music = Source(
        name: "Music", bundleID: "com.apple.Music", notification: "com.apple.Music.playerInfo",
        info: """
        tell application id "com.apple.Music"
          set s to player state as text
          if s is "stopped" then return s
          set t to current track
          set a to ""
          try
            set a to (album of t)
          end try
          return s & "\(sep)" & (name of t) & "\(sep)" & (artist of t) & "\(sep)" & a & "\(sep)" & (player position as text) & "\(sep)" & (duration of t as text) & "\(sep)" & (count of artworks of t)
        end tell
        """,
        artData: """
        tell application id "com.apple.Music" to return raw data of artwork 1 of current track
        """,
        durationScale: 1)

    static let spotify = Source(
        name: "Spotify", bundleID: "com.spotify.client", notification: "com.spotify.client.PlaybackStateChanged",
        info: """
        tell application id "com.spotify.client"
          set s to player state as text
          if s is "stopped" then return s
          set t to current track
          return s & "\(sep)" & (name of t) & "\(sep)" & (artist of t) & "\(sep)" & (album of t) & "\(sep)" & (player position as text) & "\(sep)" & (duration of t as text) & "\(sep)" & (artwork url of t)
        end tell
        """,
        artData: nil,
        durationScale: 0.001)

    static let all = [music, spotify]
}

/// What's playing, from Music or Spotify: whichever is playing, else the one used last.
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
    /// The app being shown ("Music" or "Spotify").
    @Published var sourceName = ""
    let tap = AudioTap()

    private var current: Source?
    private var trackKey = ""
    private var artTries = 0
    private var timer: Timer?
    private var scripts: [String: NSAppleScript] = [:]

    func start() {
        for s in Source.all {
            DistributedNotificationCenter.default().addObserver(
                forName: .init(s.notification), object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.refresh() }
                }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    private func running(_ s: Source) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: s.bundleID).isEmpty
    }

    /// Compiled lazily, and only for a running app: compiling a script for a missing app asks the user to find it.
    private func run(_ source: String) -> NSAppleEventDescriptor? {
        let script = scripts[source] ?? NSAppleScript(source: source)!
        scripts[source] = script
        var err: NSDictionary?
        let r = script.executeAndReturnError(&err)
        if let err { NSLog("AppleScript failed: %@", err); return nil }
        return r
    }

    /// Player commands; Music and Spotify understand the same words.
    enum Command: String { case playPause = "playpause", next = "next track", previous = "previous track" }

    /// Sends a command to the player being shown.
    func send(_ c: Command) {
        guard let current, running(current) else { return }
        _ = run("tell application id \"\(current.bundleID)\" to \(c.rawValue)")
        refresh()
    }

    func refresh() {
        // Ask every running player; pick the one playing, preferring the one already shown.
        var reads: [(Source, [String])] = []
        for s in Source.all where running(s) {
            if let out = run(s.info)?.stringValue { reads.append((s, out.components(separatedBy: Source.sep))) }
        }
        let playing = reads.filter { $0.1.first == "playing" }
        let pick = playing.first { $0.0.bundleID == current?.bundleID } ?? playing.first
            ?? reads.first { $0.0.bundleID == current?.bundleID } ?? reads.first
        guard let (src, f) = pick else { tap.stop(); current = nil; return clear(.off) }
        if src.bundleID != current?.bundleID { current = src; trackKey = ""; sourceName = src.name }

        guard f.count >= 7 else { return clear(State(rawValue: f.first ?? "") ?? .stopped) }
        state = State(rawValue: f[0]) ?? .paused
        position = Self.num(f[4]); positionAt = Date()
        if state == .playing { tap.follow(bundleID: src.bundleID) }

        let key = [src.bundleID, f[1], f[2], f[3]].joined(separator: "|")
        if key != trackKey {
            trackKey = key; artTries = 0
            title = f[1]; artist = f[2]; album = f[3]; duration = Self.num(f[5]) * src.durationScale
            artwork = nil
        }
        if artwork == nil && artTries < 3 { artTries += 1; loadArtwork(src, field: f[6], key: key) }
    }

    /// Music: embedded artwork, else Apple's iTunes Search (streamed songs often have none).
    /// Spotify: the cover URL it reports.
    private func loadArtwork(_ src: Source, field: String, key: String) {
        if let s = src.artData, (Int(field) ?? 0) > 0, let d = run(s)?.data, !d.isEmpty, let img = NSImage(data: d) {
            return setArtwork(img)
        }
        let artist = self.artist, album = self.album, title = self.title
        Task {
            var url = src.artData == nil ? URL(string: field) : nil
            if url == nil { url = await Self.itunesArtworkURL(artist: artist, album: album.isEmpty ? title : album) }
            guard let url, let (d, _) = try? await URLSession.shared.data(from: url), let img = NSImage(data: d) else { return }
            if self.trackKey == key { self.setArtwork(img) }
        }
    }

    private func setArtwork(_ img: NSImage) {
        artwork = img
        if let a = Self.accent(of: img) { accent = a }
    }

    private static func itunesArtworkURL(artist: String, album: String) async -> URL? {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [.init(name: "term", value: "\(artist) \(album)"), .init(name: "entity", value: "album"), .init(name: "limit", value: "1")]
        guard let u = c.url, let (d, _) = try? await URLSession.shared.data(from: u),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let r = (j["results"] as? [[String: Any]])?.first, let small = r["artworkUrl100"] as? String else { return nil }
        return URL(string: small.replacingOccurrences(of: "100x100bb", with: "1000x1000bb"))
    }

    private func clear(_ s: State) {
        state = s
        guard !trackKey.isEmpty else { return }
        trackKey = ""; title = ""; artist = ""; album = ""; duration = 0; position = 0; artwork = nil
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

    /// AppleScript writes numbers with the locale's decimal mark.
    private static func num(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
}
