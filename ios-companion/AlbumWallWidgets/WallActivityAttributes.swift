// Identical twin of the definition in the app target (LiveActivityShared).
// The system matches Live Activities by type name — keep in lockstep.
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
