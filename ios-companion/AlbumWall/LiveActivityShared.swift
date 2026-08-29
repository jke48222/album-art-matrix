// The Live Activity's data contract. The widget extension carries an
// identical copy (WallActivityAttributes.swift there) — the system matches
// activities by type name, so the two definitions must stay in lockstep.
import ActivityKit
import Foundation

struct WallActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var artist: String
        var playing: Bool
        var mode: String
    }
}

/// Starts, updates, and ends the lock-screen activity as pushes happen.
enum LiveActivityManager {
    /// Last wall mode seen by WallAPI — shown on the lock screen.
    static var lastMode = "art"

    private static var activity: Activity<WallActivityAttributes>? {
        Activity<WallActivityAttributes>.activities.first
    }

    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: "liveActivity")
    }

    static func sync(title: String, artist: String, playing: Bool, mode: String) {
        guard enabled else { endAll(); return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = WallActivityAttributes.ContentState(
            title: title, artist: artist, playing: playing, mode: mode)
        let content = ActivityContent(state: state, staleDate: nil)
        Task {
            if let a = activity {
                await a.update(content)
            } else if playing, title != "-" {
                _ = try? Activity.request(
                    attributes: WallActivityAttributes(), content: content)
            }
        }
    }

    static func endAll() {
        Task {
            for a in Activity<WallActivityAttributes>.activities {
                await a.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
