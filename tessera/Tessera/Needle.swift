// The needle.
//
// The tonearm is drawn from a grid of renders of the same scene, the arm
// alone with its shadow: on its cradle, swung in over the record, and at
// thirty-two places along the groove, each at five heights from down to
// up, rendered by tessera/Tools/room/room.py, whose check mode prints the
// stylus height at every pose: down is the stylus on the vinyl's face, up
// is twelve millimetres above it. A song's progress is a place on the record: the groove carries the
// stylus from the lead-in to the run-out linearly in time, so the render
// for a moment of the song is the one whose stylus radius matches. Play
// drops the arm, pause lifts it where it is, a new song swings it home
// and back out, and the end of the side sets it back on the cradle. The
// moves between renders are stepped through the grid at the display's
// rate and eased, the way a cue lever moves an arm.

import Observation
import QuartzCore
import SwiftUI
import UIKit

/// The arm in the room, placed by the room over its render box.
struct NeedleView: View {
    let lead: Int
    let track: Int
    let lifts: Int
    /// Music is on.
    let playing: Bool
    /// How far into the song, 0 to 1; nil when there is no record on.
    let progress: Double?
    /// The stylus is in the groove: the platter may turn.
    var onDown: (Bool) -> Void

    @State private var driver: NeedleDriver? = nil

    var body: some View {
        Group {
            if let d = driver, let img = NeedleSprites.image(index: d.index, lift: d.lift, lead: lead, lifts: lifts) {
                Image(uiImage: img)
                    .resizable()
                    .interpolation(.high)
            } else {
                Color.clear
            }
        }
        .onAppear {
            if driver == nil { driver = NeedleDriver(lead: lead, track: track, lifts: lifts) }
            driver?.aim(playing: playing, progress: progress)
            NeedleSprites.warm(lead: lead, lifts: lifts)
        }
        .onChange(of: playing) { _, p in driver?.aim(playing: p, progress: progress) }
        .onChange(of: progress) { _, p in driver?.aim(playing: playing, progress: p) }
        .onChange(of: driver?.down ?? false, initial: true) { _, d in onDown(d) }
    }
}

/// Where the arm is and where it is going. Two continuous values, the
/// place along the grid and the height, each moved by one segment at a
/// time; the sprite is the nearest render to both.
@Observable
final class NeedleDriver {
    let lead: Int
    let track: Int
    let lifts: Int

    /// The place: 0 the cradle, `lead` the lead-in, `lead + track - 1` the run-out.
    private(set) var place: Double = 0
    /// The height: 0 down, 1 fully up.
    private(set) var height: Double = 0

    var index: Int { Int(place.rounded()) }
    var lift: Int { Int((height * Double(lifts - 1)).rounded()) }
    /// In the groove.
    var down: Bool { index >= lead && height < 0.02 }

    private var wantPlace = 0
    private var wantDown = false

    private enum Move { case raise, lower, swing(Double) }
    private struct Segment { let move: Move; let from: Double; let to: Double; let duration: CFTimeInterval }
    private var queue: [Segment] = []
    private var current: Segment? = nil
    private var startedAt: CFTimeInterval = 0
    private var link: CADisplayLink? = nil
    private var tick: Tick? = nil

    init(lead: Int, track: Int, lifts: Int) {
        self.lead = lead; self.track = track; self.lifts = lifts
    }

    deinit { link?.invalidate() }

    /// What the song asks for. Progress picks the groove position; play
    /// asks for the stylus down; no song sends the arm home.
    func aim(playing: Bool, progress: Double?) {
        let target: Int
        if let p = progress {
            target = lead + Int((min(1, max(0, p)) * Double(track - 1)).rounded())
        } else {
            target = 0
        }
        let down = playing && progress != nil
        guard target != wantPlace || down != wantDown || (current == nil && !settled(target, down)) else { return }
        wantPlace = target; wantDown = down
        plan()
    }

    private func settled(_ target: Int, _ down: Bool) -> Bool {
        index == target && (down ? height < 0.02 : height > 0.98 || target == 0 && height < 0.02)
    }

    /// The way from here to what is wanted, as segments. A stylus in the
    /// groove that is asked for the next groove position just goes there:
    /// the record carried it. Anything else lifts first.
    private func plan() {
        queue.removeAll()
        var here = index
        let up = height > 0.98, down = height < 0.02
        if wantDown && here >= lead && wantPlace >= lead && !up {
            let step = wantPlace - here
            if step > 0 && step <= 2 {
                place = Double(wantPlace); here = wantPlace          // the groove carried it
                if let c = current, case .lower = c.move { return }  // and it is on its way down there
                if current == nil && down { return }
            } else if step < 0 && step >= -2 {
                // the wall's clock wobbling, not a seek: a stylus in the groove
                // does not walk backwards for that
                wantPlace = here
                if let c = current, case .lower = c.move { return }
                if current == nil && down { return }
            }
        }
        if wantPlace == here {
            if wantDown || wantPlace == 0 {
                if !down { queue.append(Segment(move: .lower, from: height, to: 0, duration: 0.7 * height)) }
            } else if !up {
                queue.append(Segment(move: .raise, from: height, to: 1, duration: 0.5 * (1 - height)))
            }
        } else {
            if !up { queue.append(Segment(move: .raise, from: height, to: 1, duration: 0.5 * (1 - height))) }
            let steps = abs(Double(wantPlace) - place)
            queue.append(Segment(move: .swing(Double(wantPlace)), from: place, to: Double(wantPlace),
                                 duration: min(1.4, max(0.45, 0.05 * steps))))
            if wantDown || wantPlace == 0 { queue.append(Segment(move: .lower, from: 1, to: 0, duration: 0.7)) }
        }
        current = nil
        next()
    }

    private func next() {
        guard !queue.isEmpty else { current = nil; stop(); return }
        current = queue.removeFirst()
        startedAt = CACurrentMediaTime()
        start()
    }

    private func start() {
        guard link == nil else { return }
        let t = Tick { [weak self] in self?.step() }
        tick = t
        let l = CADisplayLink(target: t, selector: #selector(Tick.fire(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func stop() {
        link?.invalidate(); link = nil; tick = nil
    }

    private func step() {
        guard let seg = current else { stop(); return }
        let t = seg.duration <= 0 ? 1 : min(1, (CACurrentMediaTime() - startedAt) / seg.duration)
        let e = ease(t)
        let v = seg.from + (seg.to - seg.from) * e
        switch seg.move {
        case .raise, .lower: height = v
        case .swing: place = v
        }
        if t >= 1 { next() }
    }

    /// In and out, with the landing soft: a cue lever's fall.
    private func ease(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    /// A target for the display link that does not retain the driver.
    private final class Tick: NSObject {
        let step: () -> Void
        init(_ step: @escaping () -> Void) { self.step = step }
        @objc func fire(_ link: CADisplayLink) { step() }
    }
}

/// The renders, by place and height, decoded once each.
enum NeedleSprites {
    private static var cache: [String: UIImage] = [:]

    static func image(index: Int, lift: Int, lead: Int, lifts: Int) -> UIImage? {
        // between the cradle and the lead-in the arm is only ever up
        let l = (index > 0 && index < lead) ? lifts - 1 : lift
        // The renders count heights from down (0) to up (4), the same way
        // the driver does, and their bottom step is the stylus on the vinyl:
        // the scene that renders them puts it there and checks the height.
        let name = String(format: "needle-%02d-%d", index, l)
        if let c = cache[name] { return c }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let data = try? Data(contentsOf: url),
              let img = UIImage(data: data, scale: 3) else { return nil }
        cache[name] = img
        return img
    }

    /// The first moves, ready before they are asked for.
    static func warm(lead: Int, lifts: Int) {
        DispatchQueue.global(qos: .utility).async {
            var names: [String] = []
            for l in 0..<lifts { names.append(String(format: "needle-%02d-%d", 0, l)) }
            for i in 1..<lead { names.append(String(format: "needle-%02d-%d", i, lifts - 1)) }
            for l in 0..<lifts { names.append(String(format: "needle-%02d-%d", lead, l)) }
            let loaded: [(String, UIImage)] = names.compactMap { n in
                guard let url = Bundle.main.url(forResource: n, withExtension: "png"),
                      let data = try? Data(contentsOf: url),
                      let img = UIImage(data: data, scale: 3) else { return nil }
                return (n, img)
            }
            DispatchQueue.main.async { for (n, i) in loaded where cache[n] == nil { cache[n] = i } }
        }
    }
}
