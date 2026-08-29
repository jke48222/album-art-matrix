// The wall on the lock screen, and in the hole at the top of the phone.
//
// Every music Live Activity looks the same: rounded artwork on the left,
// two lines of text, a thin bar. Tessera has an actual reason not to do
// that, because the thing it is reporting on is not a song, it is a wall
// with 4,096 lights in it. So the artwork slot is a grid of twelve by
// twelve lit tiles, drawn the same way the panel and the archive draw
// theirs, and it changes when the wall changes rather than when the track
// does. The progress bar is the only borrowed part, and it earns its place:
// the record's needle moves with it.

import ActivityKit
import SwiftUI
import WidgetKit

/// The reduction, as tiles. Small enough to be drawn with plain shapes at
/// every size the system asks for, including the ones a Canvas would be
/// throttled in.
struct TileField: View {
    let state: WallAttributes.ContentState
    var gap: CGFloat = 0.14          // share of a cell left dark between them

    var body: some View {
        GeometryReader { geo in
            let n = WallTile.side
            let cell = min(geo.size.width, geo.size.height) / CGFloat(n)
            let d = cell * (1 - gap)
            Canvas { ctx, _ in
                for i in 0..<(n * n) {
                    let cx = CGFloat(i % n) * cell + cell / 2
                    let cy = CGFloat(i / n) * cell + cell / 2
                    let box = CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d)
                    guard let c = state.tile(i) else { continue }
                    // An unlit emitter is not absent; it is a dark lamp, and
                    // showing it is what makes the field read as hardware.
                    let lit = c.0 + c.1 + c.2 > 0.06
                    ctx.fill(
                        Path(roundedRect: box, cornerRadius: d * 0.28),
                        with: .color(lit
                            ? Color(red: c.0, green: c.1, blue: c.2)
                            : Color.white.opacity(0.05))
                    )
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// The bar under the words. Not a capsule: a row of marks, so it belongs to
/// the same object as everything above it.
private struct NeedleRule: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let n = 32
            let cell = geo.size.width / CGFloat(n)
            let filled = Int((fraction * Double(n)).rounded())
            HStack(spacing: cell * 0.35) {
                ForEach(0..<n, id: \.self) { i in
                    Rectangle()
                        .fill(i < filled ? tint : Color.white.opacity(0.14))
                        .frame(width: cell * 0.65)
                }
            }
        }
        .frame(height: 3)
    }
}

private struct Placard: View {
    let state: WallAttributes.ContentState
    var compact = false

    private var tint: Color {
        // The brightest tile is the wall's own colour; taking it from the
        // frame means the activity is tinted by the record, not by a theme.
        var best = (0.0, Color.white)
        for i in 0..<(WallTile.side * WallTile.side) {
            guard let c = state.tile(i) else { break }
            let mx = max(c.0, c.1, c.2), mn = min(c.0, c.1, c.2)
            let score = (mx - mn) * mx
            if score > best.0 { best = (score, Color(red: c.0, green: c.1, blue: c.2)) }
        }
        return best.0 > 0.02 ? best.1 : .white
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 1 : 3) {
            Text(headline)
                .font(.system(size: compact ? 14 : 16, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if !state.artist.isEmpty {
                Text(state.artist)
                    .font(.system(size: compact ? 11 : 13))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            if let f = state.fraction {
                NeedleRule(fraction: f, tint: tint)
                    .padding(.top, compact ? 3 : 6)
            }
        }
    }

    private var headline: String {
        if state.mode == "off" { return "Asleep" }
        if !state.title.isEmpty { return state.title }
        switch state.mode {
        case "ambient": return "Lamp"
        case "clock": return "Clock"
        case "ticker": return "Lettering"
        default: return "Nothing playing"
        }
    }
}

struct WallLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WallAttributes.self) { context in
            HStack(spacing: 14) {
                TileField(state: context.state)
                    .frame(width: 62, height: 62)
                Placard(state: context.state)
                Spacer(minLength: 0)
            }
            .padding(16)
            .activityBackgroundTint(Color.black.opacity(0.55))
            .activitySystemActionForegroundColor(.white)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    TileField(state: context.state)
                        .frame(width: 54, height: 54)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Placard(state: context.state, compact: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 8)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    // Two things worth reaching for without unlocking, and
                    // nothing else. A remote control belongs in the app.
                    HStack(spacing: 10) {
                        Link(destination: URL(string: "tessera://mode/art")!) {
                            IslandKey(label: "Art", on: context.state.mode == "art")
                        }
                        Link(destination: URL(string: "tessera://mode/ambient")!) {
                            IslandKey(label: "Lamp", on: context.state.mode == "ambient")
                        }
                        Link(destination: URL(string: "tessera://mode/off")!) {
                            IslandKey(label: "Off", on: context.state.mode == "off")
                        }
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                // Four tiles from the middle of the frame: at this size the
                // grid is unreadable, but its colour is not.
                CompactMark(state: context.state)
            } compactTrailing: {
                // Text(timerInterval:) is the ONE surface ActivityKit keeps
                // advancing between updates, so the running clock lives here;
                // a percentage would freeze the moment the update landed.
                if context.state.playing, let iv = context.state.songInterval {
                    Text(timerInterval: iv, countsDown: false,
                         showsHours: false)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: 44)
                        .multilineTextAlignment(.trailing)
                } else if let f = context.state.fraction {
                    Text("\(Int(f * 100))%")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                } else {
                    EmptyView()
                }
            } minimal: {
                CompactMark(state: context.state)
            }
            .widgetURL(URL(string: "tessera://wall"))
        }
    }
}

/// Two by two, taken from the centre of the frame. The mark of the app is
/// four tiles, so this is the app's own mark wearing the record's colours.
private struct CompactMark: View {
    let state: WallAttributes.ContentState

    var body: some View {
        let n = WallTile.side
        let picks = [(n / 2 - 2, n / 2 - 2), (n / 2 + 1, n / 2 - 2),
                     (n / 2 - 2, n / 2 + 1), (n / 2 + 1, n / 2 + 1)]
        VStack(spacing: 1.5) {
            HStack(spacing: 1.5) { dot(picks[0]); dot(picks[1]) }
            HStack(spacing: 1.5) { dot(picks[2]); dot(picks[3]) }
        }
        .frame(width: 18, height: 18)
    }

    private func dot(_ p: (Int, Int)) -> some View {
        let c = state.tile(p.1 * WallTile.side + p.0) ?? (0.2, 0.2, 0.2)
        return RoundedRectangle(cornerRadius: 1)
            .fill(Color(red: c.0, green: c.1, blue: c.2))
    }
}

private struct IslandKey: View {
    let label: String
    let on: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(on ? .black : .white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(on ? Color.white : Color.white.opacity(0.13),
                        in: RoundedRectangle(cornerRadius: 7))
    }
}
