import Foundation

/// The Connection page's rules, checked on the Mac. Compiled with
/// tessera/Tessera/ConnectionModels.swift and LinkRecords.swift by
/// scripts/test_connection_models.py, which prints this JSON report.
@main struct ConnectionModelChecks {
    static func main() throws {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ ok: Bool, _ got: Any? = nil) {
            var entry: [String: Any] = ["name": name, "passed": ok]
            if !ok, let got { entry["got"] = "\(got)" }
            checks.append(entry)
        }
        func equal<T: Equatable>(_ name: String, _ got: T, _ want: T) { check(name, got == want, got) }

        // MARK: Addresses

        for (raw, want) in [
            ("album-matrix.local", "album-matrix.local:8788"),
            (" HTTP://192.168.1.40:8788/ ", "192.168.1.40:8788"),
            ("https://album-matrix.local:9000", "album-matrix.local:9000"),
            ("[fe80::1]:8788", "[fe80::1]:8788"),
            ("[FE80::1]", "[fe80::1]:8788"),
            ("fe80::1", "[fe80::1]:8788"),
            ("Album-Matrix.local.", "album-matrix.local:8788"),
            ("127.0.0.1", "127.0.0.1:8788"),
            ("http://127.0.0.1:65367/", "127.0.0.1:65367"),
            ("localhost:8788", "localhost:8788"),
            ("qa-wall", "qa-wall:8788"),
            ("192.168.001.040", "192.168.1.40:8788"),
        ] {
            equal("normalize \(raw.debugDescription)", WallAddressInput.normalize(raw), want)
        }
        for raw in ["a b", "user:pw@host", "host/path", "host?x=1", "host#top", "host:0", "host:70000", "host:",
                    "host:8a", "999.1.1.1", "1.2.3", "12345", "", "   ", "-bad.local", "bad-.local", "under_score.local",
                    "[fe80::1", "[nothost]:8788", "fe80::1%en0", "a..b.local", "http://", "wall\u{7}.local",
                    String(repeating: "a", count: 64) + ".local"] {
            equal("refuse \(raw.debugDescription)", WallAddressInput.normalize(raw), nil)
        }
        if let parts = WallAddressInput.split("[fe80::1]:8788") {
            check("split keeps IPv6 bare", parts.host == "fe80::1" && parts.port == 8788, parts)
        } else { check("split keeps IPv6 bare", false) }
        if let parts = WallAddressInput.split("album-matrix.local:9000") {
            check("split names the port", parts.host == "album-matrix.local" && parts.port == 9000, parts)
        } else { check("split names the port", false) }

        for (host, numeric) in [("192.168.1.40", true), ("fe80::1", true), ("[::1]", true), ("album-matrix.local", false),
                                ("localhost", false), ("qa-wall", false)] {
            equal("isNumeric \(host)", WallAddressInput.isNumeric(host), numeric)
        }
        for (host, loop) in [("localhost", true), ("127.0.0.1", true), ("127.4.5.6", true), ("::1", true), ("[::1]", true),
                             ("192.168.1.40", false), ("album-matrix.local", false)] {
            equal("isLoopback \(host)", WallAddressInput.isLoopback(host), loop)
        }
        for (host, local) in [("album-matrix.local", true), ("qa-wall", true), ("10.0.0.5", true), ("172.16.0.1", true),
                              ("172.31.255.1", true), ("172.32.0.1", false), ("192.168.1.40", true), ("169.254.3.4", true),
                              ("fe80::1", true), ("fd12::1", true), ("fc00::1", true), ("localhost", false),
                              ("127.0.0.1", false), ("::1", false), ("8.8.8.8", false), ("2001:db8::1", false),
                              ("wall.example.com", false), ("album-matrix.lan", true), ("wall.home.arpa", true),
                              ("nas.home", true), ("pi.internal", true), ("pi.tail1234.ts.net", false)] {
            equal("isLocal \(host)", WallAddressInput.isLocal(host), local)
        }
        for (host, blocked) in [("album-matrix.lan", true), ("wall.home.arpa", true), ("pi.tail1234.ts.net", true),
                                ("album-matrix.local", false), ("qa-wall", false), ("localhost", false),
                                ("192.168.1.40", false), ("fe80::1", false)] {
            equal("isBlockedName \(host)", WallAddressInput.isBlockedName(host), blocked)
        }
        equal("named adds .local", WallAddressInput.named("qa-wall", port: 8788), "qa-wall.local:8788")
        equal("named keeps .local", WallAddressInput.named("Album-Matrix.local", port: 9000), "album-matrix.local:9000")
        equal("named refuses an empty name", WallAddressInput.named("  ", port: 8788), nil)

        let current = "127.0.0.1:65367"
        equal("draft same", WallAddressInput.draft("http://127.0.0.1:65367/", current: current), .same(current))
        equal("draft same line", WallAddressInput.draft("http://127.0.0.1:65367/", current: current).line, "This is the address in use.")
        equal("draft valid line", WallAddressInput.draft("127.0.0.1", current: current).line, "Tessera will use 127.0.0.1:8788.")
        equal("draft invalid", WallAddressInput.draft("bad host!", current: current), .invalid)
        equal("draft invalid line", WallAddressInput.draft("bad host!", current: current).line,
              "Use a name or number with an optional port, like album-matrix.local:8788.")
        check("draft invalid is a problem with nothing to save",
              WallAddressInput.draft("bad host!", current: current).isProblem && WallAddressInput.draft("bad host!", current: current).address == nil)
        equal("draft blocked", WallAddressInput.draft("album-matrix.lan", current: current), .blocked(host: "album-matrix.lan"))
        equal("draft blocked line", WallAddressInput.draft("album-matrix.lan", current: current).line,
              "iPhone blocks plain connections to album-matrix.lan. Use a name ending in .local or the wall\u{2019}s number.")
        check("draft blocked has nothing to save", WallAddressInput.draft("wall.home.arpa", current: current).address == nil)
        equal("draft empty", WallAddressInput.draft("  ", current: current), .empty)

        // MARK: Latency

        equal("149 ms is quick", LatencyGrade(ms: 149), .quick)
        equal("150 ms is fine", LatencyGrade(ms: 150), .fine)
        equal("699 ms is fine", LatencyGrade(ms: 699), .fine)
        equal("700 ms is slow", LatencyGrade(ms: 700), .slow)
        equal("38 ms label", LatencyGrade.label(ms: 38), "Quick, 38 ms")
        equal("420 ms label", LatencyGrade.label(ms: 420), "Fine, 420 ms")
        equal("1900 ms label", LatencyGrade.label(ms: 1900), "Slow, 1.9 s")

        // MARK: Outbox words (LinkRecords.swift)

        equal("brightness", OutboxWords.describe(keys: ["brightness"], frame: false, clip: false), "Brightness")
        equal("display and brightness", OutboxWords.describe(keys: ["mode", "brightness"], frame: false, clip: false), "Display mode and brightness")
        equal("display and brightness in any order", OutboxWords.describe(keys: ["brightness", "mode"], frame: false, clip: false), "Display mode and brightness")
        equal("lamp colour once", OutboxWords.describe(keys: ["color", "color2"], frame: false, clip: false), "Lamp colour")
        equal("five keys", OutboxWords.describe(keys: ["mode", "brightness", "effect", "finish", "rpm"], frame: false, clip: false), "5 settings")
        equal("three names count names", OutboxWords.describe(keys: ["color", "color2", "match_art", "mode", "brightness"], frame: false, clip: false), "3 settings")
        equal("a picture alone", OutboxWords.describe(keys: [], frame: true, clip: false), "A picture")
        equal("brightness and a picture", OutboxWords.describe(keys: ["brightness"], frame: true, clip: false), "Brightness and a picture")
        equal("a clip", OutboxWords.describe(keys: [], frame: false, clip: true), "A clip")
        equal("record face", OutboxWords.describe(keys: ["spin_face"], frame: false, clip: false), "Record face")
        equal("words and wake up by prefix", OutboxWords.describe(keys: ["ticker_text", "wake_time"], frame: false, clip: false), "Ticker text and wake up")
        equal("finish reads as the record finish", OutboxWords.describe(keys: ["finish"], frame: false, clip: false, sentenceCase: false), "record finish")
        equal("unknown key", OutboxWords.describe(keys: ["mystery"], frame: false, clip: false), "A setting")
        equal("lower case phrase", OutboxWords.describe(keys: ["mode"], frame: true, clip: false, sentenceCase: false), "display mode and a picture")
        equal("one change waiting", OutboxWords.count(keys: ["brightness"], frame: false, clip: false), "1 change waiting")
        equal("two changes waiting", OutboxWords.count(keys: ["brightness", "mode"], frame: false, clip: false), "2 changes waiting")
        equal("changes count names, a picture and a clip", OutboxWords.count(keys: ["color", "color2"], frame: true, clip: true), "3 changes waiting")

        // MARK: The check, after a run

        func grades(_ steps: [CheckStep]) -> [String] { steps.map(\.grade) }
        func statuses(_ steps: [CheckStep]) -> [CheckStep.Status] { steps.map(\.status) }
        let named = "album-matrix.local:8788"
        let numeric = "192.168.1.40:8788"

        let passed = ConnectionCheck.steps(hostPort: named, network: .wifi, reach: .ready(remote: "192.168.1.40"),
                                           wall: .tessera(ms: 38, name: "album-matrix"), knownName: nil)
        equal("passed statuses", statuses(passed), [.passed, .passed, .passed, .passed])
        equal("passed grades", grades(passed), ["On Wi-Fi", "Allowed", "Found at 192.168.1.40", "Quick, 38 ms"])
        equal("passed summary", ConnectionCheck.summary(passed, ran: true), "All four steps passed.")
        check("passed reached the wall", ConnectionCheck.reachedWall(passed))
        equal("passed wall detail", passed[3].detail, "Tessera is running on the wall.")

        let numericPassed = ConnectionCheck.steps(hostPort: numeric, network: .wifi, reach: .ready(remote: "192.168.1.40"),
                                                  wall: .tessera(ms: 420, name: nil), knownName: nil)
        equal("numeric row 03", numericPassed[2].grade, "192.168.1.40")
        equal("numeric row 03 detail", numericPassed[2].detail, "A number, so no lookup was needed.")
        equal("fine latency", numericPassed[3].grade, "Fine, 420 ms")
        // A number is judged on itself, whatever address the connection
        // reports back, so a loopback wall never reads as a LAN one.
        let loopbackScripted = ConnectionCheck.steps(hostPort: "127.0.0.1:65368", network: .wifi, reach: .ready(remote: "192.168.1.40"),
                                                     wall: .tessera(ms: 12, name: nil), knownName: nil)
        equal("loopback row 02 grade", loopbackScripted[1].grade, "Not needed")
        equal("loopback row 02 detail", loopbackScripted[1].detail, "This address is on this device.")

        let slow = ConnectionCheck.steps(hostPort: named, network: .wifi, reach: .ready(remote: "192.168.1.40"),
                                         wall: .tessera(ms: 1900, name: nil), knownName: nil)
        equal("slow grade", slow[3].grade, "Slow, 1.9 s")
        equal("slow is a note", slow[3].status, .attention)
        equal("slow detail", slow[3].detail, "Tessera is running on the wall. Controls may feel late.")
        check("slow still reached the wall", ConnectionCheck.reachedWall(slow))
        equal("slow summary", ConnectionCheck.summary(slow, ran: true), "The wall responded. Step 4 has a note.")

        let cellular = ConnectionCheck.steps(hostPort: named, network: .cellular, reach: .ready(remote: "192.168.1.40"),
                                             wall: .tessera(ms: 90, name: nil), knownName: nil)
        equal("cellular continues as a note", statuses(cellular), [.attention, .passed, .passed, .passed])
        equal("cellular copy", cellular[0].grade + " / " + cellular[0].detail,
              "On mobile data / The wall is usually only reachable on your home Wi-Fi.")
        let other = ConnectionCheck.steps(hostPort: named, network: .other, reach: nil, wall: nil, knownName: nil)
        equal("other network passes as connected", other[0].grade, "Connected")
        equal("other network passes", other[0].status, .passed)

        let noNetwork = ConnectionCheck.steps(hostPort: named, network: .disconnected, reach: nil, wall: nil, knownName: nil)
        equal("no network stops the rest", statuses(noNetwork), [.failed, .notChecked, .notChecked, .notChecked])
        equal("no network copy", noNetwork[0].grade + " / " + noNetwork[0].detail, "No network / Turn on Wi-Fi, then check again.")
        equal("later rows say why", noNetwork[1].detail, "Fix the step above first.")
        equal("later rows grade", noNetwork[3].grade, "Not checked")
        equal("no network summary", ConnectionCheck.summary(noNetwork, ran: true), "Stopped at step 1.")

        let denied = ConnectionCheck.steps(hostPort: named, network: .wifi, reach: .denied, wall: nil, knownName: nil)
        equal("denied stops at 02", statuses(denied), [.passed, .failed, .notChecked, .notChecked])
        equal("denied copy", denied[1].grade + " / " + denied[1].detail,
              "Not allowed / Tessera needs Local Network access to reach the wall.")
        equal("denied summary", ConnectionCheck.summary(denied, ran: true), "Stopped at step 2.")
        equal("denied while the session reaches the wall is not called brief", ConnectionCheck.summary(denied, ran: true, live: true),
              "Stopped at step 2. Tessera\u{2019}s regular connection still reaches a Tessera wall at this address. Check again.")
        equal("denied advice leads with Local Network", ConnectionAdvice.steps(for: .timedOut, check: denied).map(\.title),
              ["Local Network access", "Same Wi-Fi", "Power"])
        equal("a pass while live says nothing more", ConnectionCheck.summary(passed, ran: true, live: true), "All four steps passed.")
        let deniedName = ConnectionCheck.steps(hostPort: "qa-wall.local:8788", network: .wifi, reach: .denied, wall: nil, knownName: "qa-wall")
        equal("denied by name reads as access, not a missing name", deniedName[1].grade, "Not allowed")
        equal("denied by name leaves 03 unchecked", deniedName[2].status, .notChecked)

        let notFound = ConnectionCheck.steps(hostPort: named, network: .wifi, reach: .notFound, wall: nil, knownName: nil)
        equal("not found statuses", statuses(notFound), [.passed, .unknown, .failed, .notChecked])
        equal("could not tell", notFound[1].grade + " / " + notFound[1].detail,
              "Could not tell / The name was not found, so access could not be confirmed.")
        equal("a name not found gets power and Wi-Fi", ConnectionAdvice.steps(for: nil, check: notFound).map(\.title),
              ["Power", "Same Wi-Fi", "Give it a minute"])
        equal("not found copy", notFound[2].grade + " / " + notFound[2].detail,
              "Not found / Nothing on this network responds to album-matrix.local. Check the wall has power and is on the same Wi-Fi.")
        equal("not found summary", ConnectionCheck.summary(notFound, ran: true), "Stopped at step 3.")
        let namedTimeout = ConnectionCheck.steps(hostPort: named, network: .wifi, reach: .timedOut, wall: nil, knownName: "qa-wall")
        equal("named timeout reads as not found", namedTimeout[2].grade, "Not found")
        check("named timeout offers nothing", namedTimeout[2].suggestion == nil)

        let gone = ConnectionCheck.steps(hostPort: numeric, network: .wifi, reach: .timedOut, wall: nil, knownName: "qa-wall")
        equal("numeric timeout statuses", statuses(gone), [.passed, .unknown, .failed, .notChecked])
        equal("numeric timeout copy", gone[2].grade + " / " + gone[2].detail,
              "No reply / Nothing responded at 192.168.1.40. The number may have changed. Try qa-wall.local:8788.")
        equal("numeric timeout suggestion", gone[2].suggestion, "qa-wall.local:8788")
        equal("numeric timeout says why access is unknown", gone[1].detail, "Nothing replied, so access could not be confirmed.")
        equal("a silent number suggests another address", ConnectionAdvice.steps(for: .timedOut, check: gone).map(\.title),
              ["Power", "Change the address", "Same Wi-Fi"])
        let numericNotFound = ConnectionCheck.steps(hostPort: numeric, network: .wifi, reach: .notFound, wall: nil, knownName: nil)
        equal("a number is never not found", numericNotFound[2].grade, "No reply")
        let goneNoName = ConnectionCheck.steps(hostPort: numeric, network: .wifi, reach: .timedOut, wall: nil, knownName: nil)
        equal("numeric timeout without a name", goneNoName[2].detail, "Nothing responded at 192.168.1.40. The number may have changed.")
        let loopGone = ConnectionCheck.steps(hostPort: "127.0.0.1:65368", network: .wifi, reach: .timedOut, wall: nil, knownName: "qa-wall")
        equal("loopback timeout copy", loopGone[2].detail, "Nothing responded at 127.0.0.1.")
        check("loopback timeout offers no name", loopGone[2].suggestion == nil)
        // This device's own address: row 02 says so, and row 03 never sends
        // the owner to Wi-Fi or a lookup.
        let loopNotFound = ConnectionCheck.steps(hostPort: "127.0.0.1:65368", network: .wifi, reach: .notFound, wall: nil, knownName: "qa-wall")
        equal("loopback not found rows agree", loopNotFound[1].grade + " / " + loopNotFound[2].grade + " / " + loopNotFound[2].detail,
              "Not needed / No reply / Nothing responded at 127.0.0.1.")
        check("loopback not found offers no name", loopNotFound[2].suggestion == nil)
        equal("loopback advice leaves out Wi-Fi and power", ConnectionAdvice.steps(for: .timedOut, check: loopNotFound).map(\.title),
              ["Give it a minute", "Change the address"])
        let localhostGone = ConnectionCheck.steps(hostPort: "localhost:8788", network: .wifi, reach: .notFound, wall: nil, knownName: nil)
        equal("localhost not found is no reply", localhostGone[2].grade, "No reply")

        let failedReach = ConnectionCheck.steps(hostPort: named, network: .wifi, reach: .failed, wall: nil, knownName: nil)
        equal("reach failed", failedReach[2].grade + " / " + failedReach[2].detail,
              "No connection / The connection to album-matrix.local could not be opened.")
        equal("reach failed statuses", statuses(failedReach), [.passed, .unknown, .failed, .notChecked])

        let refused = ConnectionCheck.steps(hostPort: "127.0.0.1:9", network: .wifi, reach: .refused, wall: nil, knownName: nil)
        equal("refused statuses", statuses(refused), [.passed, .passed, .passed, .failed])
        equal("refused copy", refused[3].grade + " / " + refused[3].detail,
              "Not running / Something is at this address, but Tessera is not running on port 9. It may still be starting.")
        equal("loopback needs no access", refused[1].grade + " / " + refused[1].detail, "Not needed / This address is on this device.")
        let refusedLocal = ConnectionCheck.steps(hostPort: numeric, network: .wifi, reach: .refused, wall: nil, knownName: nil)
        equal("refused on the home network passes 02 and 03", statuses(refusedLocal), [.passed, .passed, .passed, .failed])
        equal("refused advice leaves out Wi-Fi", ConnectionAdvice.steps(for: nil, check: refusedLocal).map(\.title),
              ["Give it a minute", "Restart the wall"])
        equal("refused while live may have been brief", ConnectionCheck.summary(refusedLocal, ran: true, live: true),
              "Stopped at step 4. Tessera is still reaching the wall, so this may have been brief.")

        let outside = ConnectionCheck.steps(hostPort: "8.8.8.8:8788", network: .wifi, reach: .ready(remote: "8.8.8.8"),
                                            wall: .timedOut, knownName: nil)
        equal("outside the home network", outside[1].grade + " / " + outside[1].detail,
              "Not needed / This address is outside your local network.")
        equal("ask timed out", outside[3].grade + " / " + outside[3].detail, "No response / The wall did not respond within 4 seconds.")

        let notTessera = ConnectionCheck.steps(hostPort: named, network: .wifi, reach: .ready(remote: nil), wall: .notTessera, knownName: nil)
        equal("not tessera copy", notTessera[3].grade + " / " + notTessera[3].detail,
              "Not a Tessera wall / Something responded, but it is not a Tessera wall. Check the address.")
        equal("not tessera beside Connected is not called brief", ConnectionCheck.summary(notTessera, ran: true, live: true),
              "Stopped at step 4. Tessera\u{2019}s regular connection still reaches a Tessera wall at this address. Check again.")
        equal("not tessera advice", ConnectionAdvice.steps(for: nil, check: notTessera).map(\.title), ["Change the address", "Power"])
        equal("found without a number", notTessera[2].grade, "Found")
        let http = ConnectionCheck.steps(hostPort: named, network: .wifi, reach: .ready(remote: nil), wall: .http(503), knownName: nil)
        equal("http copy", http[3].grade + " / " + http[3].detail, "Error 503 / The wall reported a problem. Try again in a minute.")
        equal("http summary", ConnectionCheck.summary(http, ran: true), "Stopped at step 4.")
        equal("http while live may have been brief", ConnectionCheck.summary(http, ran: true, live: true),
              "Stopped at step 4. Tessera is still reaching the wall, so this may have been brief.")
        equal("an error reply leaves out Wi-Fi", ConnectionAdvice.steps(for: .httpError, check: http).map(\.title),
              ["Give it a minute", "Restart the wall"])
        let blocked = ConnectionCheck.steps(hostPort: "wall.lan:8788", network: .wifi, reach: .ready(remote: "10.0.0.2"), wall: .blocked, knownName: nil)
        equal("blocked copy", blocked[3].grade + " / " + blocked[3].detail,
              "Blocked / iPhone only allows this kind of connection to .local names and numbers. Try 10.0.0.2:8788.")
        equal("blocked offers the number row 03 found", blocked[3].suggestion, "10.0.0.2:8788")
        equal("blocked advice", ConnectionAdvice.steps(for: .blockedName, check: blocked).map(\.title), ["Change the address"])
        let blockedNamed = ConnectionCheck.steps(hostPort: "album-matrix.lan:8788", network: .wifi, reach: .ready(remote: "192.168.1.40"),
                                                 wall: .blocked, knownName: "album-matrix")
        equal("blocked offers the wall's name first", blockedNamed[3].suggestion, "album-matrix.local:8788")
        // The high finding: a .lan name that leads to a home number is on the
        // local network, so row 02 cannot say it is outside it.
        equal("a .lan name at a home number needs access", blockedNamed[1].grade + " / " + blockedNamed[1].detail,
              "Allowed / The wall is reachable on this network.")
        equal("row 03 agrees", blockedNamed[2].grade + " / " + blockedNamed[2].detail,
              "Found at 192.168.1.40 / The name album-matrix.lan was found on this network.")
        let publicName = ConnectionCheck.steps(hostPort: "wall.example.com:8788", network: .wifi, reach: .ready(remote: "203.0.113.9"),
                                               wall: .blocked, knownName: nil)
        equal("a public name at a public number needs no access", publicName[1].grade, "Not needed")
        equal("a public number is not on this network", publicName[2].detail, "The name wall.example.com was found.")
        let localNameAtLoopback = ConnectionCheck.steps(hostPort: "localhost:8788", network: .wifi, reach: .ready(remote: "::1"),
                                                        wall: .tessera(ms: 5, name: nil), knownName: nil)
        equal("a name that reaches this device", localNameAtLoopback[1].detail, "This address is on this device.")
        let closed = ConnectionCheck.steps(hostPort: named, network: .wifi, reach: .ready(remote: nil), wall: .failed, knownName: nil)
        equal("ask failed copy", closed[3].detail, "The connection closed before the wall answered.")

        // How a failed connect reads (LiveProbe hands over NWError's parts).
        // With Local Network off a .local name fails its lookup with
        // kDNSServiceErr_PolicyDenied, and that is access, not a lost name.
        equal("dns policy denied is access", ReachReading.failure(localNetworkDenied: false, dns: -65570), .denied)
        equal("dns no such name is not found", ReachReading.failure(localNetworkDenied: false, dns: -65554), .notFound)
        equal("dns other is not found", ReachReading.failure(localNetworkDenied: false, dns: -65537), .notFound)
        equal("path says denied first", ReachReading.failure(localNetworkDenied: true, posix: .ECONNREFUSED), .denied)
        equal("path denied without an error", ReachReading.failure(localNetworkDenied: true), .denied)
        equal("connection refused", ReachReading.failure(localNetworkDenied: false, posix: .ECONNREFUSED), .refused)
        for code in [POSIXErrorCode.ETIMEDOUT, .EHOSTDOWN, .EHOSTUNREACH] {
            equal("\(code) is no reply", ReachReading.failure(localNetworkDenied: false, posix: code), .timedOut)
        }
        equal("network unreachable fails", ReachReading.failure(localNetworkDenied: false, posix: .ENETUNREACH), .failed)
        equal("an unknown error fails", ReachReading.failure(localNetworkDenied: false), .failed)

        // Running, one row at a time.
        let first = ConnectionCheck.steps(hostPort: named, network: nil, reach: nil, wall: nil, knownName: nil, running: .phone)
        equal("running row 01", statuses(first), [.running, .waiting, .waiting, .waiting])
        equal("running summary", ConnectionCheck.summary(first, ran: true), "Checking step 1 of 4\u{2026}")
        equal("running detail says what it checks", first[0].detail, "Reading this phone\u{2019}s network.")
        check("no running detail repeats the grade", [first[0], ConnectionCheck.steps(hostPort: named, network: .wifi, reach: nil, wall: nil,
                                                                                     knownName: nil, running: .permission)[1]]
              .allSatisfy { !$0.detail.lowercased().hasPrefix("checking") })
        equal("waiting detail", first[1].detail, "Not checked yet.")
        let second = ConnectionCheck.steps(hostPort: named, network: .wifi, reach: nil, wall: nil, knownName: nil, running: .permission)
        equal("running row 02", statuses(second), [.passed, .running, .waiting, .waiting])
        equal("running row 02 summary", ConnectionCheck.summary(second, ran: true), "Checking step 2 of 4\u{2026}")
        let third = ConnectionCheck.steps(hostPort: named, network: .wifi, reach: .ready(remote: "192.168.1.40"), wall: nil, knownName: nil, running: .address)
        equal("running row 03", statuses(third), [.passed, .passed, .running, .waiting])
        let fourth = ConnectionCheck.steps(hostPort: named, network: .wifi, reach: .ready(remote: "192.168.1.40"), wall: nil, knownName: nil, running: .wall)
        equal("running row 04", statuses(fourth), [.passed, .passed, .passed, .running])
        let stopped = [passed[0], passed[1]] + [CheckStep(id: .address, status: .notChecked, grade: "Not checked", detail: "The check was stopped."),
                                                CheckStep(id: .wall, status: .notChecked, grade: "Not checked", detail: "The check was stopped.")]
        equal("stopped summary", ConnectionCheck.summary(stopped, ran: true), "Check stopped before step 3.")
        check("a stopped check did not reach the wall", !ConnectionCheck.reachedWall(stopped))

        // What VoiceOver reads: nothing that repeats the grade.
        equal("spoken running", second[1].spoken, "Local network, Checking. Opening a connection to the wall.")
        equal("spoken waiting", second[2].spoken, "Wall address, Waiting. Not checked yet.")
        equal("spoken passed", passed[0].spoken, "This phone, On Wi-Fi, passed. This phone\u{2019}s connection right now.")
        equal("spoken failed", denied[1].spoken, "Local network, Not allowed, failed. Tessera needs Local Network access to reach the wall.")
        equal("spoken not checked", denied[3].spoken, "The wall, Not checked. Fix the step above first.")
        equal("spoken stopped", stopped[2].spoken, "Wall address, Not checked. The check was stopped.")
        equal("spoken unknown", notFound[1].spoken,
              "Local network, Could not tell, unknown. The name was not found, so access could not be confirmed.")

        // MARK: The check, before a run

        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let posix = Locale(identifier: "en_US_POSIX")
        let utc = TimeZone(identifier: "UTC")!
        let live = ConnectionCheck.passive(host: named, link: .live(lightsOff: false), network: .wifi, now: now, locale: posix, timeZone: utc)
        equal("passive live statuses", statuses(live), [.passed, .passed, .passed, .passed])
        equal("passive live grades", grades(live), ["On Wi-Fi", "Allowed", "album-matrix.local", "Responding"])
        equal("passive live 03 detail", live[2].detail, "Run the check to see its network address.")
        equal("passive summary", ConnectionCheck.summary(live, ran: false), "What Tessera knows now. The check tests each step in turn.")
        let loop = ConnectionCheck.passive(host: "127.0.0.1:65367", link: .live(lightsOff: false), network: .other, now: now, locale: posix, timeZone: utc)
        equal("passive loopback", loop[1].grade + " / " + loop[1].detail, "Not needed / This address is on this device.")
        let away = ConnectionCheck.passive(host: named, link: .offline(since: now.addingTimeInterval(-720)), network: .wifi,
                                           now: now, locale: posix, timeZone: utc)
        equal("passive offline statuses", statuses(away), [.passed, .notChecked, .notChecked, .failed])
        equal("passive offline 04", away[3].grade + " / " + away[3].detail, "No response / Since " + ConnectionCheck.clock(now.addingTimeInterval(-720), now: now, locale: posix, timeZone: utc) + ".")
        let notReady = ConnectionCheck.passive(host: named, link: .offline(since: now.addingTimeInterval(-720)), network: .wifi,
                                               problem: .httpError, now: now, locale: posix, timeZone: utc)
        equal("passive offline after an error reply", notReady[3].grade, "Not ready")
        let elsewhere = ConnectionCheck.passive(host: named, link: .noWallFound, network: .wifi, problem: .notTessera,
                                                now: now, locale: posix, timeZone: utc)
        equal("passive stand-in, something else answers", elsewhere[3].grade, "Not a Tessera wall")
        let notRunning = ConnectionCheck.passive(host: named, link: .offline(since: now.addingTimeInterval(-720)), network: .wifi,
                                                 problem: .refused, now: now, locale: posix, timeZone: utc)
        equal("passive offline, nothing listening", notRunning[3].grade, "Not running")
        let searching = ConnectionCheck.passive(host: named, link: .searching, network: .wifi, now: now, locale: posix, timeZone: utc)
        equal("passive searching", statuses(searching), [.passed, .notChecked, .notChecked, .notChecked])
        equal("passive searching 04", searching[3].grade + " / " + searching[3].detail, "Not checked / Run the check to find out.")
        let standIn = ConnectionCheck.passive(host: named, link: .noWallFound, network: .wifi, now: now, locale: posix, timeZone: utc)
        equal("passive no wall 04", standIn[3].grade + " / " + standIn[3].detail, "Not found / Run the check to see where it stops.")
        let phone = ConnectionCheck.passive(host: named, link: .phoneOnly, network: nil, now: now, locale: posix, timeZone: utc)
        equal("passive phone only 04", phone[3].grade + " / " + phone[3].detail, "Not contacted / Run the check to find out.")
        equal("passive unknown network", phone[0].status, .notChecked)

        // MARK: Words on the page

        equal("headline live", ConnectionWords.headline(.live(lightsOff: true)), "Connected")
        equal("headline searching", ConnectionWords.headline(.searching), "Looking for your wall")
        equal("headline offline", ConnectionWords.headline(.offline(since: now)), "Wall offline")
        equal("headline no wall", ConnectionWords.headline(.noWallFound), "No wall found")
        equal("headline phone only", ConnectionWords.headline(.phoneOnly), "Using this phone")
        equal("headline offline, timed out", ConnectionWords.headline(.offline(since: now), problem: .timedOut), "Wall offline")
        equal("headline the wall answered with an error", ConnectionWords.headline(.offline(since: now), problem: .httpError), "Wall not ready")
        equal("headline stand-in, the wall answered with an error", ConnectionWords.headline(.noWallFound, problem: .httpError), "Wall not ready")
        equal("headline something else answers", ConnectionWords.headline(.offline(since: now), problem: .notTessera), "No wall at this address")
        equal("headline offline, nothing listening", ConnectionWords.headline(.offline(since: now), problem: .refused), "Wall not ready")
        equal("headline stand-in, nothing listening", ConnectionWords.headline(.noWallFound, problem: .refused), "Wall not ready")
        equal("headline live ignores an old problem", ConnectionWords.headline(.live(lightsOff: false), problem: .httpError), "Connected")
        equal("status live", ConnectionWords.status(.live(lightsOff: false), host: "127.0.0.1:65367"), "Responding at 127.0.0.1:65367")
        equal("status lights off", ConnectionWords.status(.live(lightsOff: true), host: "h:1"), "Responding at h:1. The lights are off.")
        equal("status searching", ConnectionWords.status(.searching, host: "h:1"), "Trying h:1")
        func offline(_ ago: TimeInterval, _ problem: LinkProblem? = nil) -> String {
            ConnectionWords.status(.offline(since: now.addingTimeInterval(-ago)), host: "h:1", problem: problem, now: now,
                                   locale: posix, timeZone: utc)
        }
        func clockAgo(_ ago: TimeInterval) -> String {
            ConnectionCheck.clock(now.addingTimeInterval(-ago), now: now, locale: posix, timeZone: utc)
        }
        equal("status offline", offline(720), "No response since " + clockAgo(720))
        equal("status offline a moment ago", offline(20), "No response since " + clockAgo(20))
        check("offline never says just now", !offline(20).contains("just now") && !offline(0).contains("just now"))
        equal("status offline past an hour", offline(7300), "No response for 2 hours")
        equal("status offline for days", offline(3 * 86400 + 60), "No response for 3 days")
        equal("status offline, the wall reported an error", offline(600, .httpError), "No normal response since " + clockAgo(600))
        equal("status offline, something else answers", offline(7300, .notTessera), "No response from the wall for 2 hours")
        equal("status offline, nothing listening", offline(600, .refused), "No normal response since " + clockAgo(600))
        equal("status phone only", ConnectionWords.status(.phoneOnly, host: "h:1"),
              "Tessera is not contacting the wall. Changes apply only to the preview on this phone.")
        check("reason only offline and no wall found",
              ConnectionWords.showsReason(.offline(since: now)) && ConnectionWords.showsReason(.noWallFound)
              && !ConnectionWords.showsReason(.phoneOnly) && !ConnectionWords.showsReason(.live(lightsOff: false))
              && !ConnectionWords.showsReason(.searching))
        equal("caption live", ConnectionWords.caption(.live(lightsOff: false), frameFromPhone: false, mode: "art"), "LIVE")
        equal("caption lights off", ConnectionWords.caption(.live(lightsOff: false), frameFromPhone: false, mode: "off"), "LIGHTS OFF")
        equal("caption offline art", ConnectionWords.caption(.offline(since: now), frameFromPhone: false, mode: "art"), "LAST FRAME")
        equal("caption offline lamp", ConnectionWords.caption(.offline(since: now), frameFromPhone: false, mode: "ambient"), "PREVIEW")
        equal("caption offline phone frame", ConnectionWords.caption(.offline(since: now), frameFromPhone: true, mode: "art"), "PREVIEW")
        equal("caption stand-in", ConnectionWords.caption(.noWallFound, frameFromPhone: true, mode: "art"), "PREVIEW")
        equal("caption phone only", ConnectionWords.caption(.phoneOnly, frameFromPhone: true, mode: "art"), "PREVIEW")
        equal("primary live", ConnectionWords.primary(.live(lightsOff: false)), "Check the connection")
        equal("primary searching", ConnectionWords.primary(.searching), "Looking\u{2026}")
        equal("primary offline", ConnectionWords.primary(.offline(since: now)), "Look for the wall again")
        equal("primary phone only", ConnectionWords.primary(.phoneOnly), "Connect to the wall")
        equal("footnote offline", ConnectionWords.footnote(.offline(since: now)),
              "Tessera keeps trying on its own. The check shows where the connection stops.")
        equal("footnote stand-in does not repeat the status", ConnectionWords.footnote(.noWallFound),
              "The check shows where the connection stops.")
        equal("footnote phone only promises only what the check does", ConnectionWords.footnote(.phoneOnly),
              "The check only reads from the wall. Changes stay on this phone until you connect.")
        equal("waiting note away", ConnectionWords.waitingNote(.offline(since: now)), "Sends as soon as the wall responds.")
        equal("waiting note live", ConnectionWords.waitingNote(.live(lightsOff: false)), "Send now to try again.")
        equal("waiting note phone only", ConnectionWords.waitingNote(.phoneOnly), "Sends when you connect to the wall.")

        equal("mac away first", ConnectionWords.macDetail(live: false, loaded: true, available: true, endpoint: "x", answering: true), "Unknown until the wall responds")
        equal("mac loading", ConnectionWords.macDetail(live: true, loaded: false, available: false, endpoint: nil, answering: nil), "Checking\u{2026}")
        equal("mac older wall", ConnectionWords.macDetail(live: true, loaded: true, available: false, endpoint: nil, answering: nil), "Not available on this wall")
        equal("mac no endpoint", ConnectionWords.macDetail(live: true, loaded: true, available: true, endpoint: " ", answering: nil), "Not connected")
        equal("mac answering", ConnectionWords.macDetail(live: true, loaded: true, available: true, endpoint: "http://mac:8790", answering: true), "Connected")
        equal("mac silent", ConnectionWords.macDetail(live: true, loaded: true, available: true, endpoint: "http://mac:8790", answering: false), "Not responding")
        equal("mac unchecked", ConnectionWords.macDetail(live: true, loaded: true, available: true, endpoint: "http://mac:8790", answering: nil), "Address saved, not checked yet")
        equal("occupant identify", ConnectionWords.occupant("identify"), "Another glow is on the wall.")
        equal("occupant panel", ConnectionWords.occupant("panel"), "A panel check is on the wall.")
        equal("occupant unknown", ConnectionWords.occupant("mystery"), "Another screen is using the wall.")

        // Addresses get their own line at large sizes, so none breaks mid-name.
        typealias Piece = ConnectionWords.Piece
        equal("pieces status", ConnectionWords.addressPieces("Responding at album-matrix.local:8788"),
              [Piece(text: "Responding at", isAddress: false), Piece(text: "album-matrix.local:8788", isAddress: true)])
        equal("pieces keep punctuation and the words after", ConnectionWords.addressPieces(
                "Nothing responded at 192.168.1.40. The number may have changed. Try qa-wall.local:8788."),
              [Piece(text: "Nothing responded at", isAddress: false), Piece(text: "192.168.1.40.", isAddress: true),
               Piece(text: "The number may have changed. Try", isAddress: false), Piece(text: "qa-wall.local:8788.", isAddress: true)])
        equal("pieces a bare address", ConnectionWords.addressPieces("[fe80::1]:8788"), [Piece(text: "[fe80::1]:8788", isAddress: true)])
        equal("pieces a name in a reason", ConnectionWords.addressPieces("Last try: the name album-matrix.local was not found.").map(\.isAddress),
              [false, true, false])
        for sentence in ["Last try: no response within 3 seconds.", "Sep 26, 9:41 AM", "Slow, 1.9 s", "Quick, 38 ms",
                         "Use a name ending in .local or the wall\u{2019}s number, under Wall address.",
                         "Join this phone to the Wi-Fi the wall uses.", "Last try: the wall reported an error (HTTP 503).",
                         "Not a Tessera wall"] {
            equal("no address in \(sentence.debugDescription)", ConnectionWords.addressPieces(sentence).filter(\.isAddress).count, 0)
        }

        equal("advice default", ConnectionAdvice.steps(for: nil).map(\.title), ["Power", "Same Wi-Fi", "Give it a minute"])
        equal("advice refused leaves out Wi-Fi", ConnectionAdvice.steps(for: .refused).map(\.title), ["Give it a minute", "Restart the wall"])
        equal("advice after a dropped connection leaves out Wi-Fi and permission", ConnectionAdvice.steps(for: .dropped).map(\.title),
              ["Give it a minute", "Restart the wall"])
        equal("advice blocked name", ConnectionAdvice.steps(for: .blockedName).first?.title, "Change the address")
        equal("advice after an error reply leaves out power and Wi-Fi", ConnectionAdvice.steps(for: .httpError).map(\.title),
              ["Give it a minute", "Restart the wall"])
        equal("advice without a failed step falls back to the problem", ConnectionAdvice.steps(for: .refused, check: passed).map(\.title),
              ["Give it a minute", "Restart the wall"])
        equal("advice with no check falls back to the problem", ConnectionAdvice.steps(for: .noPath, check: nil).first?.title, "Same Wi-Fi")
        equal("advice when something else answers", ConnectionAdvice.steps(for: .notTessera).first?.title, "Change the address")

        // No line breaks at a hyphen: a word joiner follows each one.
        equal("unbreakable name", ConnectionWords.unbreakable("like album-matrix.local:8788."), "like album-\u{2060}matrix.local:8788.")
        equal("unbreakable leaves plain copy", ConnectionWords.unbreakable("Responding at 127.0.0.1:65368"), "Responding at 127.0.0.1:65368")
        equal("unbreakable reads the same", ConnectionWords.unbreakable("qa-wall.local:8788 and Wi-Fi")
            .replacingOccurrences(of: "\u{2060}", with: ""), "qa-wall.local:8788 and Wi-Fi")

        // MARK: Time words

        equal("clock today", ConnectionCheck.clock(now.addingTimeInterval(-60), now: now, locale: posix, timeZone: utc),
              ConnectionCheck.time(now.addingTimeInterval(-60), locale: posix, timeZone: utc))
        check("clock earlier names the day", ConnectionCheck.clock(now.addingTimeInterval(-2 * 86400), now: now, locale: posix, timeZone: utc)
              .contains(ConnectionCheck.day(now.addingTimeInterval(-2 * 86400), now: now, locale: posix, timeZone: utc) ?? "missing"))
        check("no day today", ConnectionCheck.day(now, now: now, locale: posix, timeZone: utc) == nil)
        equal("column today is the time", ConnectionCheck.column(now.addingTimeInterval(-60), now: now, locale: posix, timeZone: utc),
              ConnectionCheck.time(now.addingTimeInterval(-60), locale: posix, timeZone: utc))
        equal("column before today is the day alone", ConnectionCheck.column(now.addingTimeInterval(-2 * 86400), now: now, locale: posix, timeZone: utc),
              ConnectionCheck.day(now.addingTimeInterval(-2 * 86400), now: now, locale: posix, timeZone: utc) ?? "missing")
        equal("relative under a minute", ConnectionCheck.relative(now.addingTimeInterval(-59), now: now, locale: posix), "just now")
        equal("relative minutes", ConnectionCheck.relative(now.addingTimeInterval(-180), now: now, locale: posix), "3 minutes ago")
        // The formatters are kept, one per template, locale and time zone.
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        equal("a kept formatter gives the same time", ConnectionCheck.time(now, locale: posix, timeZone: utc),
              ConnectionCheck.time(now, locale: posix, timeZone: utc))
        check("another time zone gets its own formatter",
              ConnectionCheck.time(now, locale: posix, timeZone: utc) != ConnectionCheck.time(now, locale: posix, timeZone: tokyo))
        check("another template gets its own formatter",
              ConnectionCheck.clock(now.addingTimeInterval(-2 * 86400), now: now, locale: posix, timeZone: utc)
                != ConnectionCheck.time(now.addingTimeInterval(-2 * 86400), locale: posix, timeZone: utc))
        equal("relative kept", ConnectionCheck.relative(now.addingTimeInterval(-180), now: now, locale: posix), "3 minutes ago")
        equal("duration an hour", ConnectionCheck.duration(3700, locale: posix), "1 hour")
        equal("duration a day", ConnectionCheck.duration(90_000, locale: posix), "1 day")

        // MARK: Why the last poll failed (LinkRecords.swift)

        func url(_ code: Int) -> Error { URLError(URLError.Code(rawValue: code)) }
        for (code, want) in [(-1001, LinkProblem.timedOut), (-1003, .nameNotFound), (-1006, .nameNotFound), (-1004, .refused),
                             (-1009, .noPath), (-1005, .dropped), (-1017, .notTessera), (-1022, .blockedName), (-999, .other)] {
            equal("problem \(code)", LinkProblem.from(url(code), status: nil), want)
        }
        equal("problem status wins", LinkProblem.from(url(-1011), status: 503), .httpError)
        equal("problem 3840", LinkProblem.from(NSError(domain: NSCocoaErrorDomain, code: 3840), status: 200), .notTessera)
        do {
            _ = try JSONSerialization.jsonObject(with: Data("<html>".utf8))
            check("real JSON error", false)
        } catch {
            equal("problem from a real JSON error", LinkProblem.from(error, status: 200), .notTessera)
        }
        equal("sentence timed out", LinkProblem.timedOut.sentence(host: named, status: nil), "Last try: no response within 3 seconds.")
        equal("sentence name", LinkProblem.nameNotFound.sentence(host: named, status: nil), "Last try: the name album-matrix.local was not found.")
        equal("sentence refused", LinkProblem.refused.sentence(host: named, status: nil),
              "Last try: the address was reachable, but Tessera was not running there.")
        equal("sentence no path", LinkProblem.noPath.sentence(host: named, status: nil),
              "Last try: no network path to the wall. Check Wi-Fi and Local Network access.")
        equal("sentence dropped", LinkProblem.dropped.sentence(host: named, status: nil),
              "Last try: the connection closed before the wall answered.")
        equal("reason dropped", LinkProblem.dropped.reason(host: named, status: nil), "The connection closed before the wall answered.")
        equal("sentence http", LinkProblem.httpError.sentence(host: named, status: 503), "Last try: the wall reported an error (HTTP 503).")
        equal("sentence not tessera", LinkProblem.notTessera.sentence(host: named, status: nil), "Last try: the reply was not from a Tessera wall.")
        equal("sentence blocked", LinkProblem.blockedName.sentence(host: "wall.lan:8788", status: nil),
              "Last try: iPhone blocks plain connections to wall.lan. Use a name ending in .local or the wall\u{2019}s number.")
        equal("sentence other", LinkProblem.other.sentence(host: named, status: nil), "Last try: the connection failed.")
        equal("reason drops Last try", LinkProblem.timedOut.reason(host: named, status: nil), "No response within 3 seconds.")

        // MARK: History

        var history = LinkHistory()
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        for i in 0..<35 { history.append(LinkEvent(kind: .looking, at: base.addingTimeInterval(Double(i)))) }
        equal("history caps at 30", history.events.count, 30)
        check("history newest first", history.events.first?.at == base.addingTimeInterval(34) && history.events.last?.at == base.addingTimeInterval(5))
        history.append(LinkEvent(kind: .stopped, at: base.addingTimeInterval(20), detail: "No response within 3 seconds."))
        check("a late stopped event sits at its own time", history.events.firstIndex { $0.kind == .stopped } == 14)
        let defaults = UserDefaults(suiteName: "tessera.connection.checks.\(UUID().uuidString)")!
        history.save(to: defaults)
        equal("history round trip", LinkHistory.load(from: defaults), history)
        equal("empty history", LinkHistory.load(from: UserDefaults(suiteName: "tessera.connection.empty.\(UUID().uuidString)")!), LinkHistory())

        equal("first answer is responding", LinkHistory().answerKind, .responding)
        var outage = LinkHistory(events: [LinkEvent(kind: .responding, at: base)])
        equal("a relaunch logs nothing", outage.answerKind, nil)
        outage.append(LinkEvent(kind: .stopped, at: base.addingTimeInterval(10)))
        outage.append(LinkEvent(kind: .waiting, at: base.addingTimeInterval(20)))
        equal("an outbox event cannot hide a stop", outage.answerKind, .respondingAgain)
        outage.append(LinkEvent(kind: .address, at: base.addingTimeInterval(30)))
        equal("a new address answers as responding", outage.answerKind, .responding)

        var episode = LinkEpisode()
        episode.answer()
        var stops = 0
        for miss in 1...5 where episode.miss(miss, offline: true) { stops += 1 }
        // The owner looks again: misses start over, the wall still silent.
        for miss in 1...5 where episode.miss(miss, offline: true) { stops += 1 }
        equal("offline, look, three more misses logs one stop", stops, 1)
        var waking = LinkEpisode()
        waking.answer()
        check("two misses waking from sleep log nothing", !waking.miss(1, offline: true) && !waking.miss(2, offline: true))
        var neverAnswered = LinkEpisode()
        check("a wall that never answered never stopped", !neverAnswered.miss(3, offline: true))
        equal("event sentence", LinkEvent(kind: .noWallFound).sentence, "No wall found, preview on this phone")

        // Whose name the session remembers: only an answer since the last
        // address change makes it this address's.
        check("no history, no name", !ConnectionCheck.nameIsCurrent([]))
        check("an answer makes the name current", ConnectionCheck.nameIsCurrent(
            LinkHistory(events: [LinkEvent(kind: .responding, at: base), LinkEvent(kind: .stopped, at: base.addingTimeInterval(9))]).events))
        check("an address change since the answer does not", !ConnectionCheck.nameIsCurrent(
            LinkHistory(events: [LinkEvent(kind: .responding, at: base), LinkEvent(kind: .address, at: base.addingTimeInterval(9), detail: "192.168.1.40:8788")]).events))
        check("an answer after the change does", ConnectionCheck.nameIsCurrent(
            LinkHistory(events: [LinkEvent(kind: .address, at: base, detail: "192.168.1.40:8788"),
                                 LinkEvent(kind: .respondingAgain, at: base.addingTimeInterval(9))]).events))
        check("only outbox events say nothing", !ConnectionCheck.nameIsCurrent(
            LinkHistory(events: [LinkEvent(kind: .waiting, at: base), LinkEvent(kind: .sent, at: base.addingTimeInterval(9))]).events))

        let failed = checks.filter { $0["passed"] as? Bool == false }.count
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: ["passed": checks.count - failed, "failed": failed,
                                                                                   "checks": checks], options: [.sortedKeys]))
        if failed > 0 { exit(1) }
    }
}
