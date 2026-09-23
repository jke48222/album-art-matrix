import SwiftUI

/// The same finite range and detents feed touch, accessibility and the label.
struct WallSliderScale {
    let bounds: ClosedRange<Double>
    let step: Double

    init(bounds: ClosedRange<Double>, step: Double) {
        let span = bounds.upperBound - bounds.lowerBound
        if bounds.lowerBound.isFinite, bounds.upperBound.isFinite, span.isFinite, span > 0 {
            self.bounds = bounds
            self.step = step.isFinite && step > 0 ? min(span, max(span / 1_000_000, step)) : span / 100
        } else {
            self.bounds = 0...1
            self.step = 0.01
        }
    }

    func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return bounds.lowerBound }
        let clamped = min(bounds.upperBound, max(bounds.lowerBound, value))
        if clamped == bounds.lowerBound || clamped == bounds.upperBound { return clamped }
        let snapped = bounds.lowerBound + ((clamped - bounds.lowerBound) / step).rounded() * step
        return min(bounds.upperBound, max(bounds.lowerBound, snapped))
    }
}

/// A native slider keeps VoiceOver, Switch Control and hardware input intact.
/// Bind to the local preview, then send the value when editing ends. An
/// interrupted gesture restores its starting value before the cancel callback.
/// https://developer.apple.com/documentation/swiftui/slider
struct WallValueSlider: View {
    @Binding var value: Double
    let bounds: ClosedRange<Double>
    let step: Double
    var title: String
    var accent: Color
    var ink: Color
    var secondary: Color
    var format: (Double) -> String
    var onEditingChanged: (Bool) -> Void
    var onCancel: (() -> Void)?

    @State private var initial: Double?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isEnabled) private var enabled

    init(value: Binding<Double>, in bounds: ClosedRange<Double> = 0.05...1,
         step: Double = 0.01, title: String = "Brightness", accent: Color = Ink.tile,
         ink: Color = Ink.ink, secondary: Color = Ink.dim,
         format: @escaping (Double) -> String = { String(format: "%.0f%%", $0 * 100) },
         onEditingChanged: @escaping (Bool) -> Void = { _ in },
         onCancel: (() -> Void)? = nil) {
        _value = value
        self.bounds = bounds
        self.step = step
        self.title = title
        self.accent = accent
        self.ink = ink
        self.secondary = secondary
        self.format = format
        self.onEditingChanged = onEditingChanged
        self.onCancel = onCancel
    }

    private var scale: WallSliderScale { WallSliderScale(bounds: bounds, step: step) }
    private var reading: Double { scale.normalized(value) }
    private var selection: Binding<Double> {
        Binding(get: { reading }, set: { next in
            guard enabled else { return }
            begin()
            value = scale.normalized(next)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) { heading; Spacer(minLength: 12); number }
                VStack(alignment: .leading, spacing: 6) { heading; number }
            }
            .accessibilityHidden(true)
            // Quantize in the binding so iOS does not draw a tick for every
            // one-percent detent; the native track remains continuous.
            Slider(value: selection, in: scale.bounds,
                   onEditingChanged: { active in active ? begin() : finish() }) {
                Text(title)
            }
            .tint(accent.toned(forDark: ink.wallUsesDarkInk))
            .frame(minHeight: 44)
            .accessibilityLabel(title)
            .accessibilityValue(format(reading))
            .accessibilityAdjustableAction { direction in
                guard enabled else { return }
                begin()
                switch direction {
                case .increment: value = scale.normalized(reading + scale.step)
                case .decrement: value = scale.normalized(reading - scale.step)
                @unknown default: break
                }
                finish()
            }
            HStack {
                Text(format(scale.bounds.lowerBound))
                Spacer()
                Text(format(scale.bounds.upperBound))
            }
            .font(.machine(9, medium: false))
            .foregroundStyle(secondary)
            .accessibilityHidden(true)
        }
        .onDisappear { cancel() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { cancel() } }
        .onChange(of: enabled) { _, enabled in if !enabled { cancel() } }
    }

    private var heading: some View {
        Text(title).font(.ui(15, .medium)).foregroundStyle(ink)
    }

    private var number: some View {
        Text(format(reading)).font(.machine(20)).monospacedDigit()
            .foregroundStyle(ink).contentTransition(.numericText())
            .fixedSize(horizontal: true, vertical: false)
    }

    private func begin() {
        guard enabled, initial == nil else { return }
        initial = reading
        onEditingChanged(true)
    }

    private func finish() {
        guard initial != nil else { return }
        initial = nil
        onEditingChanged(false)
    }

    private func cancel() {
        guard let initial else { return }
        value = initial
        self.initial = nil
        if let onCancel { onCancel() }
        else { onEditingChanged(false) }
    }
}
