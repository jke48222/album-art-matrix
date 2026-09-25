import Foundation

@main struct DiscoveryTests {
    static func main() throws {
        var checks: [[String: Any]] = []
        func check(_ condition: Bool, _ name: String) { checks.append(["name": name, "passed": condition]) }
        let decoder = JSONDecoder()
        func result(_ json: String) throws -> ShowResult { try decoder.decode(ShowResult.self, from: Data(json.utf8)) }
        func earworm(_ json: String) throws -> Earworm { try decoder.decode(Earworm.self, from: Data(json.utf8)) }
        let showing = try result(#"{"id":"a","title":"Signal","shown":true,"active":true,"preview_png":"cGl4ZWxz","preview_size":64}"#)
        check(showing.receipt == "Showing on the wall", "Only active acknowledged art claims current display")
        check(showing.preview_png == "cGl4ZWxz" && showing.preview_size == 64, "Phone keeps exact wall composition receipt and resolution")
        check(showing.id == "a", "Stable receipt identity survives decoding")
        check(try result(#"{"shown":true,"active":false}"#).receipt == "Previously sent to the wall", "Replaced artwork is not described as current")
        check(try result(#"{"shown":false,"active":false}"#).receipt == "Found for you", "Found artwork never falsely claims sending")
        check(try result(#"{"what":"play","active":true,"playing":true}"#).receipt == "Playing on the wall", "Video display receipt is explicit")
        check(try result(#"{"what":"play","active":false,"playing":true}"#).receipt == "Previously sent to the wall", "Ended video does not claim current playback")
        check(try result(#"{"title":"   ","album":"Signal"}"#).heading == "Signal", "Blank search title falls back to useful album identity")
        check(try result(#"{"credit":"NASA","artist":"Archive"}"#).byline == "NASA", "Picture attribution takes precedence over artist fallback")
        check(try result(#"{}"#).heading == "Your discovery", "Older sparse responses get a readable identity")
        check(try !result(#"{}"#).isUsable, "Empty success body cannot acknowledge a discovery")
        check(try !result(#"{"title":"Signal"}"#).isUsable, "Search success requires an actual wall result receipt")
        check(showing.isUsable, "A complete discovery result can be accepted")
        let noMatch = try earworm(#"{"title":"Signal","artist":"North","shown":false,"confidence":0.3}"#)
        check(noMatch.confidenceLabel == "A possibility to explore", "Low confidence is presented as a possibility")
        check(noMatch.shareText == "Signal — North", "Sharing uses song metadata only")
        check(noMatch.isUsable, "An identified song remains useful when its cover could not be displayed")
        check(try !earworm(#"{"title":"Signal"}"#).isUsable, "Missing artist cannot masquerade as a song identification")
        check(try earworm(#"{"confidence":0.7}"#).confidenceLabel == "A likely match", "Moderate confidence avoids certainty claims")
        check(try earworm(#"{"confidence":0.9}"#).confidenceLabel == "A strong possibility", "High confidence still leaves room for mistakes")
        check(try earworm(#"{}"#).confidenceLabel == "A possible match", "Missing confidence never claims certainty")
        let ready = try decoder.decode(EarwormStatus.self, from: Data(#"{"ready":true,"pending":true,"last":{"id":"b","title":"Signal"}}"#.utf8))
        check(ready.pending == true && ready.last?.id == "b", "Previous result remains available during a new identification")
        let show = try decoder.decode(DiscoveryStatus.self, from: Data(#"{"pending":false,"picture_provider":"Google Images","video_available":false}"#.utf8))
        check(show.picture_provider == "Google Images" && show.video_available == false, "Actual search capability and source decode")
        check(DiscoveryScope.allCases.count == 3, "Single composer includes pictures covers and videos")
        check(Set(DiscoveryScope.allCases.map(\.placeholder)).count == 3, "Each scope gives an intentional search prompt")
        check(Set(DiscoveryScope.allCases.map(\.example)).count == 3, "Search examples stay appropriate to their scope")
        let output: [String: Any] = ["checks": checks, "passed": checks.filter { $0["passed"] as? Bool == true }.count, "total": checks.count]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        if CommandLine.arguments.count > 1 { try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
        print(String(data: data, encoding: .utf8)!)
        if checks.contains(where: { $0["passed"] as? Bool != true }) { exit(1) }
    }
}
