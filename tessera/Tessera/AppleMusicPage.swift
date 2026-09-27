import SwiftUI
import MediaPlayer
import UIKit

@MainActor
@Observable
private final class AppleMusicConnection {
    private(set) var permission: AppleMusicPermission = .notAsked
    private(set) var track: AppleMusicTrack?
    private(set) var artwork: UIImage?
    private(set) var checking = true
    private(set) var requesting = false
    private(set) var lastRead: Date?
    let preview: String?

    init() {
        #if DEBUG
        let supplied = ProcessInfo.processInfo.environment["TESSERA_QA_APPLE_MUSIC"]
        preview = ["notAsked", "denied", "restricted", "authorized", "playing", "paused", "offline"].contains(supplied ?? "") ? supplied : nil
        #else
        preview = nil
        #endif
    }
    func refresh() {
        defer { checking = false; lastRead = Date() }
        if let preview {
            permission = AppleMusicPermission(rawValue: preview) ?? .authorized
            if ["playing", "paused", "offline"].contains(preview) {
                track = AppleMusicTrack(identity: "preview-prism", title: "Prism Studies", artist: "Tessera Studio", album: "After the light", storeID: "", playback: preview == "paused" ? .paused : .playing)
            } else { track = nil }
            return
        }
        switch MPMediaLibrary.authorizationStatus() {
        case .notDetermined: permission = .notAsked
        case .denied: permission = .denied
        case .restricted: permission = .restricted
        case .authorized: permission = .authorized
        @unknown default: permission = .unknown
        }
        guard permission.isAuthorized else { track = nil; artwork = nil; return }
        let player = MPMusicPlayerController.systemMusicPlayer
        guard let item = player.nowPlayingItem else { track = nil; artwork = nil; return }
        let playback: AppleMusicPlayback
        switch player.playbackState {
        case .playing: playback = .playing
        case .paused: playback = .paused
        case .interrupted: playback = .interrupted
        case .seekingForward, .seekingBackward: playback = .seeking
        default: playback = .stopped
        }
        let identity = "\(item.persistentID)|\(item.playbackStoreID)|\(item.title ?? "")|\(item.artist ?? "")|\(item.albumTitle ?? "")"
        if identity != track?.identity || artwork == nil {
            artwork = item.artwork?.image(at: CGSize(width: 640, height: 640))
        }
        track = AppleMusicTrack(identity: identity, title: item.title ?? "", artist: item.artist ?? "",
                                album: item.albumTitle ?? "", storeID: item.playbackStoreID, playback: playback)
    }
    func requestAccess() async {
        guard preview == nil, !requesting, permission == .notAsked else { return }
        requesting = true
        await withCheckedContinuation { continuation in
            StandIn.requestMusicAccess { continuation.resume() }
        }
        requesting = false
        refresh()
    }
}

struct AppleMusicPage: View {
    let accent: Color
    @Binding var musicConnected: Bool
    @Binding var musicRefused: Bool
    @Environment(WallSession.self) private var wall
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @State private var connection = AppleMusicConnection()
    @State private var openError: String?
    @State private var retrying = false
    private let rose = Color(hex: 0xFF8B98)
    private let mint = Color(hex: 0xB8D6BA)
    private var authorized: Bool { connection.permission.isAuthorized }
    private var live: Bool { connection.preview == "offline" ? false : wall.link.isLive }
    private var confirmed: Bool {
        guard let track = connection.track else { return false }
        return connection.preview != nil ? connection.preview != "offline" : wall.push.lastWallReceipt?.confirms(track, host: wall.host, at: connection.lastRead ?? Date()) == true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: typeSize.isAccessibilitySize ? 22 : 28) {
                if let preview = connection.preview {
                    Label("Preview · \(preview)", systemImage: "eye").font(.ui(12, .semibold)).foregroundStyle(Ink.dim)
                }
                if !typeSize.isAccessibilitySize || !authorized { masthead }
                if connection.checking {
                    HStack(spacing: 12) { ProgressView().tint(rose); Text("Checking music access").font(.ui(16)).foregroundStyle(Ink.dim) }
                        .frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
                } else if authorized {
                    if let track = connection.track { nowPlaying(track) }
                    else { emptyPlayback }
                    connectionStatus
                } else { permissionCard }
                if let openError {
                    Label(openError, systemImage: "exclamationmark.circle").font(.ui(14)).foregroundStyle(rose)
                        .fixedSize(horizontal: false, vertical: true).accessibilityLabel(openError)
                }
                accessDetails
            }.padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 36)
        }
        .scrollIndicators(.hidden)
        .background(Color(hex: 0x111315).ignoresSafeArea())
        .navigationTitle("Apple Music").navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
        .onChange(of: wall.host) { _, _ in
            guard connection.preview == nil else { return }
            wall.push.wallHost = wall.host; wall.push.restart()
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: authorized)
    }
    private var masthead: some View {
        VStack(alignment: .leading, spacing: 17) {
            if typeSize.isAccessibilitySize {
                Text(compactPermissionDetail).font(.ui(15)).foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
            HStack(spacing: 12) {
                ServiceMark(service: .appleMusic, side: 38)
                Text("APPLE MUSIC").font(.machine(11)).tracking(2).foregroundStyle(rose)
                Spacer(minLength: 0)
                if authorized { Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(mint).accessibilityLabel("Music access allowed") }
            }
            Text(connection.checking ? "Music, in the room." : connection.permission.title).font(typeSize.isAccessibilitySize ? .ui(26, .semibold) : .display(37))
                .foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
            if !authorized {
                Text(connection.permission.detail).font(.ui(16)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
            }
        }
    }
    private var compactPermissionDetail: String {
        switch connection.permission {
        case .notAsked: "Read the song playing on this iPhone."
        case .denied: "Allow Tessera’s music access in Settings."
        case .restricted: "A device or family restriction limits music access."
        case .unknown: "Music permission couldn’t be read."
        case .authorized: "Music access is allowed."
        }
    }
    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !typeSize.isAccessibilitySize { connectionIllustration.padding(.vertical, 10) }
            Label(permissionLabel, systemImage: permissionSymbol).font(.ui(typeSize.isAccessibilitySize ? 16 : 17, .semibold)).foregroundStyle(Ink.ink)
                .fixedSize(horizontal: false, vertical: true)
            if connection.permission == .notAsked {
                if !typeSize.isAccessibilitySize {
                    Text("Song title, artist and artwork. Your Apple Account password stays with Apple.")
                        .font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    Task {
                        await connection.requestAccess()
                        updateBindings()
                        if connection.permission.isAuthorized && connection.preview == nil { wall.push.restart() }
                    }
                } label: {
                    HStack(spacing: 10) {
                        if connection.requesting { ProgressView().tint(Ink.ground) }
                        Text(connection.requesting ? "Waiting for your choice" : "Allow music access").fixedSize(horizontal: false, vertical: true)
                    }.font(.ui(16, .semibold)).frame(maxWidth: .infinity, minHeight: 52).padding(.vertical, 6)
                }.buttonStyle(PressStyle()).foregroundStyle(Ink.ground).background(rose, in: RoundedRectangle(cornerRadius: 15))
                    .disabled(connection.requesting || connection.preview != nil)
                    .accessibilityHint("Opens the iPhone permission request for your media library")
            } else {
                Button(action: openSettings) {
                    Label("Open Settings", systemImage: "arrow.up.right").font(.ui(16, .semibold))
                        .frame(maxWidth: .infinity, minHeight: 52).padding(.vertical, 6)
                }.buttonStyle(PressStyle()).foregroundStyle(Ink.ground).background(rose, in: RoundedRectangle(cornerRadius: 15))
                    .disabled(connection.preview != nil)
                if connection.permission == .restricted {
                    Text("Tessera can’t lift a device restriction or request this permission again here.")
                        .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                }
            }
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(hex: 0x201B1F), in: RoundedRectangle(cornerRadius: 24))
    }
    private var permissionLabel: String {
        if typeSize.isAccessibilitySize {
            return switch connection.permission {
            case .notAsked: "Music access"
            case .denied: "Access off"
            case .restricted: "Restricted"
            case .unknown: "Unavailable"
            case .authorized: "Access allowed"
            }
        }
        return switch connection.permission {
        case .notAsked: "Only when you say so."
        case .denied: "Permission not granted"
        case .restricted: "Managed by this iPhone"
        case .unknown: "Permission could not be read"
        case .authorized: "Music access allowed"
        }
    }
    private var permissionSymbol: String {
        switch connection.permission {
        case .notAsked: "hand.raised"
        case .restricted: "lock"
        case .denied, .unknown: "exclamationmark.circle"
        case .authorized: "checkmark.circle"
        }
    }
    private var connectionIllustration: some View {
        HStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 19).strokeBorder(rose.opacity(0.65), lineWidth: 1.5)
                VStack(spacing: 12) {
                    Capsule().fill(rose.opacity(0.55)).frame(width: 24, height: 4)
                    ServiceMark(service: .appleMusic, side: 40)
                    Capsule().fill(rose.opacity(0.35)).frame(width: 30, height: 3)
                }
            }.frame(width: 76, height: 120)
            HStack(spacing: 7) { ForEach(0..<3) { _ in Circle().fill(rose.opacity(0.5)).frame(width: 4, height: 4) } }
            VStack(spacing: 5) {
                ForEach(0..<6) { y in
                    HStack(spacing: 5) { ForEach(0..<6) { x in Circle().fill(rose.opacity((x + y) % 3 == 0 ? 0.95 : 0.25)).frame(width: 7, height: 7) } }
                }
            }.padding(13).background(Color(hex: 0x151519), in: RoundedRectangle(cornerRadius: 14))
        }.frame(maxWidth: .infinity).accessibilityElement(children: .ignore)
            .accessibilityLabel("Song details travel from this iPhone to the wall")
    }
    private func nowPlaying(_ track: AppleMusicTrack) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Image(systemName: track.playback.symbol)
                Text(track.playback.label)
            }.font(.ui(13, .semibold)).foregroundStyle(track.playback == .playing ? mint : Ink.dim)
            (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 18)) : AnyLayout(HStackLayout(alignment: .center, spacing: 20))) {
                artwork.frame(width: typeSize.isAccessibilitySize ? 112 : 126, height: typeSize.isAccessibilitySize ? 112 : 126)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.22), radius: 16, y: 8).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(track.displayTitle).font(.ui(22, .semibold)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                    Text(track.displayArtist).font(.ui(16)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                    if !track.album.isEmpty { Text(track.album).font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let url = track.catalogueURL {
                Button { open(url) } label: {
                    Image("ListenOnAppleMusic").resizable().scaledToFit().frame(width: 175, height: 50)
                        .padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).accessibilityLabel("Listen to \(track.displayTitle) on Apple Music")
                    .accessibilityHint("Opens the song in Music or on the Apple Music website")
            } else {
                Button { open(AppleMusicDestination.home) } label: {
                    Label("Open Music", systemImage: "arrow.up.right").font(.ui(15, .semibold)).foregroundStyle(rose).frame(minHeight: 44)
                }.buttonStyle(.plain)
            }
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(hex: 0x1C2022), in: RoundedRectangle(cornerRadius: 24))
    }
    @ViewBuilder private var artwork: some View {
        if let image = connection.artwork { Image(uiImage: image).resizable().scaledToFill() }
        else if connection.preview != nil {
            ZStack {
                Color(hex: 0x143138)
                ForEach(0..<5) { index in
                    RoundedRectangle(cornerRadius: 5).fill([Color(hex: 0xF2D2A4), rose, Color(hex: 0xBF5A40), Color(hex: 0x5D8D89), Color(hex: 0xE5A45D)][index])
                        .frame(width: 18, height: CGFloat(65 + index * 13)).rotationEffect(.degrees(30)).offset(x: CGFloat(index * 20 - 40), y: 10)
                }
            }
        } else {
            ZStack { Color(hex: 0x2D262B); Image(systemName: "music.note").font(.system(size: 40, weight: .regular)).foregroundStyle(rose.opacity(0.75)) }
        }
    }
    private var emptyPlayback: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 13) {
                Image(systemName: "music.note").font(.system(size: 27)).foregroundStyle(rose)
                Text("Ready for your next song.").font(.ui(21, .semibold)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
            }
            Text("Start a song in Music on this iPhone. Its title and artwork will appear here when the system player makes them available.")
                .font(.ui(15)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            Button { open(AppleMusicDestination.home) } label: {
                Label("Open Music", systemImage: "arrow.up.right").font(.ui(16, .semibold)).foregroundStyle(rose).frame(minHeight: 44)
            }.buttonStyle(.plain)
        }.padding(22).background(Color(hex: 0x1C2022), in: RoundedRectangle(cornerRadius: 24))
    }
    private var connectionStatus: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Music access allowed", systemImage: "checkmark.circle.fill").font(.ui(15, .semibold)).foregroundStyle(mint)
            Divider().overlay(Ink.hairline)
            VStack(alignment: .leading, spacing: 8) {
                Label(wallStatusTitle, systemImage: wallStatusSymbol).font(.ui(16, .semibold)).foregroundStyle(confirmed && live ? mint : Ink.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(wallStatusDetail).font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
            if live && connection.track?.title.isEmpty == false && !confirmed {
                Button {
                    guard connection.preview == nil, !retrying else { return }
                    retrying = true
                    wall.push.restart()
                    Task { try? await Task.sleep(for: .seconds(1)); retrying = false }
                } label: {
                    Label(retrying ? "Refreshing connection" : "Try sending again", systemImage: "arrow.clockwise")
                        .font(.ui(15, .semibold)).foregroundStyle(rose).frame(minHeight: 44).fixedSize(horizontal: false, vertical: true)
                }.buttonStyle(.plain).disabled(retrying || connection.preview != nil)
            }
        }.padding(.horizontal, 3)
    }
    private var wallStatusTitle: String {
        if !live { return "Wall is offline" }
        if connection.track == nil { return "Wall is reachable" }
        if connection.track?.title.isEmpty == true { return "Song title unavailable" }
        if confirmed { return "Wall received this song" }
        return wall.push.lastWallError == nil ? "Waiting for the wall" : "Music update not delivered"
    }
    private var wallStatusSymbol: String { !live ? "wifi.slash" : confirmed ? "checkmark.circle" : "arrow.triangle.2.circlepath" }
    private var wallStatusDetail: String {
        if !live { return "Music access still works on this iPhone. Sharing resumes when your wall is reachable." }
        if connection.track == nil { return "Play a song to send its details. No song is being reported by this iPhone right now." }
        if connection.track?.title.isEmpty == true { return "Music hasn’t provided a title for this item. Tessera will share it when the details arrive." }
        if confirmed { return "Your wall has acknowledged this song and its playback state, directly from this iPhone." }
        if let error = wall.push.lastWallError { return error }
        return "Tessera is waiting for an acknowledgement of this song. Keep the app open while it reconnects."
    }
    private var accessDetails: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("A direct connection.").font(.ui(17, .semibold)).foregroundStyle(Ink.ink)
            Text("This permission reads the Music player on this iPhone. It doesn’t connect an Apple Account on the wall or show what’s playing on another device.")
                .font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            if authorized {
                Text("Keep Tessera open for updates. Background reporting, if enabled in your existing settings, depends on iOS.")
                    .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                Button(action: openSettings) {
                    Label("Manage music permission", systemImage: "arrow.up.right").font(.ui(14, .semibold)).foregroundStyle(rose).frame(minHeight: 44)
                }.buttonStyle(.plain).disabled(connection.preview != nil)
            }
        }.padding(.top, 5)
    }
    private func refresh() {
        let previous = connection.permission
        connection.refresh()
        updateBindings()
        if connection.preview == nil && previous != connection.permission {
            if connection.permission.isAuthorized { wall.push.restart() }
            else { wall.push.stop() }
        }
    }
    private func updateBindings() {
        guard connection.preview == nil else { return }
        musicConnected = connection.permission.isAuthorized
        musicRefused = connection.permission.isRefused
    }
    private func openSettings() {
        guard connection.preview == nil, let url = URL(string: UIApplication.openSettingsURLString) else { return }
        open(url)
    }
    private func open(_ url: URL) {
        openError = nil
        openURL(url) { accepted in
            if !accepted { openError = "This link couldn’t be opened. Try again, or open Music or Settings from your Home Screen." }
        }
    }
}
