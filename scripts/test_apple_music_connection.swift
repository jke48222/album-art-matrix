import Foundation

@main
struct AppleMusicConnectionChecks {
    static func main() throws {
        var failures: [String] = []
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            count += 1
            if !condition() { failures.append(name) }
        }
        for permission in [AppleMusicPermission.notAsked, .denied, .restricted, .unknown] {
            check(!permission.isAuthorized, "Unapproved permission never enables reads: \(permission)")
        }
        check(AppleMusicPermission.authorized.isAuthorized, "Explicit authorization enables reads")
        check(AppleMusicPermission.denied.isRefused && AppleMusicPermission.restricted.isRefused, "Refused binding includes managed restriction")
        check(!AppleMusicPermission.notAsked.isRefused, "Not asked does not become refused")

        check(AppleMusicDestination.song(storeID: "1146195720")?.absoluteString == "https://music.apple.com/song/1146195720", "Known catalogue ID produces the verified universal link")
        for id in ["", "0", "0001", "-1", "1.0", "12/../../../account", "https://bad.test", "1?token=private", "١٢٣", " 123", "123\n", String(repeating: "9", count: 21)] {
            check(AppleMusicDestination.song(storeID: id) == nil, "Untrusted catalogue ID rejected: \(id)")
        }
        check(AppleMusicDestination.home.host == "music.apple.com", "Empty-library navigation remains on Apple’s official service")
        let track = AppleMusicTrack(identity: "id", title: "Nights", artist: "Frank Ocean", album: "Blonde", storeID: "1146195720", playback: .playing)
        let paused = AppleMusicTrack(identity: "id", title: track.title, artist: track.artist, album: track.album, storeID: track.storeID, playback: .paused)
        let local = AppleMusicTrack(identity: "local", title: "Recording", artist: "You", album: "", storeID: "", playback: .stopped)
        check(local.catalogueURL == nil, "Local library recordings never get invented catalogue links")
        let now = Date(timeIntervalSince1970: 1000)
        let receipt = MusicPushReceipt(host: "wall-a.local:8788", title: track.title, artist: track.artist, playing: true, received: now)
        check(receipt.confirms(track, host: receipt.host, at: now), "Exact current wall ACK is confirmed")
        check(receipt.confirms(track, host: receipt.host, at: now.addingTimeInterval(14.9)), "Recent ACK remains valid between heartbeats")
        check(!receipt.confirms(track, host: receipt.host, at: now.addingTimeInterval(15)), "Stale ACK cannot masquerade as delivery")
        check(!receipt.confirms(track, host: receipt.host, at: now.addingTimeInterval(-1)), "Future clock skew never confirms freshness")
        check(!receipt.confirms(track, host: "wall-b.local:8788", at: now), "Changing walls invalidates the old delivery")
        check(!receipt.confirms(paused, host: receipt.host, at: now), "Playing ACK cannot confirm a later pause")
        let wrongArtist = MusicPushReceipt(host: receipt.host, title: track.title, artist: "Another artist", playing: true, received: now)
        check(!wrongArtist.confirms(track, host: receipt.host, at: now), "Same title by a different artist is a different song")
        let pausedReceipt = MusicPushReceipt(host: receipt.host, title: track.title, artist: track.artist, playing: false, received: now)
        check(pausedReceipt.confirms(paused, host: receipt.host, at: now), "Paused receipt confirms paused playback")

        let untitled = AppleMusicTrack(identity: "untitled", title: "", artist: "", album: "", storeID: "", playback: .playing)
        let untitledReceipt = MusicPushReceipt(host: receipt.host, title: "", artist: "", playing: true, received: now)
        check(untitled.displayTitle == "Untitled track" && untitled.title.isEmpty, "Display fallback does not contaminate the source identity")
        check(!untitledReceipt.confirms(untitled, host: receipt.host, at: now), "Empty-source clear receipt cannot pretend a song was delivered")

        var gate = MusicPushDeliveryGate()
        let generation = gate.generation
        check(gate.accept(generation: generation, target: "wall", sequence: 4, currentTargets: ["wall", "mac"]), "First wall ACK accepted")
        check(!gate.accept(generation: generation, target: "wall", sequence: 3, currentTargets: ["wall", "mac"]), "Out-of-order ACK rejected")
        check(!gate.accept(generation: generation, target: "wall", sequence: 4, currentTargets: ["wall", "mac"]), "Duplicate ACK rejected")
        check(gate.accept(generation: generation, target: "mac", sequence: 1, currentTargets: ["wall", "mac"]), "Mac and wall receipt sequences are independent")
        check(!gate.accept(generation: generation, target: "wall", sequence: 5, currentTargets: ["new-wall", "mac"]), "Removed destination cannot ACK a later request")
        check(!gate.accept(generation: generation, target: "new-wall", sequence: -1, currentTargets: ["new-wall"]), "Invalid request sequence rejected")
        gate.reset()
        check(gate.generation != generation, "Restart creates a new transport generation")
        check(!gate.accept(generation: generation, target: "wall", sequence: 99, currentTargets: ["wall"]), "Completion from stopped reporter cannot overwrite new state")
        check(gate.accept(generation: gate.generation, target: "wall", sequence: 1, currentTargets: ["wall"]), "Fresh reporter accepts its first request")
        let output: [String: Any] = ["passed": failures.isEmpty, "assertions": count, "failures": failures]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        if !failures.isEmpty { exit(1) }
    }
}
