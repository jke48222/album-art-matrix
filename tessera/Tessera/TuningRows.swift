// The rows of Panel tuning: a tick rail for numbers, a native switch for
// on and off, equal capsules for a handful of whole numbers, and a read-only
// fact. They draw what they are given and report what the finger did. The
// page decides what reaches the wall.

import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Panel tuning's own quiet palette. Stone reads about 11:1 on the ground,
/// and the ground is dark enough that Ink.faint (4.52:1) and Ink.signal
/// (4.58:1) still clear 4.5:1 for the small type that carries meaning.
enum TuningInk {
    static let stone = Color(hex: 0xCFC7B6)
    static let ground = Color(hex: 0x131210)
    static let well = Color(hex: 0x0C0E0D)
    /// Text on a stone fill.
    static let onStone = Color(hex: 0x1D1B17)
    /// The chosen tab, as Guests chooses its kind.
    static let chosen = Color(hex: 0x343027)
    static let rule = Color(hex: 0xCFC7B6).opacity(0.1)
}

/// Launch flags take the panel down for a few seconds. Said once, in the
/// row's own title line, before anyone touches it.
struct RestartBadge: View {
    var body: some View {
        Text("RESTARTS PANEL").font(.machine(9)).foregroundStyle(Ink.faint)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 7).padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(Ink.hairline, lineWidth: 1))
            .accessibilityLabel("Restarts the panel")
    }
}

/// A launch flag's value while it is being chosen and has not been sent.
struct PendingPill: View {
    let text: String
    var body: some View {
        Text(text).font(.machine(13)).foregroundStyle(TuningInk.stone)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 9).padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(TuningInk.stone.opacity(0.55), lineWidth: 1))
            .accessibilityLabel("Not sent yet, \(text)")
    }
}

/// What a rail reports. began and ended bracket a horizontal drag. A drag
/// that turns out to be a scroll reports nothing at all.
struct TuningRailActions {
    var began: () -> Void = {}
    var moved: (Double) -> Void = { _ in }
    var ended: (Double) -> Void = { _ in }
    var cancelled: () -> Void = {}
    /// A VoiceOver swipe, one step. The page commits a moment later.
    var adjusted: (Double) -> Void = { _ in }
}

/// A tick rail in the SpeedTicker language: a hairline, the default as a
/// faint tick, the value as a stone marker, the ends labelled.
///
/// It sits among thirty-odd rails on a long scroll page, so a touch alone
/// never changes anything. The rail takes a drag only once it has moved
/// 10 pt and more across than down. Anything else is left to the scroll.
struct TuningRail: View {
    @Environment(\.isEnabled) private var enabled
    let knob: Knob
    /// The value to draw: the finger's while it is down, else the wall's.
    let value: Double
    let defaultValue: Double?
    let spoken: String
    var actions: TuningRailActions

    @State private var width: CGFloat = 1
    @State private var engaged = false
    @State private var last: Double?
    @State private var onDefault = false

    private var span: Double { max(knob.max - knob.min, knob.step) }

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .leading) {
                Rectangle().fill(Ink.hairline).frame(height: 1)
                if let d = defaultValue {
                    let here = abs(d - value) < knob.step / 2
                    Rectangle().fill(here ? TuningInk.stone : Ink.faint)
                        .frame(width: 1.5, height: 12)
                        .offset(x: x(d) - 0.75)
                }
                Rectangle().fill(enabled ? TuningInk.stone : Ink.dim)
                    .frame(width: 2, height: 20)
                    .offset(x: x(value) - 1)
            }
            .frame(height: 26)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = max(1, $0) }
            HStack {
                Text(TuningStore.format(knob.min, knob: knob))
                Spacer(minLength: 8)
                Text(TuningStore.format(knob.max, knob: knob))
            }
            // Scaled rather than cut or broken at the largest sizes.
            .font(.machine(9)).foregroundStyle(Ink.faint).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
        // A UIKit pan that fails as soon as the finger goes more down than
        // across, so a vertical swipe that starts here scrolls the page.
        // The SwiftUI DragGesture this replaces, even as a
        // simultaneousGesture, kept the scroll from starting on or just
        // beside any rail, which left most of the page unscrollable.
        .gesture(RailPan(enabled: enabled, began: began, moved: moved, ended: ended, cancelled: cancelled))
        .accessibilityElement()
        .accessibilityLabel(knob.title)
        .accessibilityValue(spoken)
        .accessibilityAdjustableAction { direction in
            guard enabled else { return }
            // The step math lives in the store, where the store's runner
            // checks its clamp and rounding.
            actions.adjusted(TuningStore.stepped(value, up: direction == .increment, knob: knob))
        }
    }

    /// The pan has moved 10 pt, more across than down.
    private func began() {
        guard enabled else { return }
        engaged = true
        Taps.warm()
        actions.began()
    }

    /// The finger's x in the rail's own space.
    private func moved(_ x: CGFloat) {
        guard enabled, engaged else { return }
        let (v, snapped) = pick(x)
        if snapped && !onDefault {
            Taps.detent(intensity: 0.6)      // clicking into the default
        } else if v != last {
            // Quieter at the low end, like the room it describes.
            Taps.detent(intensity: 0.2 + 0.25 * fraction(v))
        }
        onDefault = snapped
        if v != last { last = v; actions.moved(v) }
    }

    private func ended() {
        let finished = engaged ? last : nil
        reset()
        if let finished { actions.ended(finished) }
    }

    /// Taken by the system or another gesture: nothing is committed for a
    /// drag nobody finished.
    private func cancelled() {
        let was = engaged
        reset()
        if was { actions.cancelled() }
    }

    private func reset() { engaged = false; last = nil; onDefault = false }

    /// The value under the finger, stepped, and pulled onto the default
    /// within 2% of the range.
    private func pick(_ x: CGFloat) -> (Double, Bool) {
        let raw = knob.min + span * Double(min(1, max(0, x / width)))
        if let d = defaultValue, abs(raw - d) <= 0.02 * span { return (d, true) }
        return (TuningStore.clamped(knob.min + ((raw - knob.min) / knob.step).rounded() * knob.step, knob: knob), false)
    }

    private func fraction(_ v: Double) -> Double { min(1, max(0, (v - knob.min) / span)) }
    private func x(_ v: Double) -> CGFloat { CGFloat(fraction(v)) * width }
}

/// The rail's drag. See RailPanRecognizer for the direction rule.
private struct RailPan: UIGestureRecognizerRepresentable {
    var enabled: Bool
    var began: () -> Void
    var moved: (CGFloat) -> Void
    var ended: () -> Void
    var cancelled: () -> Void

    func makeUIGestureRecognizer(context: Context) -> RailPanRecognizer { RailPanRecognizer() }

    func updateUIGestureRecognizer(_ recognizer: RailPanRecognizer, context: Context) {
        recognizer.isEnabled = enabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: RailPanRecognizer, context: Context) {
        switch recognizer.state {
        case .began:
            began()
            moved(context.converter.localLocation.x)
        case .changed: moved(context.converter.localLocation.x)
        case .ended: ended()
        case .cancelled, .failed: cancelled()
        default: break
        }
    }
}

/// A pan that decides its direction once the finger has moved 10 pt, and
/// fails when that move is more down than across. Until then it lets no
/// move reach UIPanGestureRecognizer, which would otherwise begin on a few
/// points of vertical travel. A failed pan leaves the touch to the page's
/// scroll view.
private final class RailPanRecognizer: UIPanGestureRecognizer {
    private var origin: CGPoint?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if origin == nil { origin = touches.first?.location(in: view) }
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible, let origin, let point = touches.first?.location(in: view) {
            let dx = abs(point.x - origin.x), dy = abs(point.y - origin.y)
            if hypot(dx, dy) < 10 { return }
            if dy >= dx { state = .failed; return }
        }
        super.touchesMoved(touches, with: event)
    }

    override func reset() {
        super.reset()
        origin = nil
    }
}

/// Everything a row needs to know about its knob's state.
struct TuningRowState {
    var shown: Double
    var defaultValue: Double?
    /// The wall's value is off its default.
    var changed: Bool
    /// The row greys its title: the knob does nothing on this wall now.
    var greyed: Bool
    /// A finger is on this rail.
    var holding: Bool
    /// A launch flag's value is chosen and not yet sent.
    var pending: Bool
    var note: String
    var applies: String?
    var problem: String?
}

/// A number the wall describes: title, value, the default when moved off
/// it, the rail, and an always-visible note.
struct TuningSliderRow: View {
    @Environment(\.dynamicTypeSize) private var type
    @Environment(\.isEnabled) private var enabled
    let knob: Knob
    let state: TuningRowState
    var useDefault: () -> Void
    var actions: TuningRailActions

    private var valueText: String { TuningStore.format(state.shown, knob: knob) }
    private var defaultText: String? { state.defaultValue.map { "Default " + TuningStore.format($0, knob: knob) } }
    private var ax: Bool { type.isAccessibilitySize }
    /// From xxLarge the badge and a value such as "64 planes" take about
    /// 260 pt of a 327 pt row, which would leave the title too little to
    /// hold "Smallest" or "depth" whole. Each goes on its own line instead.
    private var stacked: Bool { type >= .xxLarge }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if stacked { stackedHeader } else { header }
            TuningRail(knob: knob, value: state.shown, defaultValue: state.defaultValue,
                       spoken: TuningStore.spoken(state.shown, knob: knob), actions: actions)
                .accessibilityIdentifier("tuning.knob.\(knob.name)")
            if state.holding && knob.restart {
                Text("Let go to apply. The panel restarts for a few seconds.")
                    .font(.ui(type.isAccessibilitySize ? 10 : 12)).foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TuningRowFooter(knob: knob, state: state)
            if type.isAccessibilitySize, state.changed { largeDefaultButton }
        }
        .padding(.vertical, 14)
    }

    /// Title, badge and value on one line when all three fit whole. When
    /// they do not, the badge goes on its own line under the title, as the
    /// larger sizes do, rather than squeezing the title onto two lines.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    title.lineLimit(1).fixedSize()
                    if knob.restart { RestartBadge() }
                    Spacer(minLength: 8)
                    value
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        title.fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        value
                    }
                    if knob.restart { RestartBadge() }
                }
            }
            if state.changed, let defaultText { defaultLine(defaultText) }
        }
    }

    private var title: some View {
        Text(knob.title).font(.ui(15, .semibold)).foregroundStyle(state.greyed ? Ink.dim : Ink.ink)
    }

    @ViewBuilder private var value: some View {
        if state.pending { PendingPill(text: valueText) }
        else { Text(valueText).font(.machine(15)).foregroundStyle(TuningInk.stone).lineLimit(1).fixedSize() }
    }

    private func defaultLine(_ text: String) -> some View {
        HStack(alignment: .center) {
            Text(text).font(.machine(10)).foregroundStyle(Ink.faint)
            Spacer(minLength: 8)
            TuningDefaultLink(knob: knob, action: useDefault)
        }
    }

    /// Title, badge, value and default, one to a line. The accessibility
    /// sizes use smaller base sizes, which Dynamic Type then scales up, and
    /// put Use default on its own full-width line under the footer.
    private var stackedHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(knob.title).font(.ui(ax ? 12 : 15, .semibold)).foregroundStyle(state.greyed ? Ink.dim : Ink.ink)
                .fixedSize(horizontal: false, vertical: true)
            if knob.restart { RestartBadge() }
            if state.pending { PendingPill(text: valueText) }
            else { Text(valueText).font(.machine(ax ? 10 : 15)).foregroundStyle(TuningInk.stone) }
            if state.changed, let defaultText {
                if ax { Text(defaultText).font(.ui(10)).foregroundStyle(Ink.dim) }
                else { defaultLine(defaultText) }
            }
        }
    }

    private var largeDefaultButton: some View { TuningDefaultLink(knob: knob, action: useDefault) }
}

/// The title with its badge, wrapping only between words.
struct TuningRowTitle: View {
    @Environment(\.dynamicTypeSize) private var type
    let knob: Knob
    let greyed: Bool
    var body: some View {
        // Side by side when the title fits whole on one line beside the
        // badge. Otherwise, and always from xxLarge where the badge alone
        // is about a third of the row, the badge goes under the title,
        // which keeps the width to wrap between words.
        if type >= .xxLarge || !knob.restart {
            stacked
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    title.lineLimit(1).fixedSize()
                    RestartBadge()
                }
                stacked
            }
        }
    }

    private var title: some View {
        Text(knob.title).font(.ui(15, .semibold)).foregroundStyle(greyed ? Ink.dim : Ink.ink)
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 6) {
            title.fixedSize(horizontal: false, vertical: true)
            if knob.restart { RestartBadge() }
        }
    }
}

/// A quiet text button. The 44 pt frame is inside the label, so the whole
/// row is the target, not just the words. Turned off it switches to
/// Ink.dim (5.7:1) instead of fading.
struct TuningTextButton: View {
    @Environment(\.isEnabled) private var enabled
    let title: String
    var tint: Color = TuningInk.stone
    var size: CGFloat = 15
    var fullWidth = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.ui(size, .semibold)).foregroundStyle(enabled ? tint : Ink.dim)
                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(CalibrationLinkStyle())
    }
}

/// "Use default". Full width on its own line at accessibility sizes.
struct TuningDefaultLink: View {
    @Environment(\.dynamicTypeSize) private var type
    let knob: Knob
    var action: () -> Void
    var body: some View {
        TuningTextButton(title: "Use default", size: type.isAccessibilitySize ? 12 : 13,
                         fullWidth: type.isAccessibilitySize, action: action)
            .accessibilityLabel("Use default for \(knob.title)")
            .accessibilityIdentifier("tuning.knob.\(knob.name).default")
    }
}

/// Where the change shows, the note (or why the knob is idle), and what
/// went wrong with the last write.
struct TuningRowFooter: View {
    @Environment(\.dynamicTypeSize) private var type
    let knob: Knob
    let state: TuningRowState
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let applies = state.applies {
                Text(applies).font(.ui(type.isAccessibilitySize ? 10 : 12)).foregroundStyle(Ink.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !state.note.isEmpty {
                Text(state.note).font(.ui(type.isAccessibilitySize ? 10 : 12)).foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem = state.problem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(.ui(type.isAccessibilitySize ? 11 : 13)).foregroundStyle(Ink.signal)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("tuning.knob.\(knob.name).problem")
            }
        }
    }
}

/// On and off, with a native switch.
struct TuningToggleRow: View {
    @Environment(\.dynamicTypeSize) private var type
    let knob: Knob
    let state: TuningRowState
    var set: (Bool) -> Void

    private var ax: Bool { type.isAccessibilitySize }
    private var defaultText: String? { state.defaultValue.map { "Default " + TuningStore.format($0, knob: knob) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { state.shown > 0.5 }, set: set)) {
                VStack(alignment: .leading, spacing: 6) {
                    if ax {
                        Text(knob.title).font(.ui(12, .semibold)).foregroundStyle(state.greyed ? Ink.dim : Ink.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        TuningRowTitle(knob: knob, greyed: state.greyed)
                        if state.changed, let defaultText {
                            Text(defaultText).font(.machine(10)).foregroundStyle(Ink.faint)
                        }
                    }
                }
            }
            .tint(TuningInk.stone)
            .frame(minHeight: 44)
            .accessibilityLabel(knob.title)
            .accessibilityHint(knob.restart ? "Restarts the panel" : "")
            .accessibilityIdentifier("tuning.knob.\(knob.name)")
            // At accessibility sizes the switch leaves its label about
            // 268 pt, less than the badge's one line (about 288 pt at AX5),
            // so the badge and the Default line sit under the switch on the
            // full row. The switch's hint already says it restarts.
            if ax {
                if knob.restart { RestartBadge().accessibilityHidden(true) }
                if state.changed, let defaultText {
                    Text(defaultText).font(.ui(10)).foregroundStyle(Ink.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            TuningRowFooter(knob: knob, state: state)
        }
        .padding(.vertical, 14)
    }
}

/// A handful of whole numbers as equal capsules, four to a row at every
/// size, so each keeps a 44 pt target.
struct TuningChoiceRow: View {
    @Environment(\.dynamicTypeSize) private var type
    @Environment(\.isEnabled) private var enabled
    let knob: Knob
    let state: TuningRowState
    var choose: (Double) -> Void
    var useDefault: () -> Void

    private var choices: [Int] { Array(stride(from: Int(knob.min), through: Int(knob.max), by: max(1, Int(knob.step)))) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if type.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(knob.title).font(.ui(12, .semibold)).foregroundStyle(state.greyed ? Ink.dim : Ink.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        if knob.restart { RestartBadge() }
                    }
                } else {
                    TuningRowTitle(knob: knob, greyed: state.greyed)
                }
                Spacer(minLength: 8)
                if state.changed, let d = state.defaultValue, !type.isAccessibilitySize {
                    Text("Default " + TuningStore.format(d, knob: knob)).font(.machine(10)).foregroundStyle(Ink.faint)
                }
            }
            // Plain rows of four, not a lazy grid. A lazy grid makes its
            // cells only near the visible part of the scroll view, and this
            // row sits far down the page, so its choices would be missing
            // from the accessibility tree until scrolled to. Eight cells
            // gain nothing from laziness.
            VStack(spacing: 8) {
                ForEach(Array(stride(from: 0, to: choices.count, by: 4)), id: \.self) { start in
                    HStack(spacing: 8) {
                        ForEach(start..<(start + 4), id: \.self) { i in
                            if i < choices.count {
                                choiceButton(choices[i])
                            } else {
                                // Keeps a short last row on the same columns.
                                Color.clear.frame(maxWidth: .infinity, minHeight: 44).accessibilityHidden(true)
                            }
                        }
                    }
                }
            }
            if state.changed, type.isAccessibilitySize, let d = state.defaultValue {
                Text("Default " + TuningStore.format(d, knob: knob)).font(.ui(10)).foregroundStyle(Ink.dim)
            }
            TuningRowFooter(knob: knob, state: state)
            if state.changed { TuningDefaultLink(knob: knob, action: useDefault) }
        }
        .padding(.vertical, 14)
    }

    private func choiceButton(_ n: Int) -> some View {
        let chosen = Int(state.shown.rounded()) == n
        return Button { if !chosen { choose(Double(n)) } } label: {
            Text("\(n)").font(.machine(14))
                .foregroundStyle(chosen ? TuningInk.onStone : (enabled ? Ink.ink : Ink.dim))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(chosen ? AnyShapeStyle(enabled ? TuningInk.stone : Ink.dim) : AnyShapeStyle(Color.clear), in: Capsule())
                .overlay(Capsule().strokeBorder(chosen ? Color.clear : Ink.hairline, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle(scale: 0.96))
        .accessibilityLabel("\(knob.title) \(n)")
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("tuning.knob.\(knob.name).\(n)")
    }
}

/// A value the page shows but does not change here. The value is one or
/// more parts, such as "R 0.92", "G 0.87" and "B 0.80". They sit on one
/// line at the right, as the slider values do, when title and value fit.
/// Otherwise the value goes under the title on one line, and if even that
/// is too wide, one part to a line. A part is never broken.
struct TuningFactRow: View {
    @Environment(\.dynamicTypeSize) private var type
    let title: String
    let parts: [String]
    let note: String
    /// What VoiceOver reads for the value, when the letters would not say it.
    var spoken: String? = nil

    private var ax: Bool { type.isAccessibilitySize }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if ax {
                VStack(alignment: .leading, spacing: 6) {
                    titleText.fixedSize(horizontal: false, vertical: true)
                    value
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        titleText.lineLimit(1).fixedSize()
                        Spacer(minLength: 8)
                        oneLine
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        titleText.fixedSize(horizontal: false, vertical: true)
                        value
                    }
                }
            }
            Text(note).font(.ui(ax ? 10 : 12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }

    private var titleText: some View {
        Text(title).font(.ui(ax ? 12 : 15, .semibold))
    }

    private func part(_ text: String) -> some View {
        Text(text).font(.machine(ax ? 10 : 13)).foregroundStyle(TuningInk.stone).lineLimit(1).fixedSize()
    }

    private var oneLine: some View {
        part(parts.joined(separator: " ")).accessibilityLabel(spoken ?? parts.joined(separator: " "))
    }

    /// One line, or one part to a line when one line does not fit.
    private var value: some View {
        ViewThatFits(in: .horizontal) {
            oneLine
            VStack(alignment: .leading, spacing: 4) {
                ForEach(parts, id: \.self) { part($0) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken ?? parts.joined(separator: " "))
        }
    }
}
