import SwiftUI

/// A single route into the existing time workspace. Completion never pushes
/// the user out of their current page or repeats its controls in a new modal.
struct TimeCompletionEntry: View {
    @Environment(WallSession.self) private var wall
    let accent: Color
    let open: () -> Void
    private var alarm: Bool { wall.state.timerKind == "alarm" }
    private var tint: Color { alarm ? Color(hex: 0xEDBC76) : Color(hex: 0xA4DAC5) }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 13) {
                Image(systemName: alarm ? "bell.fill" : "checkmark.circle.fill")
                    .font(.system(size: 22)).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(alarm ? "Your alarm is ringing" : "Timer complete")
                        .font(.ui(15, .semibold)).foregroundStyle(Ink.ink)
                    Text(alarm ? "Stop or snooze in Time & alarms" : "Done or repeat in Time & alarms")
                        .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 5)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(hex: 0x202623), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(tint.opacity(0.3), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.99)).accessibilityIdentifier("time.completion.open")
        .accessibilityHint("Opens the existing timer and alarm controls")
    }
}
