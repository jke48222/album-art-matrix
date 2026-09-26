import Foundation

@main struct TeachModelChecks {
    static func main() throws {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ value: Bool) {
            precondition(value, name)
            checks.append(["name": name, "passed": value])
        }
        let data = Data(#"{"enabled":true,"songs":[{"id":"beyonce|deja vu","title":"Déjà Vu","artist":"Beyoncé","album":"B’Day","how":["preview","ear"],"matched":12,"landmarks":782,"art_url":"https://example.com/cover.jpg"}],"min_score":15,"teacher":{"by_ear":true,"learning":null,"last_learned":{"id":"beyonce|deja vu","title":"Déjà Vu","artist":"Beyoncé"}},"last_match":{"id":"beyonce|deja vu","title":"Déjà Vu","artist":"Beyoncé","score":44}}"#.utf8)
        let list = try JSONDecoder().decode(TaughtList.self, from: data)
        let song = list.songs[0]
        check("local library enabled", list.enabled == true)
        check("diacritic insensitive artist", song.matches("beyonce"))
        check("case insensitive title", song.matches("DEJA"))
        check("unordered multiword search", song.matches("beyonce deja"))
        check("all search words must match", !song.matches("beyonce ocean"))
        check("album included in search", song.matches("Day"))
        check("whitespace-only search includes all", song.matches("   \n  "))
        check("provenance distinct", song.sources == "Preview · This room")
        check("artwork identity preserved", song.art_url == "https://example.com/cover.jpg")
        check("actual score preserved", list.last_match?.score == 44)
        check("threshold separate from confidence", list.min_score == 15)
        check("completed receipt decoded", list.teacher?.last_learned?.title == "Déjà Vu")
        let legacy = try JSONDecoder().decode(TaughtList.self, from: Data(#"{"songs":[{"id":"a","title":"One","artist":"Artist","how":["told"],"matched":0}]}"#.utf8))
        check("legacy library decodes", legacy.songs.count == 1)
        check("legacy art optional", legacy.songs[0].art_url == nil)
        check("legacy teacher optional", legacy.teacher == nil)
        check("manual provenance", legacy.songs[0].sources == "By name")
        if CommandLine.arguments.count > 1 {
            let output: [String: Any] = ["checks": checks, "passed": checks.count, "failed": 0]
            try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        print("Teach models: \(checks.count) checks passed")
    }
}
