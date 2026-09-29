import Foundation

// The Home Screen widget's rules, checked on the Mac against the production
// files: Shared/WidgetReading.swift, Shared/WallSnapshot.swift,
// Shared/WallFacts.swift and Shared/Panel.swift. The store is pointed at a
// temporary folder and a throwaway defaults suite, never the app group.

@main struct WidgetReadingTests {
    static func main() throws {
        var checks: [[String: Any]] = []
        var produced: [String] = []
        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            var c: [String: Any] = ["name": name, "passed": passed]
            if !passed && !detail.isEmpty { c["detail"] = detail }
            checks.append(c)
        }
        func eq<T: Equatable>(_ a: T, _ b: T, _ name: String) {
            check(name, a == b, "\(a) != \(b)")
        }

        var london = Calendar(identifier: .gregorian)
        london.timeZone = TimeZone(identifier: "Europe/London")!
        let gb = Locale(identifier: "en_GB")
        let us = Locale(identifier: "en_US")
        // Tuesday 22 September 2026, 21:41 in London.
        let now = london.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 21, minute: 41))!
        let frame = Data([UInt8](repeating: 120, count: 64 * 64 * 3))

        func read(_ r: WallSnapshot.Record, at t: Date = now, locale: Locale = gb, live: Bool = true) -> WidgetReading {
            let reading = WidgetReading(result: .record(r), now: t, calendar: london, locale: locale, liveTimer: live)
            produced += [reading.status, reading.chip, reading.title, reading.subtitle, reading.accessibility].compactMap { $0 }
            return reading
        }
        func wall(_ mode: String = "art", face: String? = nil, seenAgo: TimeInterval = 30) -> WallSnapshot.Record {
            var r = WallSnapshot.Record()
            r.frame = frame
            r.side = 64
            r.mode = mode
            r.face = face ?? mode
            r.showingTitle = "Into the Quiet"
            r.showingArtist = "The Tessera Sessions"
            r.playingTitle = "Into the Quiet"
            r.playingArtist = "The Tessera Sessions"
            r.source = .wall
            r.link = .live
            r.seen = now.addingTimeInterval(-seenAgo)
            r.written = now.addingTimeInterval(-seenAgo)
            return r
        }

        // MARK: Current and stale

        let music = read(wall())
        eq(music.kind, .current, "current music is current")
        eq(music.status, "On the wall", "current status")
        eq(music.statusSymbol, "square.grid.3x3.fill", "current symbol")
        eq(music.chip, nil, "no chip while current")
        eq(music.duty, 1, "full light while current")
        eq(music.title, "Into the Quiet", "music title is the showing title")
        eq(music.subtitle, "The Tessera Sessions", "music subtitle is the artist")
        eq(music.accessibility, "Into the Quiet. The Tessera Sessions. On the wall.", "VoiceOver sentence")
        eq(music.selectedKey, "art", "art key selected")
        check("current keys are settled and shown", music.settled && music.showsKeys)
        eq(music.keysInert, false, "current keys send")
        eq(music.keepsSubtitle, false, "an artist may give way to the title")
        eq(music.promotesSubtitle, false, "an artist never takes the title's place")
        eq(music.subtitleLines, 1, "an artist keeps to one line")
        eq(music.dark, false, "a frame is not dark")

        let edge = read(wall(seenAgo: 599))
        eq(edge.kind, .current, "seen 599 s ago is current")
        let stale = read(wall(seenAgo: 600))
        eq(stale.kind, .asOf(now.addingTimeInterval(-600)), "seen 600 s ago is As of")
        eq(stale.chip, "As of 21:31", "stale chip is the as-of time (en_GB)")
        eq(stale.status, stale.chip, "stale status matches the chip")
        eq(stale.statusSymbol, "clock", "stale symbol")
        eq(stale.duty, WidgetReading.dimDuty, "stale is dimmed")
        eq(stale.settled, false, "stale keys are all buttons")
        eq(stale.title, "Into the Quiet", "stale keeps the title")

        var away = wall()
        away.link = .away
        eq(read(away).kind, .asOf(now.addingTimeInterval(-30)), "link away with a fresh seen is As of at once")
        var neverSeen = wall()
        neverSeen.seen = nil
        eq(read(neverSeen).kind, .asOf(neverSeen.written), "no seen falls back to the written time")
        var outdated = wall()
        outdated.outdated = true
        outdated.mode = "ambient"
        let od = read(outdated)
        check("outdated is As of", { if case .asOf = od.kind { return true } else { return false } }())
        eq(od.selectedKey, "ambient", "outdated shows the new key")
        eq(od.duty, WidgetReading.dimDuty, "outdated frame is dimmed")
        eq(od.title, "Into the Quiet", "outdated keeps the old frame's title")
        eq(od.status, "Changing to Lamp", "a live wall's accepted change is the status, never dropped")
        eq(od.statusSymbol, "arrow.triangle.2.circlepath", "changing symbol")
        eq(od.chip, "As of 21:40", "the small widget dates the old frame")
        eq(od.subtitle, od.chip, "the medium widget dates it too, so the two sizes agree")
        eq(od.keepsSubtitle, true, "the dimmed frame's age is kept")
        eq(od.promotesSubtitle, false, "an age never takes the title's place")
        eq(od.subtitleShortens, false, "the age is shown whole")
        eq(od.accessibility, "Into the Quiet. As of 21:40. Changing to Lamp.", "changing VoiceOver sentence")
        eq(od.nextChange, now.addingTimeInterval(-30 + 600), "a change moments ago turns As of at seen + 600 s")
        eq(music.subtitleShortens, true, "an artist may end after a whole word")
        var turningOff = outdated
        turningOff.mode = "off"
        eq(read(turningOff).status, "Turning off", "an accepted Off says turning off")
        var oldChange = outdated
        oldChange.seen = now.addingTimeInterval(-1200)
        oldChange.written = now.addingTimeInterval(-1200)
        let oldC = read(oldChange)
        eq(oldC.status, "As of 21:21", "a change seen long ago is dated in the status")
        eq(oldC.subtitle, "Changing to Lamp", "and the change is the subtitle")
        eq(oldC.keepsSubtitle, true, "the change is never dropped")
        eq(oldC.promotesSubtitle, false, "the change never takes the title's place")
        eq(oldC.subtitleShortens, false, "the change is shown whole or not at all")
        var awayChange = outdated
        awayChange.link = .away
        eq(read(awayChange).status, read(awayChange).chip, "a change recorded away from the wall is dated")
        eq(read(awayChange).subtitle, "Changing to Lamp", "and names the change beside the title")
        var sameMode = wall()
        sameMode.outdated = true
        eq(read(sameMode).subtitle, "The Tessera Sessions", "an outdated frame with the same mode keeps its artist")
        check("a dimmed picture stays legible", WidgetReading.dimDuty >= 0.7 && WidgetReading.dimDuty < 1)

        // MARK: Phone and queued

        var phone = wall()
        phone.source = .phone
        phone.link = .standIn
        phone.seen = nil
        let pv = read(phone)
        eq(pv.kind, .preview, "a phone frame is a preview")
        eq(pv.status, "Phone preview", "preview status")
        eq(pv.chip, "Phone preview", "preview chip")
        eq(pv.statusSymbol, "iphone", "preview symbol")
        eq(pv.duty, 1, "preview at full light")

        var standInLamp = phone
        standInLamp.mode = "ambient"
        standInLamp.face = "ambient"
        standInLamp.playingTitle = nil
        eq(read(standInLamp).title, "Lamp", "a stand-in record with mode ambient is titled Lamp")

        var queued = wall(seenAgo: 1200)
        queued.link = .away
        queued.queued = true
        queued.mode = "off"
        let q = read(queued)
        eq(q.kind, .queued, "queued while away")
        eq(q.status, "Queued for the wall", "queued status")
        eq(q.statusSymbol, "tray.and.arrow.up", "queued symbol")
        eq(q.chip, "As of 21:21", "queued wall frame chip is its time")
        eq(q.subtitle, q.chip, "the medium widget dates a queued frame as the small one does")
        eq(q.keepsSubtitle, true, "a queued frame's age is kept")
        eq(q.promotesSubtitle, false, "a queued frame's age never takes the title's place")
        eq(q.subtitleShortens, false, "a queued frame's age is shown whole")
        eq(q.duty, WidgetReading.dimDuty, "queued wall frame is dimmed")
        eq(q.selectedKey, "off", "queued shows the requested key")

        var queuedPhone = queued
        queuedPhone.source = .phone
        let qp = read(queuedPhone)
        eq(qp.status, "Queued for the wall", "phone plus queued is still queued")
        eq(qp.chip, "Phone preview", "phone plus queued chip")
        eq(qp.subtitle, "Phone preview", "the medium widget says phone preview too")
        eq(qp.duty, 1, "phone plus queued at full light")

        var queuedLive = wall()
        queuedLive.queued = true
        eq(read(queuedLive).kind, .current, "a live wall is not queued")

        // MARK: Faces

        let clock = read(wall("clock"))
        eq(clock.title, "Clock", "clock title")
        eq(clock.chip, "As of 21:40", "clock always says when")
        eq(clock.duty, 1, "clock at full light")
        eq(clock.settled, true, "clock keys settled")

        var timer = wall("timer")
        timer.timerEnds = now.addingTimeInterval(252)
        let t = read(timer)
        eq(t.title, "Timer", "timer title")
        eq(t.subtitle, "4:12 left", "timer countdown")
        eq(t.status, "Ends 21:45", "a counting timer's status says when it ends, never dating the countdown")
        eq(t.statusSymbol, "timer", "counting timer symbol")
        eq(t.chip, "As of 21:40", "the small widget still dates the frozen digits")
        eq(read(timer, live: false).status, "Ends 21:45", "a still reading says when it ends too")
        let usEnds = WidgetReading.ends(now.addingTimeInterval(252), calendar: london, locale: us)
            .replacingOccurrences(of: "\u{202F}", with: " ")
        eq(usEnds, "Ends 9:45 PM", "ends, en_US")
        eq(t.timerEnds, timer.timerEnds, "timer end for the live countdown")
        eq(t.nextChange, timer.timerEnds, "the timeline changes at the timer's end")
        check("timer subtitle is set in figures", t.timed)
        eq(t.keepsSubtitle, true, "a timer keeps its time left before its title's size")
        eq(t.subtitleShortens, true, "a timer may drop the word left")
        eq(t.promotesSubtitle, true, "a timer's time left may take the title's place")
        eq(t.subtitleLines, 1, "a timer's time left keeps to one line")
        eq(read(timer, live: false).timerEnds, nil, "a still reading has no live countdown")
        eq(read(timer, at: now.addingTimeInterval(300)).subtitle, "Finished", "past the end is Finished")
        var ringing = wall("timer")
        ringing.timerRinging = true
        eq(read(ringing).subtitle, "Finished", "ringing is Finished")
        eq(read(ringing).status, "As of 21:40", "a finished timer is dated")
        eq(read(ringing).timerEnds, nil, "ringing has no countdown")
        var longTimer = wall("timer")
        longTimer.timerEnds = now.addingTimeInterval(3723)
        eq(read(longTimer).subtitle, "1:02:03 left", "hours in a long timer")

        var timerSong = timer
        timerSong.showingTitle = nil
        eq(read(timerSong).title, "Timer", "a timer with music playing is titled Timer")
        var weather = wall("weather")
        weather.place = "London"
        let w = read(weather)
        eq(w.title, "Weather", "weather with music playing is titled Weather")
        eq(w.subtitle, "London", "weather subtitle is the place")
        eq(w.keepsSubtitle, true, "the weather keeps its place")
        eq(w.promotesSubtitle, true, "the place may take the title's place")
        eq(w.subtitleShortens, false, "a place is never shortened")
        eq(w.subtitleLines, 2, "a place may wrap rather than be lost")

        var lamp = wall("ambient")
        lamp.playingTitle = nil
        lamp.playingArtist = nil
        eq(read(lamp).title, "Lamp", "the lamp never inherits the last sleeve's title")
        eq(read(lamp).selectedKey, "ambient", "lamp key selected")
        let underLamp = read(wall("ambient"))
        eq(underLamp.title, "Lamp", "music under the lamp: the title is what the wall shows")
        eq(underLamp.subtitle, "Playing Into the Quiet", "the song is said beside the lamp")
        eq(underLamp.subtitleShortens, false, "playing is shown whole or not at all")
        eq(underLamp.keepsSubtitle, false, "playing may give way")
        eq(underLamp.accessibility, "Lamp. Playing Into the Quiet. On the wall.", "music under the lamp VoiceOver")

        var video = wall("video")
        video.showingTitle = "A Film"
        video.playingTitle = "Another Song"
        eq(read(video).title, "A Film", "video uses the showing title")
        var cdNoShowing = wall("cd")
        cdNoShowing.showingTitle = nil
        cdNoShowing.showingArtist = nil
        eq(read(cdNoShowing).title, "Into the Quiet", "a music face falls back to playing")
        var frameFace = wall("frame")
        frameFace.playingTitle = nil
        eq(read(frameFace).title, "Your creation", "frame face name")

        var off = wall("off")
        off.frame = Data(count: 64 * 64 * 3)
        let o = read(off)
        eq(o.title, "Lights out", "off is Lights out")
        eq(o.chip, "Off", "off chip")
        eq(o.status, "Now", "a dark wall's status says when, not what is on it")
        eq(o.statusSymbol, "square.grid.3x3", "a dark wall's symbol is the unlit lattice")
        eq(o.accessibility, "Lights out.", "VoiceOver leaves out the bare Now")
        eq(o.selectedKey, "off", "off key selected")
        eq(o.dark, true, "off is dark")

        var idle = wall("art", face: "off")
        idle.rest = "idle"
        let i = read(idle)
        eq(i.title, "Nothing playing", "idle dark title")
        eq(i.subtitle, "Dark between songs", "idle dark subtitle")
        eq(i.chip, "Nothing playing", "idle dark chip")
        eq(i.selectedKey, "art", "idle keeps the art key")
        eq(i.status, "Now", "idle dark status")
        eq(i.keepsSubtitle, false, "Dark between songs may give way")
        eq(i.subtitleShortens, false, "Dark between songs is never shortened")
        eq(i.subtitleLines, 1, "Dark between songs keeps to one line or gives way")
        eq(i.dark, true, "idle dark is the lattice")

        var gone = wall("art", face: "off")
        gone.rest = "away"
        let g = read(gone)
        eq(g.title, "Dark while you are away", "away title never says Off beside an unlit Off key")
        eq(g.chip, "Away", "away chip")
        eq(g.selectedKey, "art", "away keeps the art key")
        eq(g.status, "Now", "away status")

        for (purpose, title) in [("panel", "Panel check"), ("calibration", "True colour"),
                                 ("onboarding", "Setup preview"), ("identify", "Connection check"),
                                 ("tuning", "Panel tuning")] {
            var c = wall("art", face: "frame")
            c.check = purpose
            let reading = read(c)
            eq(reading.title, title, "check \(purpose) title")
            eq(reading.subtitle, nil, "check \(purpose) has no subtitle")
            eq(reading.status, "Check running", "check \(purpose) status")
            eq(reading.chip, "Check running", "check \(purpose) small widget label")
            eq(reading.selectedKey, nil, "check \(purpose) selects no key")
            eq(reading.keysInert, true, "check \(purpose) keys send nothing")
        }
        var oldCheck = wall("art", face: "frame", seenAgo: 1200)
        oldCheck.check = "panel"
        let oc = read(oldCheck)
        eq(oc.keysInert, false, "a dated check has ordinary keys")
        eq(oc.selectedKey, "art", "a dated check shows the setting")
        eq(oc.status, "As of 21:21", "a dated check says when")

        var blank = wall()
        blank.showingTitle = "   "
        blank.showingArtist = "\n"
        blank.playingTitle = " "
        eq(read(blank).title, "Album art", "whitespace titles count as none")
        eq(read(blank).subtitle, nil, "whitespace artist counts as none")

        // MARK: Which titles may end in a tail
        //
        // The medium widget lets only a song's title truncate. Every other
        // title is the reading's own words and must shrink instead.

        eq(music.titleIsSong, true, "a song's title is a song")
        eq(underLamp.titleIsSong, false, "the lamp under music is not a song")
        eq(read(cdNoShowing).titleIsSong, true, "the playing fallback is a song")
        eq(read(lamp).titleIsSong, false, "the lamp's name is not a song")
        eq(read(blank).titleIsSong, false, "a face name standing in for a blank song is not a song")
        eq(read(frameFace).titleIsSong, false, "a face name is not a song")
        eq(o.titleIsSong, false, "Lights out is not a song")
        eq(i.titleIsSong, false, "Nothing playing is not a song")
        eq(g.titleIsSong, false, "the away line is not a song")
        eq(w.titleIsSong, false, "Weather is not a song")
        var checkOverSong = wall("art", face: "frame")
        checkOverSong.check = "panel"
        eq(read(checkOverSong).titleIsSong, false, "a check's title is not a song")

        var future = wall()
        future.seen = now.addingTimeInterval(3600)
        future.written = now.addingTimeInterval(3600)
        eq(read(future).kind, .current, "a seen time ahead of the phone is clamped to now")
        future.link = .away
        eq(read(future).chip, "As of 21:41", "a clamped as-of never names the future")

        // MARK: The guest code, through the real mapping

        let songJSON: [String: Any] = ["title": "Into the Quiet", "artist": "The Tessera Sessions"]
        let musicJSON: [String: Any] = ["mode": "art", "display_mode": "art", "now_showing": songJSON,
                                        "now_playing": songJSON, "display_session": ["active": false]]
        var guestsJSON = musicJSON
        guestsJSON["display_mode"] = "frame"
        guestsJSON["display_session"] = ["active": true, "purpose": "guests"]
        let musicFacts = WallFacts(json: musicJSON)
        let guestFacts = WallFacts(json: guestsJSON)
        eq(guestFacts.face, "art", "WallFacts: guests face is the mode")
        eq(guestFacts.check, nil, "WallFacts: guests is not a check")
        eq(guestFacts.session, "guests", "WallFacts: the session is kept")
        let musicRecord = WallSnapshot.record(facts: musicFacts, frame: frame, side: 64, host: "", queued: false, now: now)
        let guestRecord = WallSnapshot.record(facts: guestFacts, frame: frame, side: 64, host: "", queued: false, now: now)
        eq(guestRecord, musicRecord, "a guest code records exactly what the music did")
        let guestReading = read(guestRecord)
        eq(guestReading, read(musicRecord), "a guest code reads exactly as the music does")
        let guestWords = [guestReading.status, guestReading.chip, guestReading.title, guestReading.subtitle,
                          guestReading.accessibility].compactMap { $0 }.joined(separator: " ").lowercased()
        check("a guest code never names guests, Wi-Fi or a code",
              !guestWords.contains("guest") && !guestWords.contains("wi-fi") && !guestWords.contains("code"))

        let panelFacts = WallFacts(json: ["mode": "art", "display_mode": "frame",
                                          "display_session": ["active": true, "purpose": "panel"]])
        eq(read(WallSnapshot.record(facts: panelFacts, frame: frame, side: 64, host: "", queued: false, now: now)).title,
           "Panel check", "WallFacts: a panel check is titled")
        let idleFacts = WallFacts(json: ["mode": "art", "display_mode": "off", "idle_active": "black",
                                         "now_showing": ["title": "  "]])
        let idleReading = read(WallSnapshot.record(facts: idleFacts, frame: Data(count: 64 * 64 * 3), side: 64,
                                                   host: "", queued: false, now: now))
        eq(idleReading.title, "Nothing playing", "WallFacts: idle black reads Nothing playing")
        let lampFacts = WallFacts(json: ["mode": "ambient", "display_mode": "ambient",
                                         "now_showing": ["title": "Old Song"], "now_playing": [String: Any]()])
        eq(read(WallSnapshot.record(facts: lampFacts, frame: frame, side: 64, host: "", queued: false, now: now)).title,
           "Lamp", "WallFacts: a lamp with a stale now_showing reads Lamp")
        let timerFacts = WallFacts(json: ["mode": "timer", "display_mode": "timer", "timer_remaining_s": 252,
                                          "timer_state": "counting"])
        let timerRecord = WallSnapshot.record(facts: timerFacts, frame: frame, side: 64, host: "", queued: false, now: now)
        eq(timerRecord.timerEnds, now.addingTimeInterval(252), "WallFacts: a counting timer's end")
        let weatherFacts = WallFacts(json: ["mode": "weather", "display_mode": "weather", "place": "Leeds"])
        eq(WallSnapshot.record(facts: weatherFacts, frame: frame, side: 64, host: "", queued: false, now: now).place,
           "Leeds", "WallFacts: the weather keeps its place")
        eq(WallSnapshot.record(facts: musicFacts, frame: frame, side: 64, host: "h", queued: true, now: now).queued,
           true, "a live record carries queued forward")

        // MARK: Missing and unreadable

        let missing = WidgetReading(result: .missing, now: now, calendar: london, locale: gb)
        produced += [missing.status, missing.chip, missing.title, missing.accessibility].compactMap { $0 }
        eq(missing.chip, "Open Tessera", "missing chip")
        eq(missing.status, "Not set up", "missing status")
        eq(missing.title, "Open Tessera", "missing title, two words that never leave one alone on a line")
        eq(missing.showsKeys, false, "missing has no keys")
        eq(missing.titleIsSong, false, "the missing instruction is never cut")
        eq(missing.dark, true, "missing is the lattice")
        eq(missing.accessibility, "Open Tessera. Not set up.", "missing VoiceOver sentence")
        let unreadable = WidgetReading(result: .unreadable, now: now, calendar: london, locale: gb)
        produced += [unreadable.chip, unreadable.title, unreadable.subtitle, unreadable.accessibility].compactMap { $0 }
        eq(unreadable.status, nil, "unreadable has no status")
        eq(unreadable.subtitle, "Open Tessera to refresh", "unreadable says what to do")
        eq(unreadable.keepsSubtitle, true, "unreadable keeps its hint")
        eq(unreadable.subtitleShortens, false, "the hint is shown whole")
        eq(unreadable.subtitleLines, 2, "the hint wraps rather than hides")
        eq(unreadable.promotesSubtitle, false, "the hint never takes the title's place")
        eq(unreadable.chip, "Open Tessera", "the small widget says what to do, not a bare lattice")
        eq(unreadable.title, "The wall", "unreadable title")
        eq(unreadable.showsKeys, false, "unreadable has no keys")

        // MARK: As of, by day and locale

        let today = now.addingTimeInterval(-3 * 3600)
        eq(WidgetReading.asOf(today, now: now, calendar: london, locale: gb), "As of 18:41", "same day, en_GB")
        let usToday = WidgetReading.asOf(today, now: now, calendar: london, locale: us)
            .replacingOccurrences(of: "\u{202F}", with: " ")
        eq(usToday, "As of 6:41 PM", "same day, en_US")
        let yesterday = london.date(byAdding: .day, value: -1, to: now)!
        eq(WidgetReading.asOf(yesterday, now: now, calendar: london, locale: gb), "As of Mon", "yesterday is a weekday")
        let sixDays = london.date(byAdding: .day, value: -6, to: now)!
        eq(WidgetReading.asOf(sixDays, now: now, calendar: london, locale: us), "As of Wed", "six days is a weekday")
        let sevenDays = london.date(byAdding: .day, value: -7, to: now)!
        eq(WidgetReading.asOf(sevenDays, now: now, calendar: london, locale: gb), "As of 15 Sep",
           "a week or more is a date, en_GB")
        eq(WidgetReading.asOf(sevenDays, now: now, calendar: london, locale: us), "As of Sep 15",
           "a week or more is a date, en_US")

        // The timeline flips at the stale moment, and an as-of line changes
        // at midnight and again at the week.
        eq(music.nextChange, now.addingTimeInterval(-30 + 600), "current flips to stale at seen + 600 s")
        let midnight = london.date(byAdding: .day, value: 1, to: london.startOfDay(for: now))!
        eq(stale.nextChange, midnight, "a stale reading next changes at midnight")
        let lastWeek = read(wall(seenAgo: 2 * 86_400))
        eq(lastWeek.chip, "As of Sun", "two days ago is a weekday")
        eq(lastWeek.nextChange, london.date(byAdding: .day, value: 7, to: london.startOfDay(for: now.addingTimeInterval(-2 * 86_400))),
           "a weekday reading next changes when it becomes a date")
        eq(pv.nextChange, nil, "a phone preview has nothing scheduled")

        // MARK: The store

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tessera-widget-\(UUID().uuidString)")
        let suite = "tessera-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: folder)
            defaults.removePersistentDomain(forName: suite)
        }
        let store = WallSnapshot.Store(directory: folder, defaults: defaults)
        eq(store.read(), .missing, "no file and no old keys is missing")
        store.update { $0.queued = true }
        eq(store.read(), .missing, "update does nothing without a record")

        defaults.set(frame, forKey: "frame")
        defaults.set("Old Title", forKey: "title")
        defaults.set("Old Artist", forKey: "artist")
        defaults.set("ambient", forKey: "mode")
        defaults.set("wall.local:8788", forKey: "host")
        let updated = now.addingTimeInterval(-900)
        defaults.set(updated, forKey: "updated")
        defaults.set("wall.local:8788", forKey: "wall.host")
        if case .record(let legacy) = store.read() {
            eq(legacy.source, .wall, "legacy with a host is the wall's frame")
            eq(legacy.link, .away, "legacy link is away")
            eq(legacy.seen, updated, "legacy updated becomes seen")
            eq(legacy.showingTitle, "Old Title", "legacy title")
            eq(legacy.mode, "ambient", "legacy mode")
            eq(legacy.face, "ambient", "legacy face is the mode")
            eq(legacy.frame, frame, "legacy frame")
        } else {
            check("legacy keys migrate", false)
        }
        defaults.set("", forKey: "host")
        if case .record(let legacy) = store.read() {
            eq(legacy.source, .phone, "legacy without a host is the phone's frame")
            eq(legacy.seen, nil, "legacy without a host was never seen")
        } else {
            check("legacy keys migrate without a host", false)
        }

        var written = wall()
        written.host = "wall.local:8788"
        store.write(written)
        if case .record(let back) = store.read() {
            check("a record round-trips", back.frame == written.frame && back.mode == written.mode
                  && back.seen == written.seen && back.host == written.host && back.source == .wall)
        } else {
            check("a record round-trips", false)
        }
        check("the first write retires the six old keys",
              WallSnapshot.Store.legacyKeys.allSatisfy { defaults.object(forKey: $0) == nil })
        eq(defaults.string(forKey: "wall.host"), "wall.local:8788", "wall.host is kept")

        // A widget key launched a fresh session: it merges, never erases.
        store.update { r in
            r.mode = "off"
            r.queued = true
            r.outdated = true
        }
        if case .record(let merged) = store.read() {
            check("a merge keeps the title and frame", merged.showingTitle == "Into the Quiet" && merged.frame == frame)
            check("a merge records the queued change", merged.queued && merged.outdated && merged.mode == "off")
        } else {
            check("a merge keeps the record", false)
        }

        let json = try String(contentsOf: store.fileURL, encoding: .utf8)
        check("the frame is stored as base64 and dates as seconds",
              json.contains("\"frame\":\"") && json.contains("\"written\":") && !json.contains("T21:"))

        try Data("{\"v\":2,\"mode\":\"cd\"}".utf8).write(to: store.fileURL)
        if case .record(let partial) = store.read() {
            check("a partial record reads with defaults", partial.mode == "cd" && partial.face == "cd"
                  && partial.frame == nil && partial.link == .away)
        } else {
            check("a partial record reads with defaults", false)
        }
        try Data("{not json".utf8).write(to: store.fileURL)
        eq(store.read(), .unreadable, "a damaged record is unreadable, not missing")

        store.setMeasured(CGSize(width: 170, height: 170), for: "systemSmall")
        eq(store.measured("systemSmall"), CGSize(width: 170, height: 170), "measured sizes round-trip")
        eq(store.measured("systemMedium"), nil, "an unmeasured family is nil")

        // MARK: Whole words

        let long = "Everything Is Beautiful When We Listen Together"
        let fits = WordFit.candidates(long)
        eq(fits.first, long, "the whole title comes first")
        eq(fits.dropFirst().first, "Everything Is Beautiful When We Listen\u{2026}", "then one word fewer")
        eq(fits.last, "Everything\u{2026}", "down to the first word")
        func wholeWords(_ shown: String, of full: String) -> Bool {
            if shown == full { return true }
            guard shown.hasSuffix(WordFit.ellipsis) else { return false }
            let head = WordFit.words(String(shown.dropLast()))
            let all = WordFit.words(full)
            guard !head.isEmpty, head.count <= all.count else { return false }
            guard Array(all.prefix(head.count - 1)) == Array(head.dropLast()) else { return false }
            let original = all[head.count - 1], last = head[head.count - 1]
            return original.hasPrefix(last) && original.dropFirst(last.count).allSatisfy { !$0.isLetter && !$0.isNumber }
        }
        let orchestra = "The Metropolitan Orchestra & the Voices of Tomorrow"
        for text in [long, orchestra, "Song (feat. Someone Else)", "Hello, World", "Jay-Z Live"] {
            check("every prefix of \(text) ends after a whole word",
                  WordFit.candidates(text).allSatisfy { wholeWords($0, of: text) })
        }
        check("an ampersand never ends a prefix", !WordFit.candidates(orchestra).contains { $0.hasSuffix("&\u{2026}") })
        check("The Metropolitan Orchestra... is offered", WordFit.candidates(orchestra).contains("The Metropolitan Orchestra\u{2026}"))
        eq(WordFit.candidates("Song (feat. Someone Else)"), ["Song (feat. Someone Else)", "Song\u{2026}"],
           "an open bracket goes with its fragment")
        eq(WordFit.candidates("Hello, World"), ["Hello, World", "Hello\u{2026}"], "a comma before the ellipsis is dropped")
        eq(WordFit.candidates("Supercalifragilistic"), ["Supercalifragilistic"], "one word has no shorter form")
        eq(WordFit.candidates("4:12 left", ellipsis: false), ["4:12 left", "4:12"], "a timer shortens to its time alone")
        eq(WordFit.candidates("   "), [], "blank text has none")
        eq(WordFit.candidates("The Tessera Sessions", telling: true), ["The Tessera Sessions", "The Tessera\u{2026}"],
           "an artist never shortens to The...")
        check("a telling artist keeps a word of four letters",
              WordFit.candidates(orchestra, telling: true).dropFirst().allSatisfy { WordFit.words($0).contains(where: WordFit.tells) })
        eq(WordFit.candidates("The Who", telling: true), ["The Who"], "The Who is whole or nothing")
        eq(WordFit.candidates("The Tessera Sessions"), ["The Tessera Sessions", "The Tessera\u{2026}", "The\u{2026}"],
           "a title may still shorten to its first word")
        eq(WordFit.display("Jay-Z"), "Jay-\u{2060}Z", "a line never breaks at a hyphen inside a name")

        // MARK: Copy

        let banned = ["\u{2014}", "\u{2013}", ";", "\u{00B7}", "\u{00D7}"]
        let bad = produced.filter { s in banned.contains { s.contains($0) } || s.lowercased().contains("asleep") }
        check("no reading uses an em dash, en dash, semicolon, middot, multiplication sign or asleep",
              bad.isEmpty, bad.joined(separator: " | "))
        check("every face name is plain", ["art", "cd", "ambient", "clock", "timer", "off", "weather", "lyrics", "nine",
                                           "frame", "clip", "ticker", "game", "imagine", "video", "?"]
            .map(WallFace.name).allSatisfy { n in !banned.contains { n.contains($0) } })
        eq(WallFace.name("unknown"), "Wall", "the home's fallback is kept")

        let failures = checks.filter { !($0["passed"] as! Bool) }
        let report: [String: Any] = ["suite": "Production WidgetReading and WallSnapshot",
                                     "passed": checks.count - failures.count, "failed": failures.count,
                                     "checks": checks]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]))
        FileHandle.standardOutput.write(Data("\n".utf8))
        if !failures.isEmpty { exit(1) }
    }
}
