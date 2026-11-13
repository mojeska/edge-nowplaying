import SwiftUI

/// Full-screen layout for a 2560×720 strip: artwork left, track info centre, clock right.
struct NowPlayingView: View {
    @ObservedObject var music: MusicModel
    /// Off hides the clock and date beside the song; the idle screen keeps its clock.
    @AppStorage("showClock") private var showClock = true
    /// Off hides the next song (only known for a Music playlist in order).
    @AppStorage("showNext") private var showNext = true

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let pad = h * 0.08
            ZStack {
                background
                if music.state == .off || music.state == .stopped || music.title.isEmpty {
                    idle(h: h)
                } else {
                    WaveView(spectrum: music.tap.spectrum, color: Color(nsColor: music.accent),
                             active: music.state == .playing, fade: h * 0.035) {
                        playing(h: h, pad: pad)
                    }
                    playing(h: h, pad: pad)
                }
            }
            .frame(width: geo.size.width, height: h)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }

    private func playing(h: CGFloat, pad: CGFloat) -> some View {
        HStack(spacing: pad) {
            art(side: h - 2 * pad)
            // The progress bar runs under the song info and the clock column, to the right edge.
            VStack(spacing: h * 0.03) {
                HStack(spacing: pad) {
                    info(h: h).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    let next = showNext && !music.nextTitle.isEmpty
                    if showClock || next {
                        // Clock centred in the space above the bar; Up Next at the bottom, just above it.
                        ZStack(alignment: .bottomTrailing) {
                            if showClock {
                                ClockView(size: h * 0.12, dateSize: h * 0.05)
                                    .frame(maxHeight: .infinity)
                            }
                            if next { upNext(h: h) }
                        }
                        .frame(width: h * 0.75, alignment: .trailing)
                    }
                }
                ProgressRow(music: music, h: h)
            }
            .padding(.vertical, h * 0.02)
        }
        .padding(pad)
    }

    private var background: some View {
        ZStack {
            Color.black.overlay {
                if let img = music.artwork {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                        .blur(radius: 80).opacity(0.55)
                }
            }
            .clipped()
            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.6)],
                           startPoint: .leading, endPoint: .trailing)
        }
        .animation(.easeInOut(duration: 0.8), value: music.title)
    }

    private func art(side: CGFloat) -> some View {
        Group {
            if let img = music.artwork {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "music.note").font(.system(size: 160, weight: .light))
                        .foregroundStyle(Color(white: 0.4))
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
    }

    private func info(h: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: h * 0.025) {
            HStack(spacing: 10) {
                Image(systemName: music.state == .playing ? "play.fill" : "pause.fill")
                Text(music.state == .playing ? "NOW PLAYING" : "PAUSED")
            }
            .font(.system(size: h * 0.04, weight: .semibold)).tracking(3)
            .foregroundStyle(Color(white: 0.55))
            Text(music.title)
                .font(.system(size: h * 0.12, weight: .bold))
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(music.artist)
                .font(.system(size: h * 0.075, weight: .medium))
                .foregroundStyle(Color(white: 0.85)).lineLimit(1)
            if !music.album.isEmpty {
                Text(music.album)
                    .font(.system(size: h * 0.055))
                    .foregroundStyle(Color(white: 0.55)).lineLimit(1)
            }
        }
        .foregroundStyle(.white)
    }

    private func upNext(h: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: h * 0.012) {
            Text("UP NEXT")
                .font(.system(size: h * 0.035, weight: .semibold)).tracking(3)
                .foregroundStyle(Color(white: 0.55))
            Text(music.nextTitle)
                .font(.system(size: h * 0.055, weight: .semibold))
                .foregroundStyle(.white).lineLimit(1)
            Text(music.nextArtist)
                .font(.system(size: h * 0.045))
                .foregroundStyle(Color(white: 0.6)).lineLimit(1)
        }
    }

    private func idle(h: CGFloat) -> some View {
        VStack(spacing: h * 0.04) {
            ClockView(size: h * 0.3, dateSize: h * 0.07, centred: true)
            Text(music.state == .off ? "Music isn't open" : "Nothing playing")
                .font(.system(size: h * 0.05)).foregroundStyle(Color(white: 0.45))
        }
        .foregroundStyle(.white)
    }
}

/// Progress bar plus elapsed and remaining time, extrapolated between Music reads.
struct ProgressRow: View {
    @ObservedObject var music: MusicModel
    /// Off hides the clock and date beside the song; the idle screen keeps its clock.
    @AppStorage("showClock") private var showClock = true
    /// Off hides the next song (only known for a Music playlist in order).
    @AppStorage("showNext") private var showNext = true
    let h: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
            let pos = current(at: ctx.date)
            let frac = music.duration > 0 ? min(max(pos / music.duration, 0), 1) : 0
            VStack(spacing: h * 0.02) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(white: 0.22))
                        Capsule().fill(Color(white: 0.9)).frame(width: g.size.width * frac)
                    }
                }
                .frame(height: h * 0.018)
                HStack {
                    Text(Self.fmt(pos))
                    Spacer()
                    Text("-" + Self.fmt(max(music.duration - pos, 0)))
                }
                .font(.system(size: h * 0.045, weight: .medium).monospacedDigit())
                .foregroundStyle(Color(white: 0.6))
            }
        }
    }

    private func current(at now: Date) -> Double {
        guard music.state == .playing else { return music.position }
        return min(music.position + now.timeIntervalSince(music.positionAt), music.duration)
    }

    static func fmt(_ s: Double) -> String {
        let t = Int(s.rounded(.down))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }
}

struct ClockView: View {
    let size: CGFloat
    let dateSize: CGFloat
    var centred = false

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            VStack(alignment: centred ? .center : .trailing, spacing: 4) {
                Text(ctx.date, format: .dateTime.hour().minute())
                    .font(.system(size: size, weight: .light).monospacedDigit())
                Text(ctx.date, format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(.system(size: dateSize))
                    .foregroundStyle(Color(white: 0.55))
            }
            .foregroundStyle(.white)
        }
    }
}

/// Spectrum drawn as two crisp lines, left channel bright and right channel faint (bass on the left, treble on the right), from the right edge of
/// the artwork to the right edge of the screen.
/// `cutout` is the content drawn on top; the line fades out in a soft halo around it.
struct WaveView<Cutout: View>: View {
    let spectrum: Spectrum
    let color: Color
    let active: Bool
    let fade: CGFloat
    @ViewBuilder let cutout: () -> Cutout

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 40)) { tl in
            // Canvas only repaints when its inputs change, so it has to read the timeline's date.
            let frame = tl.date
            Canvas { ctx, size in
                _ = frame
                if !active { spectrum.decay() }
                let left = spectrum.read(0).map(CGFloat.init)
                let right = spectrum.read(1).map(CGFloat.init)
                guard max(left.max() ?? 0, right.max() ?? 0) > 0.01 else { return }
                // Artwork is a square inset by `pad` on a strip `height` tall, so it ends at x = height.
                let area = CGRect(x: size.height, y: 0, width: size.width - size.height, height: size.height)
                stroke(right, scale: 0.8, in: area, ctx: ctx, opacity: 0.3, width: 2)
                stroke(left, scale: 1.0, in: area, ctx: ctx, opacity: 0.6, width: 3)
                if let sym = ctx.resolveSymbol(id: 0) {
                    var c = ctx
                    c.blendMode = .destinationOut
                    c.drawLayer { l in
                        // Thicken the content (copies around a circle), then soften the edge.
                        l.addFilter(.blur(radius: fade * 0.6))
                        let r = CGRect(origin: .zero, size: size)
                        l.draw(sym, in: r)
                        for k in 0..<12 {
                            let a = Double(k) / 12 * 2 * .pi
                            l.draw(sym, in: r.offsetBy(dx: cos(a) * fade, dy: sin(a) * fade))
                        }
                    }
                }
            } symbols: {
                cutout().tag(0)
            }
            .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
    }

    private func stroke(_ v: [CGFloat], scale: CGFloat, in r: CGRect, ctx: GraphicsContext, opacity: Double, width: CGFloat) {
        guard v.count > 1 else { return }
        let maxH = r.height * 0.62 * scale
        let base = r.maxY - r.height * 0.04
        let step = r.width / CGFloat(v.count - 1)
        let pts = v.enumerated().map { CGPoint(x: r.minX + CGFloat($0.offset) * step, y: base - $0.element * maxH) }
        var path = Path()
        path.move(to: pts[0])
        for i in 1..<pts.count {     // smooth curve through the midpoints
            let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)
            path.addQuadCurve(to: mid, control: pts[i - 1])
        }
        path.addLine(to: pts[pts.count - 1])
        ctx.stroke(path, with: .color(color.opacity(opacity)),
                   style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
}
