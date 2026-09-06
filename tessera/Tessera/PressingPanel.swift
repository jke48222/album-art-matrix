// The pressing, under the open cover.
//
// Tap the record and the room goes in close: the cover swings up, the
// record sits centred, and this panel comes up under it, laid out like the
// wall's own tuning. Three pages: every kind the record could be; its
// colours, a picture of your own and the label; and the shelf of pressings
// you have kept. Everything you touch shows on the record itself, at once.
// Keep it for the album and every song on that album gets this record.

import PhotosUI
import SwiftUI
import UIKit

extension Pressing.Kind {
    var title: String {
        switch self {
        case .marble: "Marble"
        case .smoke: "Smoke"
        case .splatter: "Splatter"
        case .galaxy: "Galaxy"
        case .half: "Half and half"
        case .starburst: "Starburst"
        case .ring: "Colour in colour"
        case .translucent: "Translucent"
        case .picture: "Picture disc"
        case .filled: "Medallions"
        case .electric: "Electric"
        case .centre: "Picture centre"
        case .glitter: "Glitter"
        case .rings: "Rings"
        case .etched: "Etched"
        case .swatches: "Swatches"
        }
    }
    /// The kinds that put a picture in the disc.
    var wantsPicture: Bool { [.picture, .filled, .centre, .glitter, .etched, .swatches].contains(self) }
}

struct PressingPanel: View {
    @Binding var choice: PressingChoice
    let albumKey: String
    let sleeve: UIImage?
    let accent: Color
    var ink: GlassInk = .dark

    @State private var store = PressingStore.shared
    @State private var page = 0
    @State private var photoItem: PhotosPickerItem? = nil
    @State private var saveName = ""
    @State private var saving = false

    private var art: UIImage? { store.photo(choice.photo) ?? sleeve }
    private var palette: [Pressing.RGB] {
        if let c = choice.colours { return c.map { Pressing.RGB(r: $0[0], g: $0[1], b: $0[2]) } }
        return Pressing.palette(of: art)
    }
    /// What the album has now, kept or not.
    private var kept: PressingChoice { store.choice(for: albumKey) ?? PressingChoice() }

    var body: some View {
        VStack(spacing: 12) {
            TabView(selection: $page) {
                kinds.tag(0)
                look.tag(1)
                shelf.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 296)
            dots
            if albumKey.isEmpty {
                // nothing on: the record is a preview, and there is no album
                // to keep it for yet
                Text("Nothing playing, so this is a preview. Play a song to keep a record for its album.")
                    .font(.ui(12)).foregroundStyle(ink.dim)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
            }
            actions
        }
        .padding(.horizontal, 16)
        .environment(\.colorScheme, ink.ink == Ink.ink ? .dark : .light)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data),
                   let name = store.keepPhoto(img) {
                    choice.photo = name
                    let kind = choice.kind.flatMap { Pressing.Kind(rawValue: $0) }
                    if kind == nil || kind?.wantsPicture == false { choice.kind = Pressing.Kind.centre.rawValue }
                }
                photoItem = nil
            }
        }
    }

    // MARK: Page one: the kind

    private var kinds: some View {
        slab("Kind") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                chip("Song's own", on: choice.kind == nil) { choice.kind = nil }
                ForEach(Pressing.Kind.allCases, id: \.rawValue) { k in
                    chip(k.title, on: choice.kind == k.rawValue) { choice.kind = k.rawValue }
                }
            }
        }
    }

    // MARK: Page two: colours, picture, label

    private var look: some View {
        VStack(spacing: 10) {
            slab("Colours") {
                ColourBar(colours: (0..<3).map { i in
                    Binding(
                        get: {
                            let cols = palette
                            let c = i < cols.count ? cols[i] : Pressing.RGB.black
                            return Color(red: Double(c.r), green: Double(c.g), blue: Double(c.b))
                        },
                        set: { new in
                            var cs = palette
                            while cs.count < 3 { cs.append(cs.last ?? .black) }
                            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                            UIColor(new).getRed(&r, green: &g, blue: &b, alpha: &a)
                            cs[i] = Pressing.RGB(r: Float(r), g: Float(g), b: Float(b))
                            choice.colours = cs.map { [$0.r, $0.g, $0.b] }
                        })
                }, stroke: ink.ink.opacity(0.14))
                if choice.colours != nil {
                    small("Sleeve's colours") { choice.colours = nil }
                }
            }
            slab("Picture in the disc") {
                HStack(spacing: 12) {
                    Group {
                        if let art { Image(uiImage: art).resizable().interpolation(.medium) }
                        else { Rectangle().fill(ink.fill) }
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Text("Choose a photo").font(.ui(13, .medium)).foregroundStyle(Ink.ground)
                            .padding(.horizontal, 14).frame(height: 36)
                            .background(Capsule().fill(accent))
                    }
                    .buttonStyle(PressStyle(scale: 0.95))
                    if choice.photo != nil {
                        small("Use the sleeve") { choice.photo = nil }
                    }
                    Spacer(minLength: 0)
                }
            }
            slab("Label") {
                HStack(spacing: 6) {
                    chip("Auto", on: choice.label == nil) { choice.label = nil }
                    ForEach([LabelStyle.paper, .neon, .coin, .holo, .mono], id: \.rawValue) { st in
                        chip(st.title, on: choice.label == st.rawValue) { choice.label = st.rawValue }
                    }
                }
            }
        }
    }

    // MARK: Page three: the shelf

    private var shelf: some View {
        slab("Your pressings") {
            VStack(alignment: .leading, spacing: 12) {
                if store.library.isEmpty {
                    Text("Shape a record and keep it here, to put on any album.")
                        .font(.ui(13)).foregroundStyle(ink.dim)
                        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(store.library) { saved in
                                Button { choice = saved.choice; Taps.detent(intensity: 0.35) } label: {
                                    VStack(spacing: 6) {
                                        ShelfRecord(choice: saved.choice, sleeve: sleeve, key: saved.id.uuidString)
                                            .frame(width: 56, height: 56)
                                        Text(saved.name).font(.ui(12, .medium))
                                            .foregroundStyle(choice == saved.choice ? Ink.ground : ink.ink).lineLimit(1)
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 10)
                                    .background {
                                        if choice == saved.choice { RoundedRectangle(cornerRadius: 18, style: .continuous).fill(accent) }
                                        else {
                                            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.ultraThinMaterial)
                                            RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(ink.ink.opacity(0.12), lineWidth: 1)
                                        }
                                    }
                                }
                                .buttonStyle(PressStyle(scale: 0.95))
                                .contextMenu { Button("Forget", role: .destructive) { store.forget(saved) } }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .frame(height: 96)
                }
                if saving {
                    HStack(spacing: 10) {
                        TextField("Name this pressing", text: $saveName)
                            .font(.ui(14)).foregroundStyle(ink.ink)
                            .padding(.horizontal, 14).frame(height: 40)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ink.fill))
                            .submitLabel(.done)
                            .onSubmit(keepOnShelf)
                        Button(action: keepOnShelf) {
                            Text("Save").font(.ui(14, .semibold)).foregroundStyle(Ink.ground)
                                .padding(.horizontal, 18).frame(height: 40)
                                .background(Capsule().fill(accent))
                        }
                        .buttonStyle(PressStyle(scale: 0.95))
                    }
                } else if !choice.isEmpty {
                    small("Keep this one on the shelf") { saving = true }
                }
            }
        }
    }

    private func keepOnShelf() {
        let name = saveName.trimmingCharacters(in: .whitespaces)
        store.keep(choice, named: name.isEmpty ? "Pressing \(store.library.count + 1)" : name)
        saveName = ""; saving = false; Taps.commit()
    }

    // MARK: Under the pages

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Capsule().fill(i == page ? accent : ink.ink.opacity(0.22))
                    .frame(width: i == page ? 16 : 6, height: 6)
            }
        }
        .animation(Motion.settle, value: page)
    }

    /// One key for the album: keep what is on the record, or hand the
    /// album back its own; and a way back to the song's own while shaping.
    private var actions: some View {
        let same = choice == kept
        // quiet when there is nothing to do: already kept, or no album on
        let quiet = same || albumKey.isEmpty
        return HStack(spacing: 10) {
            Button {
                store.set(choice, for: albumKey); Taps.commit()
            } label: {
                HStack(spacing: 8) {
                    if same {
                        Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold))
                    }
                    Text(same ? (choice.isEmpty ? "The album's own record" : "Kept for this album")
                         : (choice.isEmpty ? "Back to the album's own" : "Keep for this album"))
                        .font(.ui(15, .semibold))
                }
                .foregroundStyle(quiet ? ink.ink : Ink.ground)
                .opacity(albumKey.isEmpty && !same ? 0.55 : 1)
                .frame(maxWidth: .infinity).frame(height: 50)
                .background {
                    if quiet {
                        RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial)
                        RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(ink.ink.opacity(0.12), lineWidth: 1)
                    } else {
                        RoundedRectangle(cornerRadius: 16, style: .continuous).fill(accent)
                    }
                }
            }
            .disabled(same || albumKey.isEmpty)
            if !choice.isEmpty {
                Button { choice = PressingChoice(); Taps.detent(intensity: 0.35) } label: {
                    Text("Song's own").font(.ui(15, .semibold)).foregroundStyle(ink.ink)
                        .padding(.horizontal, 18).frame(height: 50)
                        .background {
                            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial)
                            RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(ink.ink.opacity(0.12), lineWidth: 1)
                        }
                }
            }
        }
        .buttonStyle(PressStyle(scale: 0.96))
    }

    // MARK: Pieces

    private func slab<C: View>(_ name: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(name.uppercased()).font(.machine(9)).kerning(1.2).foregroundStyle(ink.dim)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Slab(radius: 24, ink: ink))
    }

    private func chip(_ label: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button { action(); Taps.detent(intensity: 0.35) } label: {
            Text(label).font(.ui(13, .medium)).foregroundStyle(on ? Ink.ground : ink.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity).frame(height: 36)
                .background {
                    if on { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(accent) }
                    else {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.ultraThinMaterial)
                        RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ink.ink.opacity(0.12), lineWidth: 1)
                    }
                }
        }
        .buttonStyle(PressStyle(scale: 0.95))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    private func small(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button { action(); Taps.detent(intensity: 0.3) } label: {
            Text(label).font(.ui(13, .medium)).foregroundStyle(ink.ink)
                .padding(.horizontal, 14).frame(height: 36)
                .background {
                    Capsule().fill(.ultraThinMaterial)
                    Capsule().strokeBorder(ink.ink.opacity(0.12), lineWidth: 1)
                }
        }
        .buttonStyle(PressStyle(scale: 0.95))
    }
}

/// A small record for the shelf, rendered once per kept pressing.
private struct ShelfRecord: View {
    let choice: PressingChoice
    let sleeve: UIImage?
    let key: String
    @State private var image: UIImage? = nil
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().interpolation(.medium).clipShape(Circle()) }
            else { Circle().fill(Ink.dim.opacity(0.3)) }
        }
        .task(id: key) {
            let art = PressingStore.shared.photo(choice.photo) ?? sleeve
            let palette = choice.colours.map { $0.map { Pressing.RGB(r: $0[0], g: $0[1], b: $0[2]) } } ?? Pressing.palette(of: art)
            let p = Pressing.make(key: key, palette: palette, hasPicture: art != nil, forced: choice.kind)
            image = await Task.detached { RecordDesign.render(p, sleeve: art) }.value
        }
    }
}
