import Foundation

@main struct MessageTests {
    static func main() throws {
        var checks: [[String: Any]] = []
        func check(_ condition: Bool, _ name: String) {
            checks.append(["name": name, "passed": condition])
        }
        let decoder = JSONDecoder()
        func note(_ json: String) throws -> NoteStatus { try decoder.decode(NoteStatus.self, from: Data(json.utf8)) }
        let status = try note(#"{"text":"Back at six","seconds_left":90,"active":true,"id":"current-note"}"#)
        let countdown = NoteCountdown(status: status, uptime: 100)!
        check(countdown.id == "current-note", "Countdown keeps the server note identity for safe dismissal")
        check(countdown.remaining(uptime: 100) == 90, "Initial countdown keeps all wall-reported seconds")
        check(countdown.remaining(uptime: 101.2) == 89, "Countdown advances from monotonic uptime")
        check(countdown.remaining(uptime: 99) == 90, "Clock reset cannot add time beyond original duration")
        check(countdown.remaining(uptime: 190) == 0, "Countdown reaches zero exactly")
        check(countdown.remaining(uptime: 290) == 0, "Completed countdown never becomes negative")
        check(countdown.remaining(uptime: .infinity) == 0, "Nonfinite uptime cannot crash integer conversion")
        check(try NoteCountdown(status: note(#"{"text":"Old","seconds_left":90,"active":false}"#)) == nil, "Inactive server receipt wins over stale text")
        check(try NoteCountdown(status: note(#"{"text":"Old","seconds_left":0}"#)) == nil, "Expired note does not render as active")
        check(try NoteCountdown(status: note(#"{"text":"Old","seconds_left":-9}"#)) == nil, "Invalid negative note duration is ignored")
        check(try NoteCountdown(status: note(#"{"seconds_left":30}"#)) == nil, "Missing note text cannot claim active note")
        check(try NoteCountdown(status: note(#"{"text":"Back","seconds_left":30}"#)) != nil, "Legacy active note snapshots still work")
        check(NoteCountdown.duration(3665) == "1:01:05", "Long notes show hours without minute overflow")
        check(NoteCountdown.duration(59) == "0:59", "Short note duration is explicit")
        check(NoteCountdown.duration(-2) == "0:00", "Negative note duration is clipped")
        let success = MessageReply.decode(Data(#"{"answer":"Four records","shown":true}"#.utf8), status: 200)
        check(success.accepted && success.answer == "Four records", "Valid HTTP acknowledgement accepts actual answer")
        check(success.shown == true, "Wall receipt preserves actual display acknowledgement")
        let textOnly = MessageReply.decode(Data(#"{"answer":"Four records","shown":false}"#.utf8), status: 200)
        check(textOnly.accepted && textOnly.shown == false, "Text-only answer does not invent a wall receipt")
        let failure = MessageReply.decode(Data(#"{"error":"Claude is unavailable"}"#.utf8), status: 502)
        check(!failure.accepted && failure.error == "Claude is unavailable", "Backend errors retain actionable text")
        let falseSuccess = MessageReply.decode(Data(#"{"error":"Busy"}"#.utf8), status: 200)
        check(!falseSuccess.accepted, "Even a malformed 200 cannot mark an error successful")
        let rejected = MessageReply.decode(Data(#"{"shown":true}"#.utf8), status: 409)
        check(!rejected.accepted && rejected.error != nil, "HTTP rejection cannot mark note as sent")
        let malformed = MessageReply.decode(Data("<html>offline</html>".utf8), status: 200)
        check(!malformed.accepted && malformed.error != nil, "Non-JSON replies produce a recoverable error")
        let clear = MessageReply.decode(Data(#"{"cleared":true,"active":false}"#.utf8), status: 200)
        check(clear.accepted && clear.cleared == true, "Explicit note clear is acknowledged")
        let ask = try decoder.decode(AskStatus.self, from: Data(#"{"ready":true,"pending":true,"history":[{"q":"Question","a":"Answer","ts":123}]}"#.utf8))
        check(ask.pending == true && ask.history?.first?.a == "Answer", "Pending and history decode together")
        let legacy = try decoder.decode(AskStatus.self, from: Data(#"{"ready":false}"#.utf8))
        check(legacy.pending == nil && legacy.history == nil, "Missing optional fields do not break older walls")
        let request = try MessageAPI.request(host: "192.168.12.118:8788", path: "/note", timeout: 8)
        check(request.url?.absoluteString == "http://192.168.12.118:8788/note", "Request uses selected wall including its control port")
        check(request.cachePolicy == .reloadIgnoringLocalCacheData, "Status requests cannot reuse stale cache receipts")
        check(request.timeoutInterval == 8, "Request preserves bounded timeout")
        do { _ = try MessageAPI.request(host: "", path: "/note", timeout: 8); check(false, "Empty wall address rejected") }
        catch { check(true, "Empty wall address rejected") }
        let output: [String: Any] = ["checks": checks, "passed": checks.filter { $0["passed"] as? Bool == true }.count, "total": checks.count]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        if CommandLine.arguments.count > 1 { try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
        print(String(data: data, encoding: .utf8)!)
        if checks.contains(where: { $0["passed"] as? Bool != true }) { exit(1) }
    }
}
