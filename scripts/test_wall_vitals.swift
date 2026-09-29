import Foundation

// Checks for tessera/Tessera/WallVitals.swift, run by scripts/test_wall_vitals.py:
//   xcrun swiftc -parse-as-library -D DEBUG tessera/Tessera/WallVitals.swift scripts/test_wall_vitals.swift -o /tmp/wall-vitals
//   /tmp/wall-vitals scripts/qa/health_fixtures.json
// Prints a JSON report and exits 1 when a check fails.

@main struct WallVitalsChecks {
    static func main() throws {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            var entry: [String: Any] = ["name": name, "passed": ok]
            if !ok { entry["detail"] = detail() }
            checks.append(entry)
        }

        let path = CommandLine.arguments.dropFirst().first ?? "scripts/qa/health_fixtures.json"
        let served = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any] ?? [:]
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func fixture(_ name: String) -> Vitals { HealthFixtures.vitals(name, receivedAt: now)! }
        func report(_ name: String) -> HealthReport { HealthReport(vitals: fixture(name)) }
        /// The steady reading with some keys replaced.
        func steady(_ changes: [String: Any]) -> HealthReport {
            var json = HealthFixtures.json("steady")!
            for (key, value) in changes { json[key] = value }
            return HealthReport(vitals: Vitals(json: json, receivedAt: now)!)
        }
        func bits(_ set: [String]) -> [String: Any] {
            var out: [String: Any] = ["raw": "0x0"]
            for key in ["undervolt", "capped", "throttled", "soft_temp"] {
                out["\(key)_now"] = set.contains("\(key)_now")
                out["\(key)_ever"] = set.contains("\(key)_ever")
            }
            out["now"] = set.contains { ["undervolt_now", "capped_now", "throttled_now"].contains($0) }
            out["ever"] = set.contains { ["undervolt_ever", "capped_ever", "throttled_ever"].contains($0) }
            return out
        }
        func parts(_ report: HealthReport) -> [String] { report.problems.map { "\($0.level.name) \($0.part.rawValue)" } }
        func row(_ report: HealthReport, _ part: HealthPart) -> HealthCheck? { report.checks.first { $0.part == part } }

        // The copy compiled into the app is the file the QA wall serves.
        check("HealthFixtures names every served preset", Set(HealthFixtures.names) == Set(served.keys) && HealthFixtures.names.count == 21,
              "\(HealthFixtures.names.count) names, \(served.count) served")
        for name in served.keys.sorted() {
            let same = (served[name] as? [String: Any]).map { NSDictionary(dictionary: $0).isEqual(to: HealthFixtures.json(name) ?? [:]) } ?? false
            check("Fixture \(name) matches health_fixtures.json", same)
        }

        // Every preset: level, verdict and the Settings line.
        let table: [(String, HealthLevel, String, String)] = [
            ("steady", .steady, "Running well.", "Running well, 54°C"),
            ("warm", .watch, "Worth a look.", "Running warm, 74°C"),
            ("hot", .act, "Running hot.", "Running hot, 82°C"),
            ("slowed", .act, "Slowed down.", "Slowed down"),
            ("slowed-earlier", .steady, "Running well.", "Running well, 58°C"),
            ("undervolt", .act, "Low on power.", "Low on power"),
            ("undervolt-earlier", .watch, "Worth a look.", "Power dipped earlier"),
            ("panels-off", .act, "Panels not updating.", "Panels not receiving pictures"),
            ("panels-starting", .watch, "Worth a look.", "Panels starting"),
            ("stalled", .act, "Picture updates stopped.", "Picture updates stopped"),
            ("memory-low", .watch, "Worth a look.", "Memory running low"),
            ("memory-critical", .act, "Almost out of memory.", "Almost out of memory"),
            ("storage-low", .watch, "Worth a look.", "Storage getting full"),
            ("animating", .steady, "Running well.", "Running well, 54°C"),
            ("unpaced", .steady, "Running well.", "Running well, 54°C"),
            ("still", .steady, "Running well.", "Running well, 54°C"),
            ("behind", .watch, "Worth a look.", "Frame rate behind"),
            ("collecting", .steady, "Running well.", "Running well, 52°C"),
            ("mac", .steady, "Running well.", "Running well"),
            ("legacy", .steady, "Running well.", "Running well, 54°C"),
            ("several", .act, "Needs attention.", "Low on power"),
        ]
        check("The table covers every preset", Set(table.map(\.0)) == Set(HealthFixtures.names))
        for (name, level, verdict, landing) in table {
            let r = report(name)
            check("\(name): \(level.name), \(verdict) \(landing)", r.level == level && r.verdict == verdict && r.landingLine == landing,
                  "got \(r.level.name), \(r.verdict) \(r.landingLine)")
        }

        // Specific presets.
        let steadyReport = report("steady")
        check("Steady lists every row in order", steadyReport.checks.map(\.part) == HealthPart.rows,
              "\(steadyReport.checks.map(\.part.rawValue))")
        check("Steady row values", steadyReport.checks.map(\.value) == ["Steady", "Full speed", "Connected", "Running", "412 MB free", "11 GB free", "3 days, 4 hours"],
              "\(steadyReport.checks.map(\.value))")
        check("Steady summary", steadyReport.summary == "The computer’s power, heat and picture updates are normal.")
        // The value already says how long the software has run, so the
        // subtitle says only what the value does not.
        check("Running for says the computer has been on longer",
              row(steadyReport, .uptime)?.subtitle == "Computer on for 12 days.",
              row(steadyReport, .uptime)?.subtitle ?? "none")
        check("Memory explanation uses the reading's total", row(steadyReport, .memory)?.explanation.contains("out of 990 MB in total") == true)
        check("Power explanation is about the computer only",
              row(steadyReport, .power)?.explanation == "Measured where power enters the computer. It does not measure the panels’ power.")
        let mac = report("mac")
        check("Mac: no power, speed, panels or memory rows", mac.checks.map(\.part) == [.loop, .storage, .uptime], "\(mac.checks.map(\.part.rawValue))")
        check("Mac: no temperature tile", mac.temperature == nil)
        check("Mac summary", mac.summary == "Picture updates are normal. This computer does not report power or heat.")
        check("Mac: running for says since the software started", row(mac, .uptime)?.subtitle == "Since the software last started")
        check("Mac: the footnote makes no power claim", !mac.footnote.contains("power"), mac.footnote)
        check("Steady: the footnote says where power is measured",
              steadyReport.footnote.hasSuffix("The power reading is taken at the computer, not at the panels."), steadyReport.footnote)
        let legacy = report("legacy")
        check("Legacy: no power row", row(legacy, .power) == nil)
        check("Legacy: slowed earlier names both causes", row(legacy, .speed)?.value == "Slowed earlier"
              && row(legacy, .speed)?.subtitle == "Heat or low power, at least once since the computer started. Normal now.")
        check("Legacy: the speed explanation says it cannot tell", row(legacy, .speed)?.explanation.contains("does not report which") == true)
        check("Legacy: no trace and no caption", legacy.temperature?.trace.isEmpty == true && legacy.temperature?.window == nil
              && legacy.temperature?.collecting == false)
        check("Legacy summary makes no power claim", legacy.summary == "Heat and picture updates are normal. This wall’s software does not report power separately."
              && !legacy.footnote.contains("power"), legacy.summary)
        check("Legacy: the temperature tile says there is no history", legacy.temperature?.note == "No history from this wall.")
        check("Temperature only: no power claim", steady(["throttled": NSNull()]).summary == "Heat and picture updates are normal. This computer does not report power.")
        check("Legacy: last measured frame rate", legacy.frames.kind == .legacy && legacy.frames.captions == [HealthReport.Frames.measured]
              && legacy.frames.note == "It may be from an earlier animation." && legacy.frames.status == nil)
        let legacyStill = HealthReport(vitals: Vitals(json: ["fps": 0.0, "uptime_s": 100], receivedAt: now)!)
        check("Legacy fps 0 reads Still", legacyStill.frames.word == "Still" && legacyStill.frames.perSecond == nil)
        let undervolt = report("undervolt")
        check("Undervolt with throttled now: only the power act", parts(undervolt) == ["act power"], "\(parts(undervolt))")
        check("Undervolt: no row claims the speed is normal", row(undervolt, .speed) == nil)
        check("Undervolt detail names the computer's supply",
              undervolt.problems.first?.noticeDetail == "The computer is getting too little power, so it runs slower and may restart. Check the supply that feeds the computer and its cable.")
        let dipped = report("undervolt-earlier")
        check("Power dipped earlier names the boot", dipped.problems.first?.noticeDetail == "The computer’s power dropped too low at least once since it started 12 days ago. If it happens again, check the supply that feeds the computer.",
              dipped.problems.first?.noticeDetail ?? "")
        check("Power dipped earlier: slowed while power was low", row(dipped, .speed)?.subtitle == "While power was low. Normal now.")
        var noBoot = HealthFixtures.json("undervolt-earlier")!; noBoot["boot_s"] = NSNull()
        check("Power dipped earlier without a boot time", HealthReport(vitals: Vitals(json: noBoot, receivedAt: now)!).problems.first?.noticeDetail
              == "The computer’s power dropped too low at least once since it started. If it happens again, check the supply that feeds the computer.")
        check("Slowed earlier while hot stays steady", report("slowed-earlier").level == .steady
              && row(report("slowed-earlier"), .speed)?.subtitle == "While it was hot. Normal now.")
        check("Slowed with the soft limit: heat copy", report("slowed").problems.first?.noticeDetail.contains("to stay cool") == true)
        let hot = report("hot")
        check("Hot detail", hot.problems.first?.noticeDetail == "The processor is at 82°C. At 80°C and above it runs slower to cool down. Give the back of the wall more room for air.")
        check("Hot tile", hot.temperature?.status == .hot && hot.temperature?.celsius == 82)
        check("Hot: no row claims full speed", row(hot, .speed) == nil && !hot.checks.contains { $0.value == "Full speed" })
        let slowed = report("slowed")
        check("Slowed to stay cool: the temperature is not called Normal", slowed.temperature?.status == .warm
              && slowed.temperature?.celsius == 68, "\(String(describing: slowed.temperature?.status))")
        check("Warm detail", report("warm").problems.first?.noticeDetail == "The processor is at 74°C. It slows down at 80°C.")
        let several = report("several")
        check("Several: power then memory", parts(several) == ["act power", "act memory"], "\(parts(several))")
        check("Several summary", several.summary == "Two problems, most urgent first.")
        check("Memory critical detail", report("memory-critical").problems.first?.noticeDetail
              == "48 MB of 990 MB is free. Turning the wall off and on again frees memory.")
        check("Several: restart is said once", several.problems.map(\.noticeDetail).joined(separator: " ").components(separatedBy: "restart").count == 2)
        check("Memory low detail", report("memory-low").problems.first?.noticeDetail == "96 MB of 990 MB is free.")
        check("Storage low detail", report("storage-low").problems.first?.noticeDetail == "820 MB is left.",
              report("storage-low").problems.first?.noticeDetail ?? "")
        let stalled = report("stalled")
        check("Stalled detail uses minutes", stalled.problems.first?.noticeDetail == "The panels are showing the last picture and have not updated for 2 minutes. Turn the wall off at the plug for ten seconds, then on again.")
        check("Stalled frames tile reads Stopped", stalled.frames.kind == .stopped && stalled.frames.word == "Stopped")
        let panelsOff = report("panels-off")
        check("Panels off: Picture updates is not listed as running", row(panelsOff, .loop) == nil
              && !panelsOff.checks.contains { $0.value == "Running" })
        check("Panels off: the frames tile reads Stopped, with no still caption", panelsOff.frames.kind == .stopped
              && panelsOff.frames.word == "Stopped" && panelsOff.frames.note == nil)
        check("Panels off: the restart comes before the plug", panelsOff.problems.first?.noticeDetail
              == "The program that drives the panels is not taking new pictures, so they may be dark or frozen. Restart the panel program below. If the panels stay dark, turn the wall off at the plug for ten seconds, then on again.")
        check("Panels off: a last reading keeps only the plug", panelsOff.problems.first?.readOnlyDetail
              == "The program that drives the panels is not taking new pictures, so they may be dark or frozen. Turn the wall off at the plug for ten seconds, then on again.")
        check("Panels starting detail", report("panels-starting").problems.first?.noticeDetail
              == "The wall’s software started 12 seconds ago and is still connecting to the panels. This can take up to a minute.")
        // Frames sent while the panels connect reach nothing, so the tile
        // says Starting rather than a slow number beside the notice.
        let starting = report("panels-starting")
        check("Panels starting: collecting, and the frame rate reads Starting", starting.temperature?.collecting == true
              && starting.frames.kind == .starting && starting.frames.word == "Starting" && starting.frames.perSecond == nil
              && starting.frames.note == HealthReport.Frames.startingNote && starting.frames.captions.isEmpty,
              "\(starting.frames.kind) \(String(describing: starting.frames.perSecond))")
        check("A panel program gone after the grace is not Starting", panelsOff.frames.kind == .stopped)
        // Heat is named only when the temperature tile beside it is not Normal.
        check("Behind at a normal temperature does not blame heat", report("behind").problems.first?.noticeDetail
              == "Animations are running at 41 frames a second, below the target of 60. A busy processor can cause this.",
              report("behind").problems.first?.noticeDetail ?? "")
        let behindWarm = steady(["fps": 41.2, "fps_age_s": 3.0, "temp_c": 72.0])
        check("Behind while warm names heat", behindWarm.problems.first { $0.part == .frames }?.noticeDetail
              == "Animations are running at 41 frames a second, below the target of 60. Heat or a busy processor can cause this.")
        let behindCapped = steady(["fps": 41.2, "fps_age_s": 3.0, "temp_c": 60.0, "throttled": bits(["capped_now"])])
        check("Behind while slowed for another reason names the slowdown", behindCapped.problems.first { $0.part == .frames }?.noticeDetail
              == "Animations are running at 41 frames a second, below the target of 60. A slowed processor can cause this.")
        check("Behind tile", report("behind").frames.status == "Behind" && report("behind").frames.captions == ["LAST FEW SECONDS", "TARGET 60"])
        check("Animating: paced and smooth", report("animating").frames.kind == .paced && report("animating").frames.status == "Smooth"
              && report("animating").frames.perSecond == 60 && report("animating").frames.fraction == 1)
        check("Unpaced: the number with no status, and a note saying why", report("unpaced").frames.kind == .unpaced && report("unpaced").frames.perSecond == 12
              && report("unpaced").frames.status == nil && report("unpaced").frames.captions == ["LAST FEW SECONDS"]
              && report("unpaced").frames.note == "This picture has no target rate.")
        check("Unpaced on a last reading: last measured, never a bare number",
              report("unpaced").frames.captions(lastReading: true) == ["LAST MEASURED"]
              && report("unpaced").frames.words(lastReading: true) == "Last measured.",
              "\(report("unpaced").frames.captions(lastReading: true))")
        check("Still preset reads Still, not last measured", report("still").frames.kind == .still && report("still").frames.word == "Still"
              && report("still").frames.note == "The picture is not changing, so no new frames are drawn.")
        check("sent_fps 0.0 is a still face, not an old brain", steady(["fps_age_s": 100.0, "sent_fps": 0.0]).frames.kind == .still)

        // Throttle attribution, one rule for now and for earlier.
        check("0x80008 at 60°C gives Slowed down.", steady(["temp_c": 60.0, "throttled": bits(["soft_temp_now", "soft_temp_ever"])]).verdict == "Slowed down.")
        check("Capped at 76°C: heat copy", steady(["temp_c": 76.0, "throttled": bits(["capped_now"])]).problems.first { $0.part == .speed }?.noticeDetail
              == "The processor is running slower than normal to stay cool. Give the back of the wall more room for air.")
        check("Capped at 60°C: neutral copy", steady(["temp_c": 60.0, "throttled": bits(["capped_now"])]).problems.first?.noticeDetail
              == "The processor is running slower than normal. Heat or low power can cause this.")
        check("Throttled at 82°C: the heat act only", parts(steady(["temp_c": 82.0, "throttled": bits(["throttled_now"])])) == ["act heat"])
        check("Undervolt now suppresses speed", parts(steady(["throttled": bits(["undervolt_now", "throttled_now", "capped_now"])])) == ["act power"])
        check("Earlier, soft limit only: while hot", row(steady(["throttled": bits(["soft_temp_ever"])]), .speed)?.subtitle == "While it was hot. Normal now.")
        check("Earlier, power only: while power was low", row(steady(["throttled": bits(["undervolt_ever", "throttled_ever"])]), .speed)?.subtitle == "While power was low. Normal now.")
        check("Earlier, both: either cause", row(steady(["throttled": bits(["undervolt_ever", "soft_temp_ever"])]), .speed)?.subtitle
              == "Heat or low power, at least once since the computer started. Normal now.")
        check("Earlier, capped only: either cause", row(steady(["throttled": bits(["capped_ever"])]), .speed)?.subtitle
              == "Heat or low power, at least once since the computer started. Normal now.")
        check("Undervolt earlier alone did not slow the processor", row(steady(["throttled": bits(["undervolt_ever"])]), .speed)?.value == "Full speed")
        let lowPowerOnly = steady(["throttled": bits(["undervolt_now", "undervolt_ever"])])
        check("Low power now without a slowdown bit: no Full speed row", parts(lowPowerOnly) == ["act power"]
              && row(lowPowerOnly, .speed) == nil && !lowPowerOnly.checks.contains { $0.value == "Full speed" })
        check("Legacy now: neutral slowed down", steady(["throttled": ["now": true, "ever": true]]).problems.first?.noticeDetail
              == "The processor is running slower than normal. Heat or low power can cause this.")

        // Thresholds, on the displayed value.
        let edge = steady(["temp_c": 79.6])
        check("79.6°C shows 80 and is hot", edge.temperature?.celsius == 80 && edge.temperature?.status == .hot && parts(edge) == ["act heat"])
        check("69.4°C is normal", steady(["temp_c": 69.4]).level == .steady && steady(["temp_c": 69.4]).temperature?.status == .normal)
        check("Loop 44.9 is steady", steady(["loop_age_s": 44.9]).level == .steady)
        check("Loop 45.0 is act", parts(steady(["loop_age_s": 45.0])) == ["act loop"])
        check("Loop under a minute says seconds", steady(["loop_age_s": 50.2]).problems.first?.noticeDetail.contains("have not updated for 50 seconds.") == true)
        func panels(_ attached: Bool, uptime: Int, detached: Double?, pending: Double?) -> HealthReport {
            steady(["uptime_s": uptime, "boot_s": uptime + 30,
                    "renderer": ["attached": attached, "connects": 1, "detached_s": detached.map { $0 as Any } ?? NSNull(), "pending_s": pending.map { $0 as Any } ?? NSNull()]])
        }
        check("Renderer missing at uptime 12 is watch", parts(panels(false, uptime: 12, detached: 12, pending: 11)) == ["watch panels"])
        check("A picture waiting inside the startup grace is not act", parts(panels(false, uptime: 40, detached: 40, pending: 44)) == ["watch panels"])
        check("A restart under 30 s reads Reconnecting", parts(panels(false, uptime: 3600, detached: 10, pending: 9)).isEmpty
              && row(panels(false, uptime: 3600, detached: 10, pending: 9), .panels)?.value == "Reconnecting")
        check("Renderer gone 31 s is act", parts(panels(false, uptime: 3600, detached: 31, pending: nil)) == ["act panels"])
        check("A picture waiting 30 s while attached is act", parts(panels(true, uptime: 3600, detached: nil, pending: 30)) == ["act panels"])
        check("Memory 119 is watch", parts(steady(["memory": ["total_mb": 990, "available_mb": 119]])) == ["watch memory"])
        check("Memory 120 is steady", parts(steady(["memory": ["total_mb": 990, "available_mb": 120]])).isEmpty)
        check("Memory 59 is act", parts(steady(["memory": ["total_mb": 990, "available_mb": 59]])) == ["act memory"])
        check("Storage 0.99 is watch", parts(steady(["storage": ["total_gb": 29.1, "free_gb": 0.99]])) == ["watch storage"])
        check("Storage 0.24 is act", parts(steady(["storage": ["total_gb": 29.1, "free_gb": 0.24]])) == ["act storage"])
        check("fps_age_s 12.0 is live", steady(["fps_age_s": 12.0]).frames.kind == .paced)
        check("fps_age_s 12.1 falls back to sent_fps", steady(["fps_age_s": 12.1]).frames.kind == .unpaced)
        check("sent_fps 0.4 is Still", steady(["fps_age_s": 100.0, "sent_fps": 0.4]).frames.kind == .still)
        check("Unpaced 1.0 has no status", steady(["fps_age_s": 100.0, "sent_fps": 1.0]).frames.status == nil)
        check("Paced 59 of 60 is Smooth", steady(["fps": 59.0, "fps_age_s": 1.0]).frames.status == "Smooth" && steady(["fps": 59.0, "fps_age_s": 1.0]).level == .steady)
        check("A stopped loop is not also behind", parts(steady(["loop_age_s": 60.0, "fps": 20.0, "fps_age_s": 1.0])) == ["act loop"])

        // Temperature window.
        let steadyTile = steadyReport.temperature
        check("A full log covers the last hour", steadyTile?.window == "LAST HOUR" && steadyTile?.trace.last?.ageS == 0
              && steadyTile?.trace.count == 61)
        let lows = ((HealthFixtures.json("steady")?["temp_log"] as? [[Double]]) ?? []).map { HealthFormat.celsius($0[1]) } + [54]
        check("The range spans the samples and this reading", steadyTile?.low == lows.min() && steadyTile?.high == lows.max()
              && steadyTile?.rangeCaption == "\(lows.min()!) TO \(lows.max()!)°C")
        let young = steady(["temp_log": (0..<13).map { [Double(720 - $0 * 60), 50.0 + Double($0 % 3)] }])
        check("A 12 minute log says so", young.temperature?.window == "LAST 12 MIN" && young.temperature?.windowWords == "the last 12 minutes"
              && young.temperature?.rangeWords == "Between 50 and 54°C in the last 12 minutes.", young.temperature?.rangeWords ?? "none")
        check("Temperature for VoiceOver", young.temperature?.accessibilityValue == "54 degrees Celsius, normal. Between 50 and 54 over the last 12 minutes.",
              young.temperature?.accessibilityValue ?? "")
        check("Collecting while the log is short", report("collecting").temperature?.collecting == true && report("collecting").temperature?.trace.isEmpty == true)

        // Summaries.
        check("Two watches", steady(["temp_c": 74.0, "memory": ["total_mb": 990, "available_mb": 100]]).summary
              == "Two things to keep an eye on. Everything else is normal.")
        check("One act and one watch", steady(["temp_c": 74.0, "memory": ["total_mb": 990, "available_mb": 50]]).summary
              == "One problem needs attention. One more thing to keep an eye on.")
        check("One act alone", report("hot").summary == "One problem needs attention. What to do is below.")
        let twoAndOne = steady(["temp_c": 74.0, "memory": ["total_mb": 990, "available_mb": 50], "loop_age_s": 90.0])
        check("Two acts and a watch", twoAndOne.summary == "Two problems, most urgent first. One more thing to keep an eye on."
              && parts(twoAndOne) == ["act loop", "act memory", "watch heat"], "\(twoAndOne.summary) \(parts(twoAndOne))")

        // Formats.
        check("duration(93784) is 1 day, 2 hours", HealthFormat.duration(93784) == "1 day, 2 hours")
        check("duration(59) is less than a minute", HealthFormat.duration(59) == "less than a minute")
        check("duration(18720) is 5 hours, 12 minutes", HealthFormat.duration(18720) == "5 hours, 12 minutes")
        check("ago(4) is just now", HealthFormat.ago(4) == "just now")
        check("ago(25) is 25 seconds ago", HealthFormat.ago(25) == "25 seconds ago")
        check("ago(61) is 1 minute ago", HealthFormat.ago(61) == "1 minute ago")
        check("Gigabytes", HealthFormat.gigabytes(11.4) == "11 GB" && HealthFormat.gigabytes(3.24) == "3.2 GB"
              && HealthFormat.gigabytes(0.8) == "820 MB" && HealthFormat.gigabytes(9.97) == "10 GB")
        check("Megabytes", HealthFormat.megabytes(412) == "412 MB" && HealthFormat.megabytes(8192) == "8.0 GB")

        // Decoding.
        check("A body that is not an object fails", Vitals(json: [1, 2]) == nil && Vitals(json: "ok") == nil)
        check("An empty object decodes with defaults", Vitals(json: [String: Any]()).map { $0.fps == 0 && $0.uptimeS == 0 && $0.tempLog == nil } == true)
        check("A boolean is never a number", Vitals(json: ["temp_c": true, "fps": false])?.tempC == nil)
        check("The legacy throttle is not detailed", fixture("legacy").throttle?.detailed == false && fixture("steady").throttle?.detailed == true)
        check("Renderer keys", fixture("panels-off").renderer == Vitals.RendererStatus(attached: false, connects: 1, detachedS: 45, pendingS: 44.8))
        // A finite value past Int's range used to trap in Int(_:). Each
        // reading below reaches every whole-number conversion once: the
        // first through a stopped loop, the second paced, the third unpaced.
        let huge = 1e19
        let past: [[String: Any]] = [
            ["fps": huge, "fps_target": huge, "temp_c": huge, "temp_log": [[huge, huge], [120.0, 50.0], [60.0, 50.0]],
             "uptime_s": huge, "boot_s": huge, "loop_age_s": huge,
             "renderer": ["attached": false, "connects": huge, "detached_s": huge, "pending_s": huge],
             "memory": ["total_mb": huge, "available_mb": -huge], "storage": ["total_gb": huge, "free_gb": huge]],
            ["fps": huge, "fps_age_s": 1.0, "fps_target": huge, "temp_c": -huge, "uptime_s": -huge, "loop_age_s": 0.5],
            ["fps": 1.0, "fps_age_s": huge, "sent_fps": huge, "uptime_s": 100, "loop_age_s": 0.5],
        ]
        let held = past.compactMap { Vitals(json: $0, receivedAt: now) }.map(HealthReport.init(vitals:))
        check("Values past Int's range are held, not trapped", held.count == 3 && held[0].vitals.uptimeS == 1_000_000_000_000
              && held[0].problems.map(\.part).contains(.loop) && held[1].frames.kind == .paced && held[2].frames.kind == .unpaced,
              "\(held.map { $0.problems.map(\.part.rawValue) })")
        check("Formats hold values past Int's range", HealthFormat.ago(huge).hasSuffix("days ago") && HealthFormat.gigabytes(huge).hasSuffix(" GB")
              && HealthFormat.celsius(-huge) == -1_000_000_000_000 && HealthFormat.whole(.nan) == 0)

        // The page's state.
        func screen(_ link: HealthLink, _ report: HealthReport?, age: TimeInterval = 5, lastFailed: Bool = false,
                    manualFailed: Bool = false, checking: Bool = false, attempted: Bool = true) -> HealthScreen {
            HealthScreen(link: link, report: report, now: now.addingTimeInterval(age), lastFailed: lastFailed,
                         manualFailed: manualFailed, checking: checking, attempted: attempted)
        }
        let fresh = screen(.live, steadyReport)
        check("Fresh reading", fresh.phase == .report && fresh.verdict == "Running well." && fresh.freshness == "Checked just now" && fresh.check == "Check now")
        check("Freshness ages", screen(.live, steadyReport, age: 25).freshness == "Checked 25 seconds ago")
        let hiccup = screen(.live, steadyReport, age: 12, lastFailed: true)
        check("One failed poll keeps the verdict", hiccup.phase == .report && hiccup.verdict == "Running well." && !hiccup.dimmed
              && hiccup.freshness == "Could not check. Last reading 12 seconds ago.", hiccup.freshness ?? "")
        let manual = screen(.live, steadyReport, age: 12, lastFailed: true, manualFailed: true)
        check("A failed Check now is stale", manual.phase == .stale && manual.verdict == "No new reading." && manual.dimmed
              && manual.freshness == "Last reading 12 seconds ago" && manual.report != nil)
        check("An old reading is stale", screen(.live, steadyReport, age: 31).phase == .stale)
        check("A reading carried in is not stale before the first check", screen(.live, steadyReport, age: 45, checking: true, attempted: false).phase == .report)
        check("A stale reading counts its problems", screen(.live, report("hot"), age: 60, lastFailed: true).freshness == "Last reading 1 minute ago. It showed one problem.")
        check("Loading", screen(.live, nil, checking: true).phase == .loading && screen(.live, nil).verdict == "Checking the wall.")
        let unreadable = screen(.live, nil, lastFailed: true)
        check("Unreadable", unreadable.phase == .unreadable && unreadable.check == "Try again" && unreadable.verdict == "No reading.")
        let offline = screen(.offline, steadyReport, age: 300)
        check("Offline keeps the last reading", offline.phase == .offline && offline.dimmed && offline.lookAgain && offline.addressLink
              && offline.check == nil && offline.freshness == "Last reading 5 minutes ago" && offline.verdict == "Can’t reach the wall.")
        check("Offline without a reading", screen(.offline, nil).report == nil && screen(.offline, nil).freshness == nil)
        check("Searching shows nothing else", screen(.searching, steadyReport).report == nil && screen(.searching, nil).dot == .progress)
        let chosen = screen(.standIn(chosen: true), steadyReport)
        check("Chosen stand-in offers the look", chosen.lookAgain && chosen.report == nil && chosen.verdict == "No wall connected.")
        let automatic = screen(.standIn(chosen: false), nil)
        check("Automatic stand-in offers nothing", !automatic.lookAgain && automatic.summary == "Tessera is running on this phone while it looks for your wall.")
        check("Automatic stand-in shows it is looking, the chosen one does not", automatic.dot == .progress && chosen.dot == .quiet)
        check("Loading has no Check now beside its spinner", screen(.live, nil, checking: true).check == nil && screen(.live, nil).check == nil)
        let retrying = screen(.live, nil, lastFailed: true, checking: true)
        check("Try again stays while its read is in flight", retrying.phase == .loading && retrying.check == "Try again")
        check("Unreadable does not say try again twice", unreadable.summary == "The wall is connected, but its health reading did not arrive.")
        check("Stale summary", manual.summary == "The wall is connected, but the latest check got no reply. The last reading is below.")
        let lastSeconds = screen(.live, steadyReport, age: 4, lastFailed: true, manualFailed: true)
        check("A last reading is never just now", lastSeconds.phase == .stale && lastSeconds.freshness == "Last reading a few seconds ago",
              lastSeconds.freshness ?? "")
        let dropped = screen(.offline, steadyReport, age: 2)
        check("Offline within a minute: before the connection dropped", dropped.freshness == "Last reading before the connection dropped",
              dropped.freshness ?? "")
        check("Offline with a problem counts it", screen(.offline, report("hot"), age: 20).freshness
              == "Last reading before the connection dropped. It showed one problem.")
        check("Hiccup under 10 s is not just now", screen(.live, steadyReport, age: 3, lastFailed: true).freshness == "Could not check. Last reading a few seconds ago.")
        check("Checks header: all checks when live", fresh.checksHeader == "All checks")
        check("Checks header: at last reading when stale or offline", manual.checksHeader == "Checks at last reading"
              && offline.checksHeader == "Checks at last reading")
        check("Other checks: all normal only when live", fresh.othersTitle == "Other checks, all normal"
              && manual.othersTitle == "Other checks at last reading" && offline.othersTitle == "Other checks at last reading")
        let lone = screen(.live, report("undervolt"))
        check("A lone problem's notice drops the title the headline already says", lone.verdict == "Low on power."
              && !lone.titlesNotice(report("undervolt").problems[0]))
        let loneAndWatch = steady(["temp_c": 74.0, "memory": ["total_mb": 990, "available_mb": 50]])
        let loneAndWatchScreen = screen(.live, loneAndWatch)
        check("A lone act drops its title, its watch keeps one", !loneAndWatchScreen.titlesNotice(loneAndWatch.problems[0])
              && loneAndWatchScreen.titlesNotice(loneAndWatch.problems[1]))
        check("Several problems keep every title", screen(.live, several).verdict == "Needs attention."
              && several.problems.allSatisfy { screen(.live, several).titlesNotice($0) })
        check("A watch keeps its title", report("warm").problems.allSatisfy { screen(.live, report("warm")).titlesNotice($0) })
        check("A stale lone problem keeps its title", screen(.live, report("undervolt"), age: 60).titlesNotice(report("undervolt").problems[0]))
        check("Panels detail on a live page offers the restart", screen(.live, panelsOff).detail(for: panelsOff.problems[0]).contains("Restart the panel program below"))
        check("Panels detail on a last reading does not point at a button", !screen(.offline, panelsOff, age: 300).detail(for: panelsOff.problems[0]).contains("below"))
        check("Frames on a last reading: no Smooth, no window, the target stays", steadyReport.frames.statusWord(lastReading: true) == nil
              && steadyReport.frames.captions(lastReading: true) == ["TARGET 60"]
              && steadyReport.frames.words(lastReading: true) == "Target 60."
              && steadyReport.frames.captions(lastReading: false) == ["LAST FEW SECONDS", "TARGET 60"]
              && steadyReport.frames.statusWord(lastReading: false) == "Smooth")
        check("Behind stays on a last reading", report("behind").frames.statusWord(lastReading: true) == "Behind")
        check("Temperature spoken on a last reading: no normal, hot stays", steadyTile?.accessibilityValue(lastReading: true).hasPrefix("54 degrees Celsius.") == true
              && steadyTile?.accessibilityValue(lastReading: false).hasPrefix("54 degrees Celsius, normal.") == true
              && hot.temperature?.accessibilityValue(lastReading: true).hasPrefix("82 degrees Celsius, hot.") == true,
              steadyTile?.accessibilityValue(lastReading: true) ?? "")
        check("Temperature on a last reading: no Normal, Hot stays", steadyTile?.statusWord(lastReading: true) == nil
              && hot.temperature?.statusWord(lastReading: true) == "Hot" && steadyTile?.statusWord(lastReading: false) == "Normal")

        // Restarting the panel program.
        check("Restart said relaunching", PanelProgram.answer(status: 200, said: "renderer relaunching (1 stopped)") == .relaunching)
        check("Restart said not running", PanelProgram.answer(status: 200, said: "the renderer was not running") == .notRunning)
        check("Restart could not look", PanelProgram.answer(status: 200, said: "could not look for the renderer") == .couldNotLook)
        check("Restart 409 and 503", PanelProgram.answer(status: 409, said: nil) == .busy && PanelProgram.answer(status: 503, said: nil) == .unsupported)
        check("Restart unanswered", PanelProgram.answer(status: nil, said: nil) == .noAnswer && PanelProgram.answer(status: 500, said: nil) == .noAnswer)
        check("A restart that worked needs no note", PanelProgram.note(.relaunching, stillFailing: false) == nil)
        check("Not running keeps the plug advice", PanelProgram.note(.notRunning, stillFailing: true)?.contains("at the plug") == true)

        // Copy rules, over every sentence the model can produce.
        var strings: [String] = []
        let links: [HealthLink] = [.live, .searching, .offline, .standIn(chosen: true), .standIn(chosen: false)]
        var reports = HealthFixtures.names.map(report)
        reports += [edge, young, twoAndOne, legacyStill, behindWarm, behindCapped, steady(["loop_age_s": 50.2]),
                    steady(["temp_c": 60.0, "throttled": bits(["capped_now"])]),
                    steady(["throttled": bits(["undervolt_ever", "soft_temp_ever"])])]
        for r in reports {
            // One screen never calls the temperature Normal beside a notice
            // that says the processor slowed to stay cool.
            if r.problems.contains(where: { $0.noticeDetail.contains("to stay cool") }) {
                check("Heat-slowed \(r.verdict) is not Normal", r.temperature.map { $0.status != .normal } ?? true)
            }
            // No row calls the processor full speed beside a heat or speed act.
            if r.problems.contains(where: { $0.level == .act && [.heat, .speed, .power].contains($0.part) }) {
                check("\(r.verdict) lists no full speed", !r.checks.contains { $0.value == "Full speed" })
            }
            strings += [r.verdict, r.summary, r.landingLine, r.footnote]
            strings += r.problems.compactMap(\.readOnlyDetail)
            strings += r.frames.captions(lastReading: true) + [r.frames.words(lastReading: true) ?? "", r.temperature?.note ?? ""]
            strings += r.problems.flatMap { [$0.verdict, $0.noticeTitle, $0.noticeDetail, $0.rowValue, $0.short] }
            strings += r.checks.flatMap { [$0.title, $0.value, $0.subtitle ?? "", $0.explanation] }
            if let t = r.temperature {
                strings += [t.status.word, t.window ?? "", t.windowWords ?? "", t.rangeCaption ?? "", t.rangeWords ?? "", t.accessibilityValue]
            }
            strings += r.frames.captions + [r.frames.word ?? "", r.frames.status ?? "", r.frames.note ?? "", r.frames.words ?? "", r.frames.accessibilityValue]
            for link in links {
                for (failed, manual) in [(false, false), (true, false), (true, true)] {
                    let s = screen(link, r, age: 45, lastFailed: failed, manualFailed: manual)
                    strings += [s.verdict, s.summary, s.freshness ?? "", s.check ?? "", s.checksHeader, s.othersTitle]
                    strings += r.problems.map(s.detail(for:))
                }
            }
        }
        for link in links {
            let s = screen(link, nil, lastFailed: true)
            strings += [s.verdict, s.summary, s.freshness ?? "", s.check ?? ""]
        }
        strings += [HealthReport.Temperature.collectingNote, HealthReport.Temperature.noHistoryNote, HealthReport.Frames.stillNote,
                    HealthReport.Frames.legacyNote, HealthReport.Frames.unpacedNote, HealthReport.Frames.startingNote]
        for answer in [PanelProgram.Answer.relaunching, .notRunning, .couldNotLook, .busy, .unsupported, .noAnswer] {
            strings += [PanelProgram.note(answer, stillFailing: true) ?? ""]
        }
        strings += HealthPart.allCases.map(\.title)
        let banned: [(String, String)] = [("\u{2014}", "em dash"), ("\u{2013}", "en dash"), (";", "semicolon"), ("\u{00B7}", "middot"), ("\u{00D7}", "multiplication sign")]
        for (character, name) in banned {
            let offenders = strings.filter { $0.contains(character) }
            check("No \(name) in any sentence", offenders.isEmpty, offenders.first ?? "")
        }
        check("Every sentence the model makes was checked", strings.count > 400, "\(strings.count)")

        let failed = checks.filter { $0["passed"] as? Bool == false }.count
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: ["passed": checks.count - failed, "failed": failed, "checks": checks], options: [.sortedKeys]))
        if failed > 0 { exit(1) }
    }
}
