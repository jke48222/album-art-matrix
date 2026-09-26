import Foundation

@main struct ShelfModelTests {
    static func main() throws {
        var checks: [[String: Any]] = []
        func check(_ condition: Bool, _ name: String) { checks.append(["name": name, "passed": condition]) }
        let json = #"{"user":"collector","token_set":true,"synced_at":1000,"syncing":false,"sync_id":"read-2","completed_sync_id":"read-2","releases":[{"release_id":1,"title":"Homogenic","artists":["Björk"],"year":1997,"label":"One Little Indian","catno":"TPLP71","formats":["Vinyl"],"descriptions":["LP"],"country":"UK","cover":"https://example.org/cover.jpg","url":"https://bad.example","plays":5,"added":"2026-09-24T00:00:00Z","copies":2},{"release_id":2,"title":"Blue","artists":["Joni Mitchell"],"year":1971,"formats":["Vinyl"],"url":"https://www.discogs.com/release/2","plays":9,"added":"2026-09-25T00:00:00Z"},{"release_id":3,"title":"Hejira","artists":["Joni Mitchell"],"year":1976,"formats":["Vinyl"],"url":"https://www.discogs.com/release/3","plays":0}] }"#
        let decoder = JSONDecoder()
        var shelf = try decoder.decode(ShelfList.self, from: Data(json.utf8))
        check(shelf.configured, "Known account and token are configured")
        check(shelf.copyCount == 4, "Two copies of one pressing count separately")
        check(shelf.artistCount == 2, "Repeated artist is counted once")
        check(shelf.uniqueReleases.count == 3, "One row per pressing")
        check(shelf.visible(query: "bjork", order: .title).map(\.id) == [1], "Search folds diacritics")
        check(shelf.visible(query: " HOMOGENIC \n TPLP71 ", order: .title).map(\.id) == [1], "Search requires all terms across title and catalogue")
        check(shelf.visible(query: "vinyl uk", order: .title).map(\.id) == [1], "Format and country are searchable")
        check(shelf.visible(query: "1997", order: .title).map(\.id) == [1], "Year is searchable")
        check(shelf.visible(query: "one little", order: .title).map(\.id) == [1], "Record label is searchable")
        check(shelf.visible(query: "blue bjork", order: .title).isEmpty, "Unmatched term does not broaden search")
        check(shelf.visible(query: "   ", order: .title).count == 3, "Whitespace search shows entire collection")
        check(shelf.visible(query: "", order: .title).map(\.id) == [2, 3, 1], "Title ordering is stable")
        check(shelf.visible(query: "", order: .artist).map(\.id) == [1, 2, 3], "Artist ordering breaks ties by title")
        check(shelf.visible(query: "", order: .year).map(\.id) == [1, 3, 2], "Release year sorts newest first")
        check(shelf.visible(query: "", order: .recent).map(\.id) == [2, 1, 3], "Recently added keeps missing dates last")
        check(shelf.visible(query: "", order: .played).map(\.id) == [2, 1, 3], "Play history orders frequent appearances first")
        check(!shelf.isStale(at: Date(timeIntervalSince1970: 1001)), "Fresh collection is not called stale")
        check(shelf.isStale(at: Date(timeIntervalSince1970: 23000)), "Collection overdue for its six hour read is stale")
        check(!shelf.isStale(at: Date(timeIntervalSince1970: 900)), "Clock skew does not falsely age collection")
        check(shelf.releases[0].formatLine == "Vinyl · LP", "Pressing formats preserve descriptions")
        check(shelf.releases[0].discogsURL?.absoluteString == "https://www.discogs.com/release/1", "Pressing link is pinned to trusted Discogs identity")
        check(shelf.releases[0].coverURL?.scheme == "https", "HTTPS artwork is supported")
        check(shelf.releases[1].copyCount == 1, "Legacy release defaults to one copy")
        check(shelf.sync_id == shelf.completed_sync_id, "Read completion carries the exact request identity")
        shelf.releases.append(shelf.releases[0])
        check(shelf.uniqueReleases.count == 3, "Legacy duplicate IDs cannot destabilize SwiftUI navigation")
        shelf.releases[0].copies = -3
        check(shelf.releases[0].copyCount == 1, "Malformed negative copy count is clamped")
        shelf.releases[0].cover = "file:///etc/private"
        check(shelf.releases[0].coverURL == nil, "Collection artwork cannot open local file URLs")
        shelf.releases[0].release_id = -1
        check(shelf.releases[0].discogsURL == nil, "Invalid pressing ID cannot become external link")
        check(shelf.uniqueReleases.allSatisfy { $0.id > 0 }, "Invalid IDs are excluded from collection navigation")
        shelf.token_set = false
        check(!shelf.configured, "User alone cannot claim connected account")
        shelf.synced_at = nil
        check(shelf.isStale(), "Never read collection has no invented freshness")
        shelf.synced_at = .infinity
        check(shelf.isStale(), "Nonfinite server timestamp cannot crash date formatting")
        let legacy = try decoder.decode(ShelfList.self, from: Data(#"{"releases":[]}"#.utf8))
        check(!legacy.configured && legacy.uniqueReleases.isEmpty, "Older wall response still decodes")
        let receipt = try decoder.decode(ShelfSyncReceipt.self, from: Data(#"{"accepted":true,"sync_id":"r1","releases":3,"syncing":true}"#.utf8))
        check(receipt.accepted == true && receipt.sync_id == "r1", "Sync response permits numeric record count and retains receipt")
        check(Set(ShelfOrder.allCases.map(\.rawValue)).count == 5, "Five distinct collection orders")
        let output: [String: Any] = ["checks": checks, "passed": checks.filter { $0["passed"] as? Bool == true }.count, "total": checks.count]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        if CommandLine.arguments.count > 1 { try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
        print(String(data: data, encoding: .utf8)!)
        if checks.contains(where: { $0["passed"] as? Bool != true }) { exit(1) }
    }
}
