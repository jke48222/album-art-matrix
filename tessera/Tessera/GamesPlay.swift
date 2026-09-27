import SwiftUI

/// Thumb-sized arcade controls share feedback and availability, not game state.
struct ArcadeKey: View {
    let title: String
    let symbol: String
    let accessibilityTitle: String
    var tint: Color = Ink.ink
    var prominent = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
                if !title.isEmpty {
                    Text(title).font(.ui(12, .semibold)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(prominent ? Ink.ground : tint)
            .padding(.horizontal, 6).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(prominent ? tint : Ink.plaster, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(prominent ? 0 : 0.18), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(PressStyle(scale: reduceMotion ? 1 : 0.96))
        .accessibilityLabel(accessibilityTitle)
        .opacity(enabled ? 1 : 0.4)
    }
}

struct ArcadeRoundControl: View {
    let name: String
    let phase: String
    let tint: Color
    let send: ([String: Any]) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button {
            send([phase == "ready" ? "start" : phase == "paused" ? "resume" : "pause": true])
        } label: {
            HStack(spacing: 12) {
                Image(systemName: phase == "playing" ? "pause.fill" : "play.fill")
                Text(phase == "ready" ? "Start \(name)" : phase == "paused" ? "Resume \(name)" : "Pause \(name)")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if phase == "paused" { Image(systemName: "arrow.turn.down.right") }
            }
            .font(.ui(15, .semibold))
            .foregroundStyle(phase == "playing" ? tint : Ink.ground)
            .padding(.horizontal, 16).padding(.vertical, 12).frame(minHeight: 48)
            .background(phase == "playing" ? Ink.plaster : tint, in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(PressStyle(scale: reduceMotion ? 1 : 0.96)).keyboardShortcut(.space, modifiers: [])
            .opacity(enabled ? 1 : 0.4)
    }
}
