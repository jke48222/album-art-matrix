import Foundation

@main struct ImagineModelChecks {
    static func main() throws {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ okay: Bool) { checks.append(["name": name, "passed": okay]) }
        func decode(_ json: String) throws -> WallImagined { try JSONDecoder().decode(WallImagined.self, from: Data(json.utf8)) }
        let empty = try decode(#"{"ready":false,"images":[]}"#)
        check("An unconfigured studio is not busy", !empty.isDrawing)
        check("Saved images can exist without an image key", empty.images.isEmpty && empty.ready == false)
        let waiting = try decode(#"{"ready":true,"busy":true,"job_id":"job-one","images":[],"live":{"stage":"waiting","prompt":"a moon"}}"#)
        check("Background job is pending", waiting.isDrawing)
        check("Job identity survives response decoding", waiting.job_id == "job-one")
        let partial = try decode(#"{"images":[],"live":{"stage":"partial","partials":1}}"#)
        check("Received first image is described without a percentage", partial.progressDescription.contains("first image") && !partial.progressDescription.contains("%"))
        let more = try decode(#"{"images":[],"live":{"stage":"partial","partials":3}}"#)
        check("Received image count is factual", more.progressDescription.hasPrefix("3 previews"))
        let failed = try decode(#"{"images":[],"live":{"stage":"failed","problem":"Service unavailable"},"busy":false}"#)
        check("A failure does not keep the create button spinning", !failed.isDrawing)
        let saved = try decode(#"{"images":[{"id":"123-a-moon","prompt":"a moon","provider":"openai","ts":0,"took_s":42}],"live":{"stage":"done"},"on_wall":false,"showing_id":"123-a-moon"}"#)
        check("A completed picture off the wall keeps truthful ownership", saved.on_wall == false && saved.showing_id == saved.images.first?.id)
        check("Epoch zero is a valid picture timestamp", saved.images.first?.date == Date(timeIntervalSince1970: 0))
        check("Valid image IDs map to the wall's saved PNG", WallImagined.imageURL(host: "localhost:8788", id: "123-a-moon")?.absoluteString == "http://localhost:8788/imagine/123-a-moon.png")
        for id in ["../secret", "photo?other", "https://elsewhere", "a/b", "", String(repeating: "a", count: 81)] {
            check("Reject unsafe image identity \(id)", WallImagined.imageURL(host: "localhost:8788", id: id) == nil)
        }
        check("A missing wall cannot produce an image URL", WallImagined.imageURL(host: "", id: "123-a-moon") == nil)
        let failedCount = checks.filter { $0["passed"] as? Bool == false }.count
        let report: [String: Any] = ["passed": checks.count - failedCount, "failed": failedCount, "checks": checks]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if CommandLine.arguments.count > 1 { try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
        FileHandle.standardOutput.write(data)
        if failedCount > 0 { exit(1) }
    }
}
