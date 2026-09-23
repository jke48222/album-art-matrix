import SwiftUI

/// The live surface always consumes the wall's RGB frame. Original artwork is
/// a separate, labeled view, so changing a preview never changes the display.
struct ArtworkPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var sleeve = SleeveArt()
    @State private var original = false
    @State private var rpm = 7.5
    @State private var editing = false
    let spin: Bool
    let accent: Color

    private var track: String { [wall.host, wall.state.title ?? "", wall.state.artist ?? "", wall.state.album ?? ""].joined(separator: "|") }
    private var selectedMode: String { spin ? "cd" : "art" }
    private var onWall: Bool { wall.state.mode == selectedMode }
    private var canSend: Bool { wall.link.isLive || wall.link.isStandIn }
    private var reading: FrameReading { FrameRenderer.read(wall.state.mode == "off" ? nil : wall.frame) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(spin ? "THE RECORD IN MOTION" : "GIVE THE SLEEVE THE ROOM").font(.machine(8)).tracking(1).foregroundStyle(accent.toned(forDark: true))
                        Text(spin ? "Spin" : "Album art").font(.display(typeSize.isAccessibilitySize ? 20 : 38)).foregroundStyle(Ink.ink)
                    }
                    if !spin {
                        Picker("Artwork view", selection: $original) {
                            Text("On the wall").tag(false); Text("Original cover").tag(true)
                        }.pickerStyle(.segmented)
                    }
                    artwork
                    if wall.state.replayActive { ReturnToMusicButton(accent: accent) }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(wall.state.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Waiting for a song").font(.displayMid(typeSize.isAccessibilitySize ? 18 : 27)).foregroundStyle(Ink.ink)
                        if let artist = wall.state.artist, !artist.isEmpty { Text(artist).font(.ui(17, .medium)).foregroundStyle(Ink.dim) }
                        if let album = wall.state.album, !album.isEmpty { Text(album).font(.ui(13)).foregroundStyle(Ink.dim) }
                    }
                    if let owned = wall.state.owned { ownedRow(owned) }
                    if spin { spinControls }
                    else {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("The whole cover, beautifully framed", systemImage: "viewfinder").font(.ui(15, .semibold)).foregroundStyle(Ink.ink)
                            Text("The wall uses a centred square crop. Its live pixels above include the current finish and any collection mark.")
                                .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                            LiveFinishRow(host: wall.host, mode: wall.state.mode, current: wall.state.finish, accent: accent, ink: .dark, sleeve: sleeve.image) { wall.send(["finish": $0]) }.disabled(!canSend)
                        }
                    }
                    if !onWall {
                        Button { wall.send(["mode": selectedMode]); Taps.commit() } label: {
                            Label(spin ? "Put Spin on the wall" : "Put album art on the wall", systemImage: spin ? "opticaldisc" : "photo")
                                .font(.ui(15, .semibold)).foregroundStyle(Ink.ground).frame(maxWidth: .infinity, minHeight: 54)
                                .background(accent.toned(forDark: true), in: RoundedRectangle(cornerRadius: 16))
                        }.buttonStyle(PressStyle()).disabled(!canSend)
                    }
                }.padding(24)
            }.background(Ink.ground)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.frame(minHeight: 44) } }
        }.preferredColorScheme(.dark).tint(accent.toned(forDark: true))
            .task(id: track) { sleeve.refresh(title: wall.state.title, artist: wall.state.artist, album: wall.state.album, host: wall.host) }
            .onAppear { rpm = wall.state.rpm }
            .onChange(of: wall.state.rpm) { _, value in if !editing { rpm = value } }
            .onChange(of: wall.lastSync) { _, _ in sleeve.refresh(title: wall.state.title, artist: wall.state.artist, album: wall.state.album, host: wall.host) }
    }

    private var artwork: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                Color(hex: 0x151815)
                if original, let image = sleeve.image {
                    Image(uiImage: image).resizable().interpolation(.high).scaledToFit()
                        .transition(.opacity)
                } else if !original, let pixels = reading.px, wall.state.mode != "off" {
                    PanelCanvas(px: pixels, duty: wall.state.brightness)
                } else {
                    VStack(spacing: 12) {
                        if original && sleeve.phase == .loading { ProgressView().tint(accent) }
                        else { Image(systemName: spin ? "opticaldisc" : "photo").font(.system(size: 42, weight: .ultraLight)).foregroundStyle(Ink.dim) }
                        Text(original ? sleeve.phase == .loading ? "Finding the cover" : "Cover unavailable" : wall.state.mode == "off" ? "The wall is asleep" : "Waiting for the wall")
                            .font(.ui(14)).foregroundStyle(Ink.dim)
                    }.padding(24)
                }
            }.aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.ink.opacity(0.1), lineWidth: 1))
            HStack(alignment: .firstTextBaseline) {
                Label(original ? "Original cover · centred crop" : wall.link.isLive ? "Live wall pixels" : wall.link.isStandIn ? "Preview on this phone" : "Last received frame", systemImage: original ? "photo" : wall.link.isLive ? "dot.radiowaves.left.and.right" : "wifi.slash")
                    .font(.ui(12)).foregroundStyle(Ink.dim)
                Spacer(minLength: 8)
                if !original { Text("\(Panel.side) × \(Panel.side)").font(.machine(9)).foregroundStyle(Ink.dim) }
            }
            if !original, !onWall, wall.state.mode != "off" {
                Text("Your wall is currently showing another face.").font(.ui(12)).foregroundStyle(Ink.dim)
            }
        }
    }

    private var spinControls: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Record face").font(.displayMid(22)).foregroundStyle(Ink.ink)
                HStack(spacing: 10) {
                    spinFace("Your pressing", symbol: "opticaldisc", value: "pressing")
                    spinFace("Album art", symbol: "photo", value: "art")
                }
                if wall.state.spinFace == "pressing", wall.state.pressingFor != sleeve.songKey {
                    Text("Album artwork is used until your pressing is ready. Shape a pressing by opening the record in Room.")
                        .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                WallValueSlider(value: $rpm, in: 0.5...45, step: 0.1, title: "Rotation speed", accent: accent,
                                format: { String(format: "%.1f rpm", $0) }, onEditingChanged: { active in
                    editing = active
                    if !active { wall.send(["rpm": rpm]) }
                }, onCancel: { editing = false; rpm = wall.state.rpm })
                HStack(spacing: 8) {
                    speed(7.5, label: "Slow · 7.5")
                    speed(33.333, label: "33⅓")
                    speed(45, label: "45")
                }
            }.padding(18).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 20))
            Label("The record follows the song’s position and pauses with playback when timing is available.", systemImage: "pause.circle")
                .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }.disabled(!canSend)
    }

    private func spinFace(_ name: String, symbol: String, value: String) -> some View {
        let selected = wall.state.spinFace == value
        return Button { wall.send(["spin_face": value]) } label: {
            VStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 27, weight: .light))
                Text(name).font(.ui(14, .medium))
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 14))
            }.foregroundStyle(selected ? accent.toned(forDark: true) : Ink.ink).padding(18).frame(maxWidth: .infinity)
                .background(Ink.plaster, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(selected ? accent.toned(forDark: true) : Ink.hairline, lineWidth: 1))
        }.buttonStyle(PressStyle()).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func speed(_ value: Double, label: String) -> some View {
        let selected = abs(wall.state.rpm - value) < 0.05
        return Button { rpm = value; wall.send(["rpm": value]) } label: {
            Text(label).font(.ui(13, .medium)).foregroundStyle(selected ? Ink.ground : Ink.ink)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(selected ? accent.toned(forDark: true) : Ink.sunk, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(PressStyle()).accessibilityLabel("\(label) revolutions per minute").accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func ownedRow(_ owned: WallOwned) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("On your record shelf", systemImage: "checkmark.seal").font(.ui(14, .semibold)).foregroundStyle(accent.toned(forDark: true))
            Text([owned.year.map(String.init), owned.label.isEmpty ? nil : owned.label, owned.catno.isEmpty ? nil : owned.catno].compactMap { $0 }.joined(separator: " · "))
                .font(.ui(12)).foregroundStyle(Ink.dim)
            if let url = URL(string: owned.url), url.scheme == "https" {
                Link(destination: url) { Label("View this pressing", systemImage: "arrow.up.right").font(.ui(13, .medium)).frame(minHeight: 44) }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 18))
    }
}
