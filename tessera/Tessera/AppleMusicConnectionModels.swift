import Foundation

enum AppleMusicPermission: String, Equatable {
    case notAsked, denied, restricted, authorized, unknown
    var isAuthorized: Bool { self == .authorized }
    var isRefused: Bool { self == .denied || self == .restricted }
    var title: String {
        switch self {
        case .notAsked: "A little permission. A whole room of music."
        case .authorized: "Your music, in the room."
        case .denied: "Music access is off."
        case .restricted: "Music access is restricted."
        case .unknown: "Music access is unavailable."
        }
    }
    var detail: String {
        switch self {
        case .notAsked: "Let Tessera read the song and artwork playing in Music on this iPhone."
        case .authorized: "Tessera can read this iPhone’s Music player and share its song with your wall."
        case .denied: "You can allow Media & Apple Music access for Tessera in Settings."
        case .restricted: "A device or family restriction limits access. Check Screen Time or ask the person who manages this iPhone."
        case .unknown: "This device did not report a supported permission state. Check Settings and try again."
        }
    }
}

enum AppleMusicPlayback: String, Equatable {
    case playing, paused, stopped, interrupted, seeking
    var label: String {
        switch self {
        case .playing: "Playing on this iPhone"
        case .paused: "Paused on this iPhone"
        case .stopped: "Queued in Music"
        case .interrupted: "Playback interrupted"
        case .seeking: "Seeking in Music"
        }
    }
    var symbol: String {
        switch self {
        case .playing: "play.fill"
        case .paused: "pause.fill"
        case .stopped: "music.note.list"
        case .interrupted: "pause.circle"
        case .seeking: "forward.fill"
        }
    }
}

struct AppleMusicTrack: Equatable {
    let identity: String
    let title: String
    let artist: String
    let album: String
    let storeID: String
    let playback: AppleMusicPlayback

    var catalogueURL: URL? { AppleMusicDestination.song(storeID: storeID) }
    var displayTitle: String { title.isEmpty ? "Untitled track" : title }
    var displayArtist: String { artist.isEmpty ? "Unknown artist" : artist }
}

enum AppleMusicDestination {
    static let home = URL(string: "https://music.apple.com/")!
    /// Store IDs are identifiers, never arbitrary URLs or search strings.
    static func song(storeID: String) -> URL? {
        guard (1...20).contains(storeID.utf8.count), storeID.first != "0",
              storeID.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return URL(string: "https://music.apple.com/song/\(storeID)")
    }
}

struct MusicPushReceipt: Equatable {
    let host: String
    let title: String
    let artist: String
    let playing: Bool
    let received: Date

    func confirms(_ track: AppleMusicTrack, host currentHost: String, at now: Date) -> Bool {
        guard !track.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              host == currentHost, now.timeIntervalSince(received) >= 0,
              now.timeIntervalSince(received) < 15 else { return false }
        return title == track.title && artist == track.artist && playing == (track.playback == .playing)
    }
}

/// A request generation is tied to one lifetime of the phone-to-wall reporter.
/// Its target and sequence must still belong to that lifetime before accepting an ACK.
struct MusicPushDeliveryGate {
    private(set) var generation = UUID()
    private var accepted: [String: Int] = [:]
    mutating func reset() { generation = UUID(); accepted.removeAll() }
    mutating func accept(generation requestGeneration: UUID, target: String, sequence: Int, currentTargets: [String]) -> Bool {
        guard requestGeneration == generation, currentTargets.contains(target), sequence >= 0,
              sequence > (accepted[target] ?? -1) else { return false }
        accepted[target] = sequence
        return true
    }
}
