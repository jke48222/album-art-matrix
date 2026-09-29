// Which home the app shows, and which opening plays in front of it.
//
// Foundation only, so scripts/test_about_models.swift can compile it with
// swiftc on the Mac. What is bundled is passed in (OpeningAssets), and the
// app's own answer lives next to the films (StingOpening.swift), so the rules
// here are pure and the tests can ask about a build without a film.

import Foundation

/// Three designs of the same wall, one at a time: the panel (2D), the iPod,
/// and the room itself in 3D. Chosen on the App design page. Nothing else
/// changes with it.
enum Design: String, CaseIterable {
    case classic, ipod, room

    var name: String {
        switch self {
        case .classic: "Panel"
        case .ipod: "iPod"
        case .room: "Room"
        }
    }

    /// The order the chooser shows them in: the room first, as it is the
    /// default, then the flat panel, then the iPod.
    static let displayOrder: [Design] = [.room, .classic, .ipod]

    var summary: String {
        switch self {
        case .room: "The wall hangs above a record player, and the room takes its light."
        case .classic: "The wall fills the top of the screen. Drag the artwork to dim it."
        case .ipod: "The wall sits on an iPod screen. Turn the click wheel to change the light."
        }
    }
}

/// What is saved under intro.style. "none" is a real choice now: an
/// unrecognised value used to play the room's film, so there was no way to
/// open straight to the wall on Room.
enum OpeningStyle: String, CaseIterable {
    case sting, stingRoom = "sting-room", film, mark, none

    static let key = "intro.style"

    /// Unknown or missing reads as the sting, the same fallback the one-time
    /// migration in RootView writes.
    static func saved(_ raw: String?) -> OpeningStyle {
        raw.flatMap(OpeningStyle.init(rawValue:)) ?? .sting
    }

    /// The opening a saved style actually plays in a design with what this
    /// build carries. Film and mark are each design's own, so on Panel, which
    /// has none, they play nothing. Mark on the iPod plays the iPod film, as
    /// it always has.
    static func kind(_ style: OpeningStyle, in design: Design, assets: OpeningAssets) -> OpeningKind {
        switch (style, design) {
        case (.sting, _): return assets.sting ? .sting : .none
        case (.stingRoom, _): return assets.stingKeyed ? .stingInLight : .none
        case (.film, .room): return assets.roomFilm ? .roomFilm : .none
        case (.mark, .room): return assets.roomMark ? .roomMark : .none
        case (.film, .ipod), (.mark, .ipod): return assets.iPodFilm ? .iPodFilm : .none
        default: return .none
        }
    }

    /// Every opening a design can play: the stings first, then the design's
    /// own films, then none. Nothing is offered that would not play.
    static func choices(in design: Design, assets: OpeningAssets) -> [OpeningKind] {
        var out: [OpeningKind] = []
        if assets.sting { out.append(.sting) }
        if assets.stingKeyed { out.append(.stingInLight) }
        switch design {
        case .room:
            if assets.roomFilm { out.append(.roomFilm) }
            if assets.roomMark { out.append(.roomMark) }
        case .ipod:
            if assets.iPodFilm { out.append(.iPodFilm) }
        case .classic:
            break
        }
        out.append(.none)
        return out
    }
}

/// An opening as a person picks it: one row per film that can actually play.
enum OpeningKind: String, CaseIterable {
    case sting, stingInLight, roomFilm, roomMark, iPodFilm, none

    var title: String {
        switch self {
        case .sting: "Record sting"
        case .stingInLight: "Record sting in the wall’s light"
        case .roomFilm: "Room film"
        case .roomMark: "Mark"
        case .iPodFilm: "iPod film"
        case .none: "None"
        }
    }

    var detail: String {
        switch self {
        case .sting: "The Tessera record film, on black."
        case .stingInLight: "The same film over the colours of what the wall is showing."
        case .roomFilm: "The mark lands on the record player’s lid, then the view pulls back to the seat."
        case .roomMark: "The mark forms in front of the wall while the record player builds up in blocks."
        case .iPodFilm: "The iPod arrives face down, its mark lights up, and it turns over."
        case .none: "Open straight to the wall."
        }
    }

    /// What picking this writes to intro.style. Both films write "film", so
    /// the choice follows the owner to another design as that design's film.
    var style: OpeningStyle {
        switch self {
        case .sting: .sting
        case .stingInLight: .stingRoom
        case .roomFilm, .iPodFilm: .film
        case .roomMark: .mark
        case .none: .none
        }
    }

    /// Played over the whole app by RootView, whatever the design.
    var isSting: Bool { self == .sting || self == .stingInLight }
}

/// Which films this build carries. The app's own is OpeningAssets.bundled
/// (StingOpening.swift), and the tests make their own.
struct OpeningAssets: Equatable {
    var sting: Bool
    var stingKeyed: Bool
    var roomFilm: Bool
    var roomMark: Bool
    var iPodFilm: Bool

    static let all = OpeningAssets(sting: true, stingKeyed: true, roomFilm: true, roomMark: true, iPodFilm: true)
}

/// Openings play at a cold launch and on Play only. WallScreen sets this once
/// it has appeared: its body, which creates the home and evaluates the home's
/// state, always runs before its onAppear, so the first home still plays its
/// film, and a home made later in the session (after a design switch) reads
/// true and skips it.
enum OpeningLaunch {
    static var settled = false
}

/// A request to play the opening again, as a counter rather than a switch.
/// The old Bool had to be put back by whichever screen played the film, and
/// when none did (Panel with a film saved) it stayed on for good.
enum OpeningReplay {
    static let key = "intro.replay.request"
}
