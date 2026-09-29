import Foundation

// Checks the About and App design models without SwiftUI. Compiled with
// tessera/Tessera/HomeDesign.swift, AboutModels.swift and WallGrid.swift by
// scripts/test_about_models.py, which prints the JSON report.

@main struct AboutModelChecks {
    static func main() throws {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ ok: Bool) { checks.append(["name": name, "passed": ok]) }
        let en = Locale(identifier: "en_US")
        let all = OpeningAssets.all

        // Openings: what a saved style plays in each design.
        check("Sting plays on Panel", OpeningStyle.kind(.sting, in: .classic, assets: all) == .sting)
        check("Film has nothing to play on Panel", OpeningStyle.kind(.film, in: .classic, assets: all) == OpeningKind.none)
        check("Mark on Panel plays nothing", OpeningStyle.kind(.mark, in: .classic, assets: all) == OpeningKind.none)
        check("Mark on the iPod plays the iPod film", OpeningStyle.kind(.mark, in: .ipod, assets: all) == .iPodFilm)
        check("Film on the iPod plays the iPod film", OpeningStyle.kind(.film, in: .ipod, assets: all) == .iPodFilm)
        // The mark's films are missing, but the room's geometry is there, so
        // OpeningAssets.bundled still counts the mark (RoomIntro2 draws it).
        let geometryOnly = OpeningAssets(sting: true, stingKeyed: true, roomFilm: false, roomMark: true, iPodFilm: true)
        check("Mark in the room without its films still plays from the geometry", OpeningStyle.kind(.mark, in: .room, assets: geometryOnly) == .roomMark)
        var noTrack = all
        noTrack.roomFilm = false
        check("Film in the room without its track plays nothing", OpeningStyle.kind(.film, in: .room, assets: noTrack) == OpeningKind.none)
        check("None in the room is none", OpeningStyle.kind(.none, in: .room, assets: all) == OpeningKind.none)
        check("Sting in the light needs the keyed film", OpeningStyle.kind(.stingRoom, in: .room, assets: OpeningAssets(sting: true, stingKeyed: false, roomFilm: true, roomMark: true, iPodFilm: true)) == OpeningKind.none)
        check("A garbled saved style reads as the sting", OpeningStyle.saved("garbage") == .sting)
        check("No saved style reads as the sting", OpeningStyle.saved(nil) == .sting)
        check("The QA harness's none is a real choice", OpeningStyle.saved("none") == OpeningStyle.none)
        check("Panel offers the stings and None only", OpeningStyle.choices(in: .classic, assets: all) == [.sting, .stingInLight, .none])
        let ipod = OpeningStyle.choices(in: .ipod, assets: all)
        check("The iPod offers its film", ipod.contains(.iPodFilm))
        check("The iPod does not offer the room's mark", !ipod.contains(.roomMark) && !ipod.contains(.roomFilm))
        check("The room offers its film and mark", OpeningStyle.choices(in: .room, assets: all) == [.sting, .stingInLight, .roomFilm, .roomMark, .none])
        check("Nothing missing from the bundle is offered", OpeningStyle.choices(in: .room, assets: noTrack).contains(.roomFilm) == false)
        check("Every choice writes a style that reads back as itself", Design.allCases.allSatisfy { design in
            OpeningStyle.choices(in: design, assets: all).allSatisfy { OpeningStyle.kind($0.style, in: design, assets: all) == $0 }
        })
        check("Both films write film", OpeningKind.roomFilm.style == .film && OpeningKind.iPodFilm.style == .film)
        check("The keyed sting writes sting-room", OpeningKind.stingInLight.style.rawValue == "sting-room")
        check("Only the stings are the root's", OpeningKind.allCases.filter(\.isSting) == [.sting, .stingInLight])
        check("Design order is Room, Panel, iPod", Design.displayOrder == [.room, .classic, .ipod])
        check("Designs keep their saved names", Design.allCases.map(\.rawValue) == ["classic", "ipod", "room"])

        // The version.
        check("Version and build", AppVersion.display(["CFBundleShortVersionString": "1.0", "CFBundleVersion": "1"]) == "1.0 (1)")
        check("A build equal to the version is not repeated", AppVersion.display(["CFBundleShortVersionString": "1.0", "CFBundleVersion": "1.0"]) == "1.0")
        check("A missing build shows the version alone", AppVersion.display(["CFBundleShortVersionString": "1.0"]) == "1.0")
        check("Nothing to read says so", AppVersion.display([:]) == "Version unavailable" && AppVersion.display(nil) == "Version unavailable")
        check("The version is read aloud with its build", AppVersion.spoken(["CFBundleShortVersionString": "1.0", "CFBundleVersion": "1"]) == "Version 1.0, build 1")
        let full: [String: Any] = ["CFBundleShortVersionString": "1.0", "CFBundleVersion": "1"]
        check("The Settings detail names the version once", AppVersion.detail(full) == "Version 1.0 (1)")
        check("No version is never Version Version unavailable", AppVersion.detail(nil) == "Version unavailable")
        check("A build alone is never Version Build 1", AppVersion.detail(["CFBundleVersion": "1"]) == "Build 1")
        check("The masthead is one stop with the name", AppVersion.heading(full) == "Tessera, version 1.0, build 1")
        check("The masthead without a version still says so", AppVersion.heading(nil) == "Tessera, version unavailable")

        // The tuning count.
        check("A float over half a step counts", TuningPeek.changed(values: ["dither": 0.3], defaults: ["dither": 0.0], steps: ["dither": 0.1]) == 1)
        check("A float under half a step does not", TuningPeek.changed(values: ["dither": 0.04], defaults: ["dither": 0.0], steps: ["dither": 0.1]) == 0)
        check("A flipped bool counts once", TuningPeek.changed(values: ["nearest_colour": 0], defaults: ["nearest_colour": 1], steps: ["nearest_colour": 1]) == 1)
        check("A name missing from the defaults is skipped", TuningPeek.changed(values: ["new_knob": 5], defaults: [:], steps: ["new_knob": 1]) == 0)
        check("parse needs knobs", TuningPeek.parse(["values": ["dither": 0.3], "defaults": ["dither": 0.0]]) == nil)
        check("parse needs values", TuningPeek.parse(["defaults": [:], "knobs": []]) == nil)
        let real = Data(#"{"values":{"nearest_colour":false,"dither":0.3,"black_point":4},"defaults":{"nearest_colour":true,"dither":0.0,"black_point":4},"knobs":[{"name":"nearest_colour","group":"Dark end","kind":"bool","min":0,"max":1,"step":1},{"name":"dither","group":"Panel","kind":"float","min":0,"max":10,"step":0.1},{"name":"black_point","group":"Dark end","kind":"int","min":0,"max":40,"step":1}]}"#.utf8)
        let parsed = (try? JSONSerialization.jsonObject(with: real)) as? [String: Any] ?? [:]
        check("JSON true and false count from real bytes", TuningPeek.parse(parsed) == 2)
        let hearing = Data(#"{"values":{"knock":false,"dither":0.0},"defaults":{"knock":true,"dither":0.0},"knobs":[{"name":"knock","group":"Hearing","kind":"bool","step":1},{"name":"dither","group":"Panel","kind":"float","step":0.1}]}"#.utf8)
        let knock = (try? JSONSerialization.jsonObject(with: hearing)) as? [String: Any] ?? [:]
        check("Knocks switched off count, as on the tuning page", TuningPeek.parse(knock) == 1)
        let stepless = Data(#"{"values":{"odd":0.5},"defaults":{"odd":0.0},"knobs":[{"name":"odd","group":"Other"}]}"#.utf8)
        let noStep = (try? JSONSerialization.jsonObject(with: stepless)) as? [String: Any] ?? [:]
        check("A knob without a step takes the store's 0.01", TuningPeek.parse(noStep) == 1)
        check("Bools read as 1 and 0", TuningPeek.numbers(["a": true, "b": false, "c": 3, "d": 0.5]) == ["a": 1, "b": 0, "c": 3, "d": 0.5])
        check("Status at defaults", TuningPeek.status(.count(0), link: .live) == "All settings at their defaults")
        check("Status with one change", TuningPeek.status(.count(1), link: .live) == "1 setting changed from its default")
        check("Status with three changes", TuningPeek.status(.count(3), link: .live) == "3 settings changed from their defaults")
        check("Status while reading", TuningPeek.status(.reading, link: .live) == "Reading your wall")
        check("Status without a store", TuningPeek.status(.unavailable, link: .live) == "Not available on this wall")
        check("Status after a failed read", TuningPeek.status(.failed, link: .live) == "Couldn’t read the tuning")
        check("A count is never shown away from the wall", TuningPeek.status(.count(3), link: .offline) == "Needs your wall"
              && TuningPeek.status(.count(3), link: .standIn) == "Needs your wall"
              && TuningPeek.status(.count(3), link: .searching) == "Waiting for your wall")
        check("The row opens live, even after a failed read", TuningPeek.opens(.failed, link: .live) && TuningPeek.opens(.reading, link: .live))
        check("The row stays shut without a store or a wall", !TuningPeek.opens(.unavailable, link: .live) && !TuningPeek.opens(.count(0), link: .offline))

        // The grid.
        check("One panel", WallGrid(json: ["cols": 1, "rows": 1, "tile": 64])?.panelsText == "One panel")
        check("Nine panels", WallGrid(json: ["cols": 3, "rows": 3, "tile": 64])?.panelsText == "9 panels, 3 x 3")
        check("Nine panels size", WallGrid(json: ["cols": 3, "rows": 3, "tile": 64, "width": 192, "height": 192])?.sizeText(locale: en) == "192 x 192, 36,864 lights")
        check("Zero columns is no grid", WallGrid(json: ["cols": 0, "rows": 1, "tile": 64]) == nil)
        let wide = WallGrid(json: ["cols": 2, "rows": 1, "tile": 64])
        check("A rectangle keeps both sides", wide?.sizeText(locale: en) == "128 x 64, 8,192 lights")
        check("A rectangle counts its panels", wide?.panelsText == "2 panels, 2 x 1")

        // The Wall row, in its order.
        let one = WallGrid(cols: 1, rows: 1, tile: 64)
        func line(_ link: AboutFacts.Link, _ grid: WallGrid?, _ side: Int, _ learned: Bool) -> (String, String?) {
            let l = AboutFacts.wallLine(link: link, grid: grid, side: side, learned: learned, previewSide: 64, locale: en)
            return (l.value, l.subline)
        }
        check("The stand-in is the phone's preview, even never connected", line(.standIn, nil, 192, false) == ("64 x 64 preview", "No wall connected"))
        check("The stand-in wins over a grid", line(.standIn, one, 64, true) == ("64 x 64 preview", "No wall connected"))
        check("Live states its grid", line(.live, one, 64, true) == ("64 x 64, 4,096 lights", "One panel"))
        check("Live without a grid falls back to the side", line(.live, nil, 64, true) == ("64 x 64, 4,096 lights", nil))
        check("Away with a learned size is last known", line(.offline, one, 64, true) == ("64 x 64, 4,096 lights", "One panel, last known"))
        check("Away without a grid is last known", line(.searching, nil, 192, true) == ("192 x 192, 36,864 lights", "Last known"))
        check("Never connected says so, offline", line(.offline, nil, 192, false) == ("Not connected yet", nil))
        check("Never connected says so, searching", line(.searching, nil, 192, false) == ("Not connected yet", nil))
        check("Details size live", AboutFacts.sizeLine(link: .live, grid: one, side: 64, learned: true) == "64 x 64, one panel")
        check("Details size never connected", AboutFacts.sizeLine(link: .offline, grid: nil, side: 192, learned: false) == "not connected yet")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        check("Last reply in minutes", AboutFacts.lastReply(now.addingTimeInterval(-12 * 60), now: now, locale: en) == ", last reply 12 minutes ago")
        check("Under a minute Offline stands alone", AboutFacts.lastReply(now.addingTimeInterval(-20), now: now, locale: en) == "")
        check("From a minute the reply is timed", AboutFacts.lastReply(now.addingTimeInterval(-60), now: now, locale: en) == ", last reply 1 minute ago")
        check("No last reply adds nothing", AboutFacts.lastReply(nil, now: now) == "")

        // Copy details.
        let details = AboutDetails.text(version: "1.0 (1)", iOS: "26.5", host: "album-matrix.local:8788", status: "Connected",
                                        size: AboutFacts.sizeLine(link: .live, grid: one, side: 64, learned: true), design: Design.room.name,
                                        opening: OpeningKind.sting.title)
        check("Copy details reads as specified", details == "Tessera 1.0 (1)\niOS 26.5 on iPhone\nWall: album-matrix.local:8788\nStatus: Connected\nSize: 64 x 64, one panel\nDesign: Room\nOpening: Record sting")

        // House rules on every string these models show.
        var copy = OpeningKind.allCases.flatMap { [$0.title, $0.detail] } + Design.allCases.flatMap { [$0.name, $0.summary] }
        copy += [details, TuningPeek.status(.failed, link: .live), TuningPeek.status(.count(2), link: .live)]
        copy += [line(.standIn, nil, 64, false).0, line(.offline, one, 64, true).1 ?? ""]
        let banned: [Character] = ["\u{2014}", "\u{2013}", ";", "\u{00B7}", "\u{00D7}"]
        check("No em dash, en dash, semicolon, middot or multiplication sign", copy.allSatisfy { text in !text.contains { banned.contains($0) } })
        check("Copy details has no multiplication sign", !details.contains("\u{00D7}"))

        let failed = checks.filter { $0["passed"] as? Bool == false }.count
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: ["passed": checks.count - failed, "failed": failed, "checks": checks], options: [.sortedKeys]))
        if failed > 0 { exit(1) }
    }
}
