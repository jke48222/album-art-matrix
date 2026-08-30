// Putting the wall on the lock screen, and taking it off again.
//
// The rule for when this runs is the interesting part. A Live Activity that
// stays up all day is a Live Activity people turn off, so this only exists
// while the wall is doing something worth glancing at: showing a track, or
// lettering, or on as a lamp. Nothing playing and the wall asleep means it
// ends itself. Nobody needs a lock-screen widget to tell them a dark wall is
// dark.
//
// Updates are throttled hard. ActivityKit will accept a push per second and
// then quietly stop delivering them; a wall in an animated mode changes every
// frame, and none of those are news. So it sends on a real change of what the
// wall is showing, and otherwise at most twice a minute to keep the position
// honest.

import ActivityKit
import Foundation
import SwiftUI

@MainActor
@Observable
final class LiveWall {
    private(set) var running = false
    /// The owner's choice. Off by default: a lock-screen presence is not
    /// something to help yourself to.
    @ObservationIgnored @AppStorage("live.enabled") var enabled = false {
        didSet { if !enabled { Task { await end() } } }
    }

    @ObservationIgnored private var activity: Activity<WallAttributes>?
    @ObservationIgnored private var lastKey = ""
    @ObservationIgnored private var lastSent = Date.distantPast

    /// True when the wall is doing something a person would look up at.
    private func worthShowing(_ state: WallState) -> Bool {
        if state.mode == "off" { return false }
        if state.mode == "art" || state.mode == "cd" {
            return !(state.title ?? "").isEmpty
        }
        return true          // lamp, lettering, clock: all deliberate acts
    }

    func update(state: WallState, frame: [UInt8], wall: String) {
        guard enabled, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard worthShowing(state) else {
            Task { await end() }
            return
        }

        let content = WallAttributes.ContentState(
            tiles: WallTile.reduce(frame),
            title: state.title ?? "",
            artist: state.artist ?? "",
            mode: state.mode,
            songAt: state.songNow,
            songOf: state.songOf,
            playing: state.songPlaying,
            stamped: Date()
        )

        // What counts as news: a different track, or a different mode. A new
        // frame of the same thing is not.
        let key = "\(state.mode)|\(state.title ?? "")|\(state.artist ?? "")"
        let fresh = key != lastKey
        guard fresh || Date().timeIntervalSince(lastSent) > 30 else { return }
        lastKey = key
        lastSent = Date()

        // ActivityKit blocks whoever calls it (the lap timer clocked its
        // update at 448ms on the render path), so every interaction happens
        // on a detached task and only the bookkeeping comes back.
        if let activity {
            Task.detached(priority: .utility) {
                await activity.update(
                    ActivityContent(state: content, staleDate: Date().addingTimeInterval(15 * 60))
                )
            }
        } else {
            let attrs = WallAttributes(wall: wall)
            Task.detached(priority: .utility) { [weak self] in
                let made = try? Activity.request(
                    attributes: attrs,
                    content: ActivityContent(state: content,
                                             staleDate: Date().addingTimeInterval(15 * 60)),
                    pushType: nil
                )
                await MainActor.run {
                    self?.activity = made
                    self?.running = made != nil
                }
            }
        }
    }

    func end() async {
        guard let activity else { running = false; return }
        await activity.end(nil, dismissalPolicy: .immediate)
        self.activity = nil
        running = false
        lastKey = ""
    }
}
