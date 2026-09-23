import Foundation

@main
struct TimeInputChecks {
    static func main() throws {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        for (minutes, seconds, expected) in [("0", "06", 6), ("0", "59", 59), ("1", "00", 60), ("25", "00", 1500), ("179", "59", 10799), ("180", "00", 10800), (" 05 ", " 03 ", 303)] {
            check("Custom duration \(minutes):\(seconds)", TimeInput.seconds(minutes: minutes, seconds: seconds) == expected)
        }
        for (minutes, seconds) in [("0", "00"), ("0", "05"), ("180", "01"), ("181", "00"), ("-1", "10"), ("1", "-1"), ("1", "60"), ("", "00"), ("1", ""), ("x", "00"), ("1", "3x"), ("1.5", "00"), ("1e2", "00"), ("999999999999999999999999999999", "00")] {
            check("Reject invalid duration \(minutes):\(seconds)", TimeInput.seconds(minutes: minutes, seconds: seconds) == nil)
        }
        for (seconds, expected) in [(-1,"0:00"),(0,"0:00"),(59,"0:59"),(60,"1:00"),(3599,"59:59"),(3600,"1:00:00"),(10800,"3:00:00")] {
            check("Countdown formats \(seconds)", TimeInput.clock(seconds) == expected)
        }
        for hhmm in ["00:00", "00:59", "06:01", "12:00", "18:45", "23:59"] {
            check("Wall civil time round trip \(hhmm)", TimeInput.civilTime(TimeInput.date(hhmm)) == hhmm)
        }
        for invalid in ["", "x", "24:00", "12:60", "12:00:00", "-1:00"] {
            check("Malformed alarm safely defaults \(invalid)", TimeInput.civilTime(TimeInput.date(invalid)) == "07:00")
        }
        check("Midnight 12 hour", TimeInput.timeLabel("00:00", twentyFour: false) == "12:00 AM")
        check("Noon 12 hour", TimeInput.timeLabel("12:00", twentyFour: false) == "12:00 PM")
        check("Evening 12 hour", TimeInput.timeLabel("18:45", twentyFour: false) == "6:45 PM")
        check("24 hour keeps leading zero", TimeInput.timeLabel("06:01", twentyFour: true) == "06:01")
        check("Named wall timezone wins offset", TimeInput.timeZone(identifier: "America/New_York", offset: 0)?.identifier == "America/New_York")
        check("Older wall falls back to UTC offset", TimeInput.timeZone(identifier: "invalid zone", offset: -14400)?.secondsFromGMT() == -14400)
        check("Unknown timezone stays unknown", TimeInput.timeZone(identifier: nil, offset: nil) == nil)
        check("Impossible timezone offset rejected", TimeInput.timeZone(identifier: nil, offset: 70000) == nil)
        check("Editor uses fixed UTC zone", TimeInput.editorCalendar.timeZone.secondsFromGMT() == 0)
        check("Civil 7 AM remains seven despite phone travel", TimeInput.date("07:00").timeIntervalSince1970 == 978332400)
        check("Spoken duration units are complete", TimeInput.duration(3661) == "1 hour, 1 minute, 1 second")
        check("Spoken duration plurals", TimeInput.duration(7382) == "2 hours, 3 minutes, 2 seconds")
        let failures = checks.filter { !($0["passed"] as! Bool) }.count
        let report: [String: Any] = ["passed": checks.count - failures, "failed": failures, "checks": checks]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]))
        if failures > 0 { exit(1) }
    }
}
