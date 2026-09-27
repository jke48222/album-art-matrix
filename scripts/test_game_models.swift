import Foundation

@main struct GameModelChecks {
    static func main() async throws {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ value: Bool) {
            checks.append(["name": name, "passed": value])
            if !value { print("FAIL: \(name)") }
        }
        let decoder = JSONDecoder()
        let activeData = Data(#"{"running":true,"seq":12,"session_id":"session-A","on_wall":true,"starting":null,"game":{"name":"wordle","title":"Wordle","players":["You","Jalen"],"seq":2,"over":false,"won":false,"message":"Four left.","rows":[{"word":"slate","marks":"xxgxg"}],"keys":{"a":"g"},"guesses_left":5,"turn":"Jalen","voice":true},"scores":{"You":{"played":3,"won":2,"streak":1,"best":2}},"voice_words":["crane"]}"#.utf8)
        let active = try decoder.decode(GameStatus.self, from: activeData)
        check("active session identity retained", active.session_id == "session-A")
        check("wall destination retained", active.on_wall == true)
        check("player identity and order retained", active.game?.players == ["You", "Jalen"])
        check("opaque board data retained", active.game?.state["rows"][0]["word"].string == "slate")
        check("keyboard state retained", active.game?.state["keys"]["a"].string == "g")
        check("game scoring retained", active.scores?["You"]?.won == 2)
        let idle = try decoder.decode(GameStatus.self, from: Data(#"{"running":false,"seq":0,"game":null}"#.utf8))
        check("legacy idle response remains valid", !idle.running && idle.session_id == nil)
        let legacy = try decoder.decode(GameStatus.self, from: Data(#"{"running":true,"seq":2,"game":{"name":"wordle","title":"Wordle"}}"#.utf8))
        check("legacy active response remains valid", legacy.game?.name == "wordle" && legacy.on_wall == nil)
        for (label, json) in [
            ("empty acknowledgement is rejected", "{}"),
            ("running without a game is rejected", #"{"running":true,"seq":1,"game":null}"#),
            ("stopped with an active game is rejected", #"{"running":false,"seq":1,"game":{"name":"wordle","title":"Wordle"}}"#),
            ("negative sequence is rejected", #"{"running":false,"seq":-1,"game":null}"#),
            ("overflow sequence is rejected", #"{"running":false,"seq":999999999999999999999999999999,"game":null}"#),
            ("wrong sequence type is rejected", #"{"running":false,"seq":"2","game":null}"#),
            ("missing required sequence is rejected", #"{"running":false,"game":null}"#)
        ] {
            check(label, (try? decoder.decode(GameStatus.self, from: Data(json.utf8))) == nil)
        }
        check("positive infinity cannot become Int", JSONValue.number(.infinity).int == nil)
        check("negative infinity cannot become Int", JSONValue.number(-.infinity).int == nil)
        check("NaN cannot become Int", JSONValue.number(.nan).int == nil)
        check("rounded upper Int boundary is rejected", JSONValue.number(Double(Int.max)).int == nil)
        check("minimum Int boundary is safe", JSONValue.number(Double(Int.min)).int == Int.min)
        check("ordinary integer survives", JSONValue.number(42).int == 42)
        check("negative array index is safe", JSONValue.array([.string("one")])[-1].isNull)
        check("missing key is safe", JSONValue.object([:])["absent"].isNull)
        check("booleans are not numeric moves", JSONValue.bool(true).int == nil)

        var steering = GameSteeringBuffer()
        steering.offer(0.2, session: "A", now: 100)
        steering.offer(0.8, session: "A", now: 100.1)
        check("steering coalesces to the latest position", steering.take(session: "A", now: 100.2) == 0.8)
        check("steering is consumed exactly once", steering.take(session: "A", now: 100.2) == nil)
        steering.offer(0.4, session: "A", now: 100)
        check("old steering cannot enter a new session", steering.take(session: "B", now: 100.1) == nil)
        steering.offer(0.4, session: "A", now: 100)
        check("stalled steering expires", steering.take(session: "A", now: 101) == nil)
        steering.offer(0.4, session: "A", now: 100)
        steering.clear()
        check("leaving the screen clears steering", steering.take(session: "A", now: 100.1) == nil)
        steering.offer(.nan, session: "A", now: 100)
        check("nonfinite steering never queues", steering.take(session: "A", now: 100.1) == nil)
        steering.offer(2, session: "A", now: 100)
        check("steering stays in the flight area", steering.take(session: "A", now: 100.1) == 1)
        steering.offer(0.3, session: "A", final: true, now: 100)
        check("final steering survives a slow reply", steering.take(session: "A", now: 102) == 0.3)

        let host = CommandLine.arguments[1]
        let catalogue = try await GameLink.catalogue(host: host)
        check("catalogue preserves all cards", catalogue.count == 3)
        check("solo game has one player", catalogue[1].minimumPlayers == 1 && catalogue[1].maximumPlayers == 1)
        check("party game permits eight players", catalogue[2].maximumPlayers == 8)
        check("party destination category", catalogue[2].category == "Together")
        for label in ["duplicate game IDs are rejected", "unbounded player counts are rejected"] {
            do { _ = try await GameLink.catalogue(host: host); check(label, false) }
            catch { check(label, true) }
        }
        do { _ = try await GameLink.catalogue(host: host); check("games switched off is its own answer", false) }
        catch GameLink.Failure.gamesOff { check("games switched off is its own answer", true) }
        catch { check("games switched off is its own answer", false) }
        let firstRead = await GameLink.status(host: host)
        check("status request reads matching session", firstRead?.session_id == "session-A")
        let badStatus = await GameLink.status(host: host)
        check("error-only status cannot replace a board", badStatus == nil)
        let malformedStatus = await GameLink.status(host: host)
        check("malformed status cannot replace a board", malformedStatus == nil)

        var latest = active
        let move: [String: Any] = ["session_id": "session-A", "player": "You", "move": ["guess": "crane"]]
        do { latest = try await GameLink.perform(host: host, "denied", move); check("failed HTTP write throws", false) }
        catch { check("failed HTTP write preserves server reason", error.localizedDescription == "The game changed. Refresh before making another move.") }
        check("failed write cannot replace caller snapshot", latest.session_id == "session-A" && latest.seq == 12)
        for (action, label) in [("empty", "empty200 cannot confirm a move"), ("malformed", "badJSON200 cannot confirm a move"), ("error-ok", "JSONerror200 cannot confirm a move") ] {
            do { _ = try await GameLink.perform(host: host, action, move); check(label, false) }
            catch { check(label, true) }
        }
        let success = try await GameLink.perform(host: host, "valid", move)
        check("acknowledged move supplies newer sequence", success.seq == 13)
        check("acknowledged move retains session", success.session_id == "session-A")
        let cancellation = Task { try await GameLink.perform(host: host, "slow", move) }
        try? await Task.sleep(for: .milliseconds(70))
        cancellation.cancel()
        do { _ = try await cancellation.value; check("cancelled transport cannot acknowledge a move", false) }
        catch { check("cancelled transport cannot acknowledge a move", true) }
        do { _ = try await GameLink.perform(host: "", "valid", move); check("empty host prevents write", false) }
        catch { check("empty host prevents write", true) }
        let failed = checks.filter { $0["passed"] as? Bool != true }.count
        let output: [String: Any] = ["checks": checks, "passed": checks.count - failed, "failed": failed]
        try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("Game models and HTTP: \(checks.count - failed)/\(checks.count) checks passed")
        if failed != 0 { exit(1) }
    }
}
