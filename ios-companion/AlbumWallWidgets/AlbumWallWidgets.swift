// The lock-screen / Dynamic Island face of the wall. System fonts only in
// the extension (no font registration plumbing) — the Paper discipline
// carries through weight, tracking, and the ink/signal palette instead.
import ActivityKit
import SwiftUI
import WidgetKit

private let paper = Color(red: 0.957, green: 0.945, blue: 0.918)
private let signal = Color(red: 0.878, green: 0.243, blue: 0.102)

@main
struct AlbumWallWidgetsBundle: WidgetBundle {
    var body: some Widget {
        WallHomeWidget()
        WallLiveActivity()
    }
}

struct WallLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WallActivityAttributes.self) { context in
            lockScreen(context.state)
                .activityBackgroundTint(Color.black.opacity(0.82))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    dot(context.state.playing)
                        .padding(.top, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.title)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(paper)
                            .lineLimit(1)
                        Text(context.state.artist)
                            .font(.system(size: 12))
                            .foregroundStyle(paper.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    modeTag(context.state.mode)
                        .padding(.top, 8)
                }
            } compactLeading: {
                dot(context.state.playing)
            } compactTrailing: {
                Text(shortMode(context.state.mode))
                    .font(.system(size: 11, weight: .heavy))
                    .kerning(1)
                    .foregroundStyle(paper)
            } minimal: {
                dot(context.state.playing)
            }
        }
    }

    private func lockScreen(_ s: WallActivityAttributes.ContentState) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("ALBUMWALL")
                        .font(.system(size: 10, weight: .heavy))
                        .kerning(2)
                        .foregroundStyle(paper.opacity(0.55))
                    Circle().fill(signal).frame(width: 4, height: 4)
                }
                Text(s.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(paper)
                    .lineLimit(1)
                Text(s.artist)
                    .font(.system(size: 13))
                    .foregroundStyle(paper.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer()
            modeTag(s.mode)
        }
        .padding(16)
    }

    private func modeTag(_ mode: String) -> some View {
        Text(displayMode(mode))
            .font(.system(size: 10, weight: .heavy))
            .kerning(1.5)
            .foregroundStyle(paper.opacity(0.85))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(paper.opacity(0.35), lineWidth: 1))
    }

    private func dot(_ playing: Bool) -> some View {
        Circle()
            .fill(playing ? signal : paper.opacity(0.3))
            .frame(width: 7, height: 7)
    }

    private func displayMode(_ m: String) -> String {
        switch m {
        case "cd": "SPIN"
        case "ambient": "AMBIENT"
        case "off": "OFF"
        case "frame": "YOURS"
        default: "ART"
        }
    }

    private func shortMode(_ m: String) -> String {
        m == "off" ? "OFF" : "ON"
    }
}
