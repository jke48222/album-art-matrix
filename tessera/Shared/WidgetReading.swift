// What the widget says about a snapshot, decided in one place.
//
// The views only draw. Every word they show, whether the picture is dimmed,
// which key is selected and when the reading next changes are worked out
// here, from the record and a clock, so the Mac-side tests can check each
// rule without a widget, and the widget, the Settings page and the render
// harness cannot disagree.
//
// The small widget stays the wall with nothing on it while the picture is
// current. A label appears when it is not, when the wall is dark or when a
// check is up: a picture this phone drew, a picture that has aged, a time
// face whose digits froze when the frame was taken, a wall that is off, dark
// while you are away or dark between songs, or a test pattern. The unlit
// lattice or a grey check alone could be any of those.
//
// The two sizes never explain one picture two ways. When the medium widget's
// status names something other than the picture's age (a queued change, a
// change the wall is making), its subtitle carries the age the small
// widget's label shows.

import Foundation

/// The home's names for the faces, shared with the widget so the two use
/// one table.
enum WallFace {
    static func name(_ mode: String) -> String {
        table[mode] ?? "Wall"
    }

    private static let table = [
        "art": "Album art", "cd": "Spin", "ambient": "Lamp", "clock": "Clock",
        "timer": "Timer", "off": "Off", "weather": "Weather", "lyrics": "Lyrics",
        "nine": "Nine", "frame": "Your creation", "clip": "Clip", "ticker": "Words",
        "game": "Game", "imagine": "Imagine", "video": "Video",
    ]

    /// Faces that show a song's artwork, so the song names the picture.
    static let music: Set<String> = ["art", "cd", "nine", "lyrics", "video"]
    /// Faces whose picture is a moment in time, frozen when it was taken.
    static let time: Set<String> = ["clock", "timer"]
}

struct WidgetReading: Equatable {
    enum Kind: Equatable {
        case current
        case asOf(Date)
        case preview
        case queued
        case missing
        case unreadable
    }

    /// The lit emitters of a picture that is not current, dimmed. The unlit
    /// lattice stays as it is. The emitter gaps already take the widget to
    /// about a third of the wall's brightness, so this stays gentle: clearly
    /// dimmer, still legible, and the label says why.
    static let dimDuty = 0.7

    let kind: Kind
    /// The moment this reading describes.
    let at: Date
    /// Sentence case. The medium widget's status line, uppercased by the view.
    let status: String?
    let statusSymbol: String
    /// The small widget's one label. Nil while the picture is current and
    /// shows what it is.
    let chip: String?
    let title: String
    /// The title names a song, which may end in a tail when it is long.
    /// Any other title is the reading's own words, and is never cut.
    let titleIsSong: Bool
    let subtitle: String?
    /// The subtitle carries what the reading is for (a timer's time left, a
    /// place, what to do next, how old a dimmed picture is, what the wall is
    /// changing to), so the medium widget never drops it: the title shrinks,
    /// or gives the subtitle its place, instead.
    let keepsSubtitle: Bool
    /// The subtitle is the reading's value (a timer's time left, a place),
    /// so when the title and it do not fit together it may be set in the
    /// title's place. A hint never is: it reads as an instruction, not a
    /// name.
    let promotesSubtitle: Bool
    /// The subtitle may be shortened after a whole word: a song's artist,
    /// or a timer's "4:12 left" to "4:12". The reading's own words ("Dark
    /// between songs", "Changing to Lamp", "Playing Into the Quiet") are
    /// shown whole or not at all.
    let subtitleShortens: Bool
    /// The subtitle is a timer's time left, set in figures.
    let timed: Bool
    /// The lines a subtitle may take. One that is kept and never shortened
    /// (a place, a hint) may wrap onto a second line rather than be lost.
    /// Anything else keeps to one.
    var subtitleLines: Int { keepsSubtitle && !subtitleShortens ? 2 : 1 }
    /// A counting timer's end, for a live countdown. Nil when there is none
    /// or when the caller asked for a still one.
    let timerEnds: Date?
    /// Draw the unlit lattice instead of the frame.
    let dark: Bool
    let duty: Double
    /// art, ambient or off.
    let selectedKey: String?
    let showsKeys: Bool
    /// A check is running on the wall. Any mode would end it, so the keys
    /// are drawn as quiet labels that send nothing, and none is selected.
    let keysInert: Bool
    /// The wall is live, the picture fresh and the mode known. Tapping the
    /// selected key then would only re-send it, and any accepted mode ends
    /// an Archive replay or a check on the wall, so it is drawn as a label.
    let settled: Bool
    let accessibility: String
    /// When this reading turns into another one: the stale flip, a timer's
    /// end, or an "As of" line changing from a time to a day to a date.
    let nextChange: Date?

    init(result: WallSnapshot.ReadResult, now: Date, calendar: Calendar = .current,
         locale: Locale = .current, liveTimer: Bool = true) {
        at = now
        switch result {
        case .missing:
            kind = .missing
            status = "Not set up"
            statusSymbol = "arrow.up.forward.app"
            chip = "Open Tessera"
            // Two words, so it never leaves one alone on a last line. The
            // status already says it is not set up.
            title = "Open Tessera"
            titleIsSong = false
            subtitle = nil
            keepsSubtitle = false
            promotesSubtitle = false
            subtitleShortens = false
            timed = false
            timerEnds = nil
            dark = true
            duty = 1
            selectedKey = nil
            showsKeys = false
            keysInert = false
            settled = false
            nextChange = nil
        case .unreadable:
            // Before the first unlock, or a damaged file. Quiet, but never
            // an empty square that looks unfinished.
            kind = .unreadable
            status = nil
            statusSymbol = "square.grid.3x3"
            // The unlit lattice alone reads as a wall that is off.
            chip = "Open Tessera"
            title = "The wall"
            titleIsSong = false
            subtitle = "Open Tessera to refresh"
            keepsSubtitle = true
            promotesSubtitle = false
            subtitleShortens = false
            timed = false
            timerEnds = nil
            dark = true
            duty = 1
            selectedKey = nil
            showsKeys = false
            keysInert = false
            settled = false
            nextChange = nil
        case .record(let r):
            let seen = r.seen.map { min($0, now) }
            let written = min(r.written, now)
            let face = Self.clean(r.face) ?? r.mode
            let check = Self.clean(r.check)
            let words = Self.words(r, face: face, now: now)
            let recent = seen.map { now.timeIntervalSince($0) < WallSnapshot.staleAfter } == true
            let fresh = r.link == .live && !r.outdated && recent
            let queuedHere = r.link != .live && r.queued
            // A key was taken and the frame on record is from before it: say
            // what the wall is changing to, until the next frame arrives.
            let changing = r.outdated && check == nil && r.mode != face ? Self.changing(to: r.mode) : nil
            // A live wall took the change moments ago. The status says so,
            // and the picture's age moves to the subtitle, as the small
            // widget's label shows it.
            let changingNow = changing != nil && !queuedHere && r.source == .wall && r.link == .live && recent
            // What the small widget's label says about a picture the medium
            // widget's status does not date: its age, or that this phone
            // drew it.
            let label: String? = queuedHere
                ? (r.source == .phone ? "Phone preview" : Self.asOf(seen ?? written, now: now, calendar: calendar, locale: locale))
                : (changingNow ? Self.asOf(seen ?? written, now: now, calendar: calendar, locale: locale) : nil)
            // A subtitle the reading supplies in place of the artist. Never
            // dropped, never shortened.
            let note = label ?? changing
            title = words.title
            titleIsSong = words.song
            subtitle = note ?? words.subtitle
            timed = note == nil && face == "timer" && check == nil
            keepsSubtitle = subtitle != nil && (note != nil || (check == nil && (face == "timer" || face == "weather")))
            // Only a value (a timer's time left, a place) may take the
            // title's place. A note reads as a remark, not a name.
            promotesSubtitle = keepsSubtitle && note == nil
            subtitleShortens = subtitle != nil && note == nil && (words.song || timed)
            let counting = changing == nil && face == "timer" && !r.timerRinging
            timerEnds = counting && liveTimer ? r.timerEnds.flatMap { $0 > now ? $0 : nil } : nil
            dark = face == "off" || Panel.square(r.frame) == nil
            showsKeys = true

            // Only a check that is running now. A dated one has likely ended,
            // and its keys are ordinary keys again.
            let checking = fresh && check != nil
            keysInert = checking
            selectedKey = checking ? nil : ["art": "art", "ambient": "ambient", "off": "off"][r.mode]
            var dated: Date? = nil
            if queuedHere {
                // Asked for while the wall was away. The request is what the
                // keys show, and the picture is whatever this phone has.
                kind = .queued
                status = "Queued for the wall"
                statusSymbol = "tray.and.arrow.up"
                chip = label
                if r.source == .phone {
                    duty = 1
                } else {
                    dated = seen ?? written
                    duty = Self.dimDuty
                }
                settled = false
            } else if r.source == .phone {
                // A picture this phone drew is never passed off as the wall's.
                kind = .preview
                status = "Phone preview"
                statusSymbol = "iphone"
                chip = "Phone preview"
                duty = 1
                settled = false
            } else if !fresh {
                let when = seen ?? written
                dated = when
                kind = .asOf(when)
                if changingNow, let changing {
                    status = changing
                    statusSymbol = "arrow.triangle.2.circlepath"
                } else {
                    status = Self.asOf(when, now: now, calendar: calendar, locale: locale)
                    statusSymbol = "clock"
                }
                chip = Self.asOf(when, now: now, calendar: calendar, locale: locale)
                duty = Self.dimDuty
                settled = false
            } else if WallFace.time.contains(face) && check == nil {
                // Current, but the digits froze when the frame was taken, so
                // the small widget always says when. A counting timer's
                // status says when it ends instead: an "As of" above the live
                // countdown would seem to date the countdown.
                dated = written
                kind = .asOf(written)
                let asOf = Self.asOf(written, now: now, calendar: calendar, locale: locale)
                if counting, let ends = r.timerEnds, ends > now {
                    status = Self.ends(ends, calendar: calendar, locale: locale)
                    statusSymbol = "timer"
                } else {
                    status = asOf
                    statusSymbol = "clock"
                }
                chip = asOf
                duty = 1
                settled = true
            } else if checking {
                // A test pattern is up. The keys are labels until it ends,
                // and the small widget says so: a grey lattice alone reads
                // as a picture or a broken widget.
                kind = .current
                status = "Check running"
                statusSymbol = "hourglass"
                chip = "Check running"
                duty = 1
                settled = true
            } else if face == "off" {
                // Current, and dark. "On the wall" above "Lights out" would
                // say two things at once, so the status only says when.
                kind = .current
                status = "Now"
                statusSymbol = "square.grid.3x3"
                if r.mode == "off" { chip = "Off" }
                else if r.rest == "away" { chip = "Away" }
                else if r.rest == "idle" { chip = "Nothing playing" }
                else { chip = "Off" }
                duty = 1
                settled = true
            } else {
                kind = .current
                status = "On the wall"
                statusSymbol = "square.grid.3x3.fill"
                chip = nil
                duty = 1
                settled = true
            }

            var changes: [Date] = []
            // A live wall's reading turns "As of" ten minutes after it was
            // last seen, whether it is current or changing.
            if fresh || changingNow, let seen {
                changes.append(seen.addingTimeInterval(WallSnapshot.staleAfter))
            }
            if counting, let ends = r.timerEnds { changes.append(ends) }
            if let dated {
                // "As of 9:41 PM" must not still read as today tomorrow.
                let day = calendar.startOfDay(for: dated)
                if let next = calendar.date(byAdding: .day, value: 1, to: day) { changes.append(next) }
                if let week = calendar.date(byAdding: .day, value: 7, to: day) { changes.append(week) }
            }
            nextChange = changes.filter { $0 > now }.min()
        }
        // "Now" is a word for the eye beside a dark panel. Read aloud after
        // "Lights out" it adds nothing.
        accessibility = Self.sentences([title, subtitle, status == "Now" ? nil : status])
    }

    // MARK: Words

    /// Title and subtitle, as an explicit table so no face falls between
    /// two rules. song says the title is a song's, for the view's line rule.
    private static func words(_ r: WallSnapshot.Record, face: String, now: Date) -> (title: String, subtitle: String?, song: Bool) {
        if let check = clean(r.check) {
            return (checkTitle(check), nil, false)
        }
        let showing = clean(r.showingTitle).map { ($0, clean(r.showingArtist), true) }
        let playing = clean(r.playingTitle).map { ($0, clean(r.playingArtist), true) }
        if WallFace.music.contains(face) {
            if let song = showing ?? playing { return song }
            return (WallFace.name(face), nil, false)
        }
        switch face {
        case "clock":
            return ("Clock", nil, false)
        case "timer":
            return ("Timer", timerWords(r, now: now), false)
        case "weather":
            return ("Weather", clean(r.place), false)
        case "off":
            // "Off" is kept for the Off key's own state. Away leaves the
            // setting as it was, so its key stays lit and the words say dark.
            if r.mode == "off" { return ("Lights out", nil, false) }
            if r.rest == "away" { return ("Dark while you are away", nil, false) }
            if r.rest == "idle" { return ("Nothing playing", "Dark between songs", false) }
            return ("Lights out", nil, false)
        default:
            // Idle faces (the lamp, a picture, words) are named for what the
            // wall shows. They never inherit the last sleeve's title, and a
            // song that is on is said beside the face, never as the title:
            // "On the wall" above a song's name would say the song is showing.
            if let song = playing?.0 { return (WallFace.name(face), "Playing \(song)", false) }
            return (WallFace.name(face), nil, false)
        }
    }

    private static func checkTitle(_ purpose: String) -> String {
        switch purpose {
        case "panel": "Panel check"
        case "calibration": "True colour"
        case "onboarding": "Setup preview"
        case "identify": "Connection check"
        case "tuning": "Panel tuning"
        default: "Test pattern"
        }
    }

    /// What an accepted key is changing the wall to.
    private static func changing(to mode: String) -> String {
        mode == "off" ? "Turning off" : "Changing to \(WallFace.name(mode))"
    }

    /// "Ends 15:18" (en_GB), "Ends 3:18 PM" (en_US): when a counting timer
    /// ends, which stays true while the countdown beside it runs.
    static func ends(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateStyle = .none
        f.timeStyle = .short
        return "Ends " + f.string(from: date)
    }

    /// "4:12 left", or "Finished" once it rings or passes its end.
    private static func timerWords(_ r: WallSnapshot.Record, now: Date) -> String? {
        if r.timerRinging { return "Finished" }
        guard let ends = r.timerEnds else { return nil }
        let left = Int(ends.timeIntervalSince(now).rounded(.up))
        guard left > 0 else { return "Finished" }
        let h = left / 3600, m = (left % 3600) / 60, s = left % 60
        let clock = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        return clock + " left"
    }

    /// "As of 9:41 PM" the same day, "As of Mon" within six days, "As of
    /// 12 Sep" before that. A weekday a week old would read as this week's.
    static func asOf(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let then = min(date, now)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: then),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        if days <= 0 {
            f.dateStyle = .none
            f.timeStyle = .short
        } else if days <= 6 {
            f.setLocalizedDateFormatFromTemplate("EEE")
        } else {
            f.setLocalizedDateFormatFromTemplate("dMMM")
        }
        return "As of " + f.string(from: then)
    }

    /// Empty or whitespace text counts as none.
    static func clean(_ text: String?) -> String? {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// "Into the Quiet. The Tessera Sessions. On the wall."
    private static func sentences(_ parts: [String?]) -> String {
        let kept = parts.compactMap { clean($0) }.map { part -> String in
            var p = part
            while p.hasSuffix(".") { p.removeLast() }
            return p
        }
        return kept.joined(separator: ". ") + (kept.isEmpty ? "" : ".")
    }
}

// MARK: - Whole words

/// How a text is shortened without cutting a word: the whole text, then
/// ever shorter runs of its first words, each ending in an ellipsis. A word
/// left hanging ("&", "feat." with its bracket open) goes with the rest, and
/// a comma or colon before the ellipsis is dropped.
enum WordFit {
    static let ellipsis = "\u{2026}"

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// The whole text first, then whole-word prefixes, longest first. A
    /// timer's "4:12 left" shortens to "4:12", with no ellipsis: the time
    /// is whole on its own. telling drops a prefix that keeps no word of
    /// four or more letters: an artist shortened to "The..." says nothing,
    /// and is better left out.
    static func candidates(_ text: String, ellipsis trails: Bool = true, telling: Bool = false) -> [String] {
        let all = words(text)
        guard !all.isEmpty else { return [] }
        var out = [all.joined(separator: " ")]
        var k = all.count - 1
        while k >= 1 {
            let head = trimmed(Array(all.prefix(k)))
            if !head.isEmpty && (!telling || head.contains(where: tells)) {
                let candidate = head.joined(separator: " ") + (trails ? ellipsis : "")
                if !out.contains(candidate) { out.append(candidate) }
            }
            k -= 1
        }
        return out
    }

    /// A word of four or more letters or figures.
    static func tells(_ word: String) -> Bool {
        word.filter { $0.isLetter || $0.isNumber }.count >= 4
    }

    /// The text as it is set: a line may not break at a hyphen or slash
    /// inside a word, so "Jay-Z" never ends one line and starts the next.
    static func display(_ text: String) -> String {
        var out = ""
        for c in text {
            out.append(c)
            if c == "-" || c == "/" || c == "\u{2010}" { out.append("\u{2060}") }
        }
        return out
    }

    private static func trimmed(_ words: [String]) -> [String] {
        var head = words
        // A bracket opened and not closed leaves a fragment ("Song (feat.").
        var open: [Int] = []
        for (i, word) in head.enumerated() {
            for c in word {
                if c == "(" || c == "[" || c == "{" { open.append(i) }
                if (c == ")" || c == "]" || c == "}") && !open.isEmpty { open.removeLast() }
            }
        }
        if let first = open.first { head = Array(head.prefix(first)) }
        while let last = head.last {
            let kept = String(last.reversed().drop(while: dangling).reversed())
            if kept.contains(where: { $0.isLetter || $0.isNumber }) {
                head[head.count - 1] = kept
                break
            }
            head.removeLast()
        }
        return head
    }

    /// Punctuation that would sit badly before an ellipsis. Closing marks,
    /// quotes, ! and ? stay.
    private static func dangling(_ c: Character) -> Bool {
        guard c.isPunctuation || c.isSymbol else { return false }
        if "!?)]}\"'\u{2019}\u{201D}".contains(c) { return false }
        return true
    }
}
