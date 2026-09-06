// The way in to the record, and the way out.
//
// Tap the record and the camera leaves the seat, rises over the deck and
// tilts down onto the record as the cover swings up: a short film, rendered
// from the room's own scene, from exactly where the still stands to exactly
// where the overhead still stands. The wall and the record are holes in it,
// drawn live through the film's own track, so the wall keeps playing and
// the pressing is the song's. The same film backwards is the way out.
//
// The stage stays mounted the whole time the room is up, its six players
// loaded and prerolled, so a tap starts the film on the next frame instead
// of after a cold load; and it cuts hard at both ends, where its first and
// last frames are the still they replace, with only a blink of a fade.

import AVFoundation
import OSLog
import SwiftUI

let diveLog = Logger(subsystem: "com.jalenedusei.tessera", category: "dive")

struct DiveTrack: Decodable {
    var fps: Double
    var frames: [IntroTrack.Frame]

    static let loaded: DiveTrack? = {
        guard let url = Bundle.main.url(forResource: "room-dive-track", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DiveTrack.self, from: data)
    }()

    /// Looked up once: the room's body asks on every evaluation.
    static let available: Bool =
        loaded != nil && Bundle.main.url(forResource: "room-dive", withExtension: "mov") != nil
            && Bundle.main.url(forResource: "room-dive-out", withExtension: "mov") != nil
}

/// The films, both ways, loaded once and kept ready.
@MainActor
final class DiveFilms {
    struct Reel {
        let main: AVPlayer
        let light: AVPlayer?
        let badge: AVPlayer?
        var all: [AVPlayer] { [main, light, badge].compactMap { $0 } }
    }
    private(set) var way: Reel? = nil       // in
    private(set) var back: Reel? = nil      // out
    private(set) var outFrames: [IntroTrack.Frame] = []

    func warm() {
        guard way == nil else { return }
        way = reel(suffix: ""); back = reel(suffix: "-out")
        outFrames = Array((DiveTrack.loaded?.frames ?? []).reversed())
        for r in [way, back].compactMap({ $0 }) { prime(r.all) }
    }

    func reel(out: Bool) -> Reel? { out ? back : way }

    func start(out: Bool) {
        guard let r = reel(out: out) else { return }
        startFilmsTogether(r.all)
    }

    /// Back to the first frame, a beat after the reel has gone from view: a
    /// seek while its layer still shows would flash that frame.
    func rewind(out: Bool) {
        guard let r = reel(out: out) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            for p in r.all {
                p.pause()
                p.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in p.preroll(atRate: 1) { _ in } }
            }
        }
    }

    private func reel(suffix: String) -> Reel? {
        func player(_ name: String) -> AVPlayer? {
            guard let url = Bundle.main.url(forResource: name + suffix, withExtension: "mov") else { return nil }
            let p = AVPlayer(url: url)
            p.isMuted = true
            p.actionAtItemEnd = .pause
            p.automaticallyWaitsToMinimizeStalling = false
            return p
        }
        guard let main = player("room-dive") else { return nil }
        return Reel(main: main, light: player("room-dive-light"), badge: player("room-dive-badge"))
    }

    /// Once ready, load the first frames so a start is instant.
    private func prime(_ players: [AVPlayer]) {
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, players.contains(where: { $0.currentItem?.status == .unknown }) {
                try? await Task.sleep(for: .milliseconds(30))
            }
            for p in players where p.currentItem?.status == .readyToPlay { p.preroll(atRate: 1) { _ in } }
        }
    }
}

struct DiveFilm: View {
    let light: Lighting
    let duty: Double
    /// Where the room's picture sits on the screen; the film sits there too.
    let fit: CGRect
    /// The song's pressing, and the angle it stopped at.
    var pressing: UIImage? = nil
    var angle: Double = 0
    /// Which way to go: nil is idle, false the way in, true the way out.
    let out: Bool?
    /// Called as the film's last blink of fade begins: what is under it is the
    /// scene now.
    var onDone: () -> Void

    // Warmed on appear, not here: a State's initial value is built every
    // time the room's body makes this view, ten times a second while the
    // stand-in ticks, and warming here made six players a render.
    @State private var films = DiveFilms()
    @State private var running: Bool? = nil
    @State private var handedOver = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let track = DiveTrack.loaded, let way = films.reel(out: false), let back = films.reel(out: true) {
                    // both reels stay mounted, at nothing, so their layers are warm
                    reel(way, frames: track.frames, fps: track.fps, active: running == false, geo: geo.size)
                    reel(back, frames: films.outFrames, fps: track.fps, active: running == true, geo: geo.size)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear {
            films.warm()
            if let out { begin(out) }
        }
        .onChange(of: out) { _, new in
            if let new { begin(new) }
        }
    }

    private func begin(_ way: Bool) {
        handedOver = false
        running = way
        films.start(out: way)
        diveLog.notice("begin out=\(way) ready=\(films.reel(out: way)?.all.map { $0.currentItem?.status == .readyToPlay } ?? [])")
    }

    @ViewBuilder
    private func reel(_ r: DiveFilms.Reel, frames: [IntroTrack.Frame], fps: Double, active: Bool, geo: CGSize) -> some View {
        let length = Double(frames.count) / fps
        TimelineView(.animation(paused: !active)) { tl in
            let t = r.main.currentTime().seconds
            let now = t.isFinite ? t : 0
            let i = max(0, min(frames.count - 1, Int(now * fps)))
            let f = frames.isEmpty ? nil : frames[i]
            // opaque from its first frame to its last: both are the stills they
            // stand between, so the cuts land on identical pictures
            let played = now >= length - 0.005 || (now > 0.2 && r.main.rate == 0)
            let quad = (f?.face ?? []).map { CGPoint(x: fit.origin.x + fit.width * $0[0], y: fit.origin.y + fit.height * $0[1]) }
            ZStack(alignment: .topLeading) {
                if active, let rq = f?.record, let pressing {
                    RecordView(image: pressing, quad: rq.map { CGPoint(x: fit.origin.x + fit.width * $0[0], y: fit.origin.y + fit.height * $0[1]) }, angle: angle, blend: .normal)
                        .frame(width: geo.width, height: geo.height)
                }
                FilmView(player: r.main)
                    .frame(width: fit.width, height: fit.height)
                    .offset(x: fit.origin.x, y: fit.origin.y)
                if let lp = r.light {
                    FilmView(player: lp)
                        .frame(width: fit.width, height: fit.height)
                        .colorMultiply(light.steadyAccent)
                        .blendMode(.screen)
                        .opacity(min(1, 1.1 * light.room))
                        .offset(x: fit.origin.x, y: fit.origin.y)
                }
                // the wall, through its hole, over the light pass, while it is in shot
                if active, quad.count == 4 {
                    WarpedPanel(px: light.reading.px, duty: duty, quad: quad)
                        .frame(width: geo.width, height: geo.height)
                }
                if let bp = r.badge {
                    FilmView(player: bp)
                        .frame(width: fit.width, height: fit.height)
                        .colorMultiply(light.steadyAccent)
                        .offset(x: fit.origin.x, y: fit.origin.y)
                }
                // The first frames of the way in, and the last of the way out,
                // have the cover closed over the disc; the film's first frames
                // came up with the disc dark for a few frames before the hole
                // showed the pressing through the glass. So at the cuts the
                // pressing is drawn over the film too, and fades as the cover
                // clears: the cut lands on the picture the still had.
                if active, let rq = f?.record, let pressing {
                    let isOut = r.main === films.reel(out: true)?.main
                    let closed = isOut ? Double(frames.count - 1 - i) : Double(i)
                    let cap = max(0, 1 - closed / 8)
                    if cap > 0 {
                        RecordView(image: pressing, quad: rq.map { CGPoint(x: fit.origin.x + fit.width * $0[0], y: fit.origin.y + fit.height * $0[1]) }, angle: angle, blend: .normal)
                            .frame(width: geo.width, height: geo.height)
                            .opacity(cap)
                    }
                }
            }
            .frame(width: geo.width, height: geo.height, alignment: .topLeading)
            .opacity(active && !played ? 1 : 0)
            .onChange(of: active && played) { _, over in
                // played out: what is under it is the scene; back to idle, rewound for next time
                diveLog.notice("played out=\(r.main === films.reel(out: true)?.main) now=\(now) rate=\(r.main.rate) handedOver=\(handedOver)")
                guard over, !handedOver else { return }
                handedOver = true
                running = nil
                films.rewind(out: r.main === films.reel(out: true)?.main)
                onDone()
            }
        }
    }
}
