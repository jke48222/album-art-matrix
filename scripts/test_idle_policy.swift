import Foundation

@main struct IdlePolicyTests {
    static func main() throws {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) {
            checks.append(["name": name, "passed": passed])
        }
        // These identifiers are persisted by existing walls. UI labels may
        // evolve, but choosing an option must still send the same API value.
        let saved: [String: IdlePolicy] = ["black": .black, "hold": .hold, "dim": .dim,
                                          "ambient": .ambient, "weather": .weather]
        for (raw, expected) in saved.sorted(by: { $0.key < $1.key }) {
            let policy = IdlePolicy.current(raw)
            check("Existing wall policy round-trips: \(raw)", policy == expected && policy.id == raw)
        }
        check("Every server-supported policy is available once",
              Set(IdlePolicy.allCases.map(\.rawValue)) == Set(saved.keys)
                && IdlePolicy.allCases.count == saved.count)
        check("Unknown future firmware policy uses safe local fallback",
              IdlePolicy.current("scheduled") == .black)
        check("Missing or corrupt saved value uses safe local fallback",
              ["", " ", "\n", "BLACK", "dim\0"].allSatisfy { IdlePolicy.current($0) == .black })
        // A choice must remain distinguishable when VoiceOver combines the
        // row, when the compact plan is shown, and without relying on color.
        check("All choices have distinct accessible names",
              Set(IdlePolicy.allCases.map(\.title)).count == saved.count)
        check("Compact plan choices remain distinct",
              Set(IdlePolicy.allCases.map(\.shortTitle)).count == saved.count)
        check("Every choice includes an explanatory caption and symbol",
              IdlePolicy.allCases.allSatisfy { !$0.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.symbol.isEmpty })
        check("Quiet plan captions describe the actual policy multiplier",
              IdlePolicy.dim.detail.contains("30%") && IdlePolicy.dim.shortTitle.contains("30%"))
        check("Changing presentation does not require translated protocol identifiers",
              IdlePolicy.allCases.allSatisfy { $0.id == $0.rawValue && !$0.id.contains(" ") })
        let failures = checks.filter { !($0["passed"] as! Bool) }.count
        let report: [String: Any] = ["suite": "Production IdlePolicy", "passed": checks.count - failures,
                                     "failed": failures, "checks": checks]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]))
        FileHandle.standardOutput.write(Data("\n".utf8))
        if failures > 0 { exit(1) }
    }
}
