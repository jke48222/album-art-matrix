// Putting the wall on the lock screen, and taking it off again.
//
// The rule for when this runs is the interesting part. A Live Activity that
// stays up all day is a Live Activity people turn off, so this only exists
// while the wall is doing something worth glancing at: showing a track, or
// lettering, or on as a lamp. Nothing playing and the wall asleep means it
// ends itself. Nobody needs a lock-screen widget to tell them a dark wall is
// dark.
//
// There is exactly one of it. Every card on the lock screen is one Live
// Activity, and the pile of old songs that built up there was every extra
// one: a launch that forgot the activity the last launch made, or a second
// request slipping out while the first was still being granted. So this
// adopts whatever an earlier launch left, allows one request in flight,
// and ends every activity of ours when it ends any.
//
// When the app goes to sleep it can no longer speak for the wall, so unless
// the keep-alive is on (then it keeps running) the activity is ended and
// allowed to linger a quarter of an hour before the lock screen drops it.
// A card that still says what was playing at lunch is the thing this file
// exists to prevent.
//
// Updates are throttled. A still sleeve is sent on change and otherwise
// twice a minute to keep the position honest; a moving wall (the record
// turning, the lamp drifting, lettering scrolling) is sent once a second so
// the lock screen moves with it.

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
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var pending: WallAttributes.ContentState?
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var lastKey = ""
    @ObservationIgnored private var lastSent = Date.distantPast
    @ObservationIgnored private var asleep = false

    /// How long the wall may stay on the lock screen after the app can no
    /// longer say what it is doing.
    private static let linger: TimeInterval = 15 * 60

    init() {
        adoptLeftovers()
    }

    /// Whatever an earlier launch left on the lock screen: the newest one
    /// still alive is this launch's to carry on with, everything else is an
    /// old song and goes.
    private func adoptLeftovers() {
        let all = Activity<WallAttributes>.activities
        guard !all.isEmpty else { return }
        let alive = all.filter { $0.activityState == .active || $0.activityState == .stale }
        let keep = enabled && !asleep
            ? alive.max { ($0.content.staleDate ?? .distantPast) < ($1.content.staleDate ?? .distantPast) }
            : nil
        let extras = all.filter { $0.id != keep?.id }
        if !extras.isEmpty {
            Task.detached(priority: .utility) {
                for a in extras { await a.end(nil, dismissalPolicy: .immediate) }
            }
        }
        if let keep { attach(keep) }
    }

    private func attach(_ a: Activity<WallAttributes>) {
        activity = a
        running = true
        lastKey = ""                      // whatever it shows, the next update is news
        watcher?.cancel()
        // A swipe on the lock screen dismisses it behind our back. Hearing
        // about it is what lets the next update make a new one instead of
        // talking to a corpse for the rest of the day.
        watcher = Task { [weak self] in
            for await s in a.activityStateUpdates {
                if s == .dismissed || s == .ended {
                    await MainActor.run { [weak self] in
                        guard let self, self.activity?.id == a.id else { return }
                        self.activity = nil
                        self.running = false
                        self.lastKey = ""
                    }
                    break
                }
            }
        }
    }

    /// True when the wall is doing something a person would look up at.
    private func worthShowing(_ state: WallState) -> Bool {
        if state.mode == "off" { return false }
        if state.mode == "art" || state.mode == "cd" {
            return !(state.title ?? "").isEmpty
        }
        return true          // lamp, lettering, clock: all deliberate acts
    }

    nonisolated private static func content(_ state: WallAttributes.ContentState) -> ActivityContent<WallAttributes.ContentState> {
        ActivityContent(state: state, staleDate: Date().addingTimeInterval(linger))
    }

    func update(state: WallState, frame: [UInt8], wall: String) {
        guard enabled, !asleep, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
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
        // frame of the same thing is not, unless the wall is moving. A
        // spinning record or a drifting lamp is motion, and the lock screen
        // shows it at one frame a second: enough to read as alive, few
        // enough that ActivityKit keeps delivering them.
        let key = "\(state.mode)|\(state.title ?? "")|\(state.artist ?? "")"
        let fresh = key != lastKey
        let moving = ["cd", "ambient", "ticker", "clock", "timer", "clip", "snake", "lyrics"].contains(state.mode)
        let every: TimeInterval = moving ? 1.0 : 30
        guard fresh || Date().timeIntervalSince(lastSent) > every else { return }
        lastKey = key
        lastSent = Date()

        // ActivityKit blocks whoever calls it (the lap timer clocked its
        // update at 448ms on the render path), so every interaction happens
        // on a detached task and only the bookkeeping comes back.
        if let activity {
            Task.detached(priority: .utility) {
                await activity.update(Self.content(content))
            }
        } else if starting {
            // One request at a time. The latest picture waits for the
            // activity being made and lands on it the moment it exists.
            pending = content
        } else {
            starting = true
            let attrs = WallAttributes(wall: wall)
            Task.detached(priority: .utility) { [weak self] in
                let made = try? Activity.request(attributes: attrs, content: Self.content(content), pushType: nil)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.starting = false
                    guard let made else {
                        self.pending = nil
                        self.lastKey = ""             // so the next change tries again
                        return
                    }
                    self.attach(made)
                    self.lastKey = key
                    if let late = self.pending {
                        self.pending = nil
                        Task.detached(priority: .utility) { await made.update(Self.content(late)) }
                    }
                }
            }
        }
    }

    /// Off the lock screen, now. Every activity of ours, not only the one
    /// this launch made: a leftover from an earlier launch is exactly what
    /// "off" should take down.
    func end() async {
        watcher?.cancel()
        watcher = nil
        activity = nil
        pending = nil
        running = false
        lastKey = ""
        let all = Activity<WallAttributes>.activities
        guard !all.isEmpty else { return }
        Task.detached(priority: .utility) {
            for a in all { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// The app is going to the background. With the keep-alive on it keeps
    /// running and keeps the lock screen honest; without it the phone
    /// suspends it within seconds and the card would freeze on whatever was
    /// playing, for hours. So it is ended, and lingers a quarter of an hour.
    func appSleeps(canStayAwake: Bool) {
        guard !canStayAwake else { return }
        asleep = true
        guard let activity else { return }
        watcher?.cancel()
        watcher = nil
        self.activity = nil
        pending = nil
        running = false
        lastKey = ""
        Task.detached(priority: .utility) {
            await activity.end(nil, dismissalPolicy: .after(Date().addingTimeInterval(Self.linger)))
        }
    }

    /// Back in front. Anything left lingering is done with; the next update
    /// makes a fresh one.
    func appWakes() {
        asleep = false
        adoptLeftovers()
    }
}
