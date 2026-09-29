// What GET /state says is on the wall, read one way everywhere.
//
// The app's session (WallState) and the widget's own fetch both turn /state
// into "what is showing and what is it called". Written twice, the two had
// already drifted: one read now_showing only, the other preferred
// now_playing. So the mapping lives here once, Foundation only, for the app,
// the widget and the Mac-side unit tests alike.
//
// The guest code is the case that matters. While a guests display session
// is up, the brain reports display_mode "frame" and /frame.raw serves the
// cover of what was up before. The face therefore comes from `mode`, never
// display_mode, and the purpose is not a check to name, so nothing that
// reads these facts can say a code is on the wall.

import Foundation

struct WallFacts: Equatable {
    /// The setting. It drives which key is selected.
    var mode = "art"
    /// What is visible: display_mode, except during a guests session.
    var face = "art"
    /// display_session.purpose while one is active, guests included.
    var session: String? = nil
    /// The session purpose worth naming: panel, calibration, onboarding,
    /// identify or tuning. Never guests.
    var check: String? = nil
    /// now_showing: what the artwork on the wall belongs to.
    var showingTitle: String? = nil
    var showingArtist: String? = nil
    /// now_playing: the song that is on, whatever face is up.
    var playingTitle: String? = nil
    var playingArtist: String? = nil
    /// The weather's place as named on the phone. Nil when unset.
    var place: String? = nil
    /// Seconds left on a timer, from the wall's receipt.
    var timerRemaining: Int? = nil
    var timerRinging = false
    /// "away" or "idle" when the brain's rest policy is holding the wall.
    var rest: String? = nil

    init() {}

    init(json: [String: Any]) {
        mode = json["mode"] as? String ?? "art"
        session = Self.purpose(json["display_session"])
        face = Self.face(mode: mode, displayed: json["display_mode"] as? String ?? mode, session: session)
        check = Self.check(session)
        (showingTitle, showingArtist) = Self.song(json["now_showing"])
        (playingTitle, playingArtist) = Self.song(json["now_playing"])
        place = Self.words(json["place"])
        timerRemaining = json["timer_remaining_s"] as? Int
        // The same fallbacks WallState uses for a brain that predates
        // timer_state and timer_ringing.
        let status = json["timer_state"] as? String
            ?? (timerRemaining == nil ? "idle" : (timerRemaining == 0 ? "ringing" : "counting"))
        timerRinging = json["timer_ringing"] as? Bool ?? (status == "ringing")
        rest = Self.rest(away: json["away_active"] as? Bool ?? false,
                         idle: json["idle_active"] as? String)
    }

    // The rules, as functions, so the app can apply them to a state it
    // changed locally (an optimistic mode, a stand-in) without JSON.

    /// A guest code covers the wall with what was up before it, so the
    /// face is the setting, not the "frame" the brain reports.
    static func face(mode: String, displayed: String, session: String?) -> String {
        session == "guests" ? mode : displayed
    }

    static func check(_ session: String?) -> String? {
        session == "guests" ? nil : session
    }

    static func rest(away: Bool, idle: String?) -> String? {
        if away { return "away" }
        return idle == nil ? nil : "idle"
    }

    /// When a counting timer ends, on this device's clock.
    func timerEnds(from now: Date) -> Date? {
        guard face == "timer", !timerRinging, let left = timerRemaining, left > 0 else { return nil }
        return now.addingTimeInterval(TimeInterval(left))
    }

    private static func purpose(_ raw: Any?) -> String? {
        guard let s = raw as? [String: Any], s["active"] as? Bool == true else { return nil }
        return words(s["purpose"])
    }

    private static func song(_ raw: Any?) -> (String?, String?) {
        guard let d = raw as? [String: Any] else { return (nil, nil) }
        return (words(d["title"]), words(d["artist"]))
    }

    /// Empty or whitespace text counts as none.
    private static func words(_ raw: Any?) -> String? {
        guard let s = raw as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
