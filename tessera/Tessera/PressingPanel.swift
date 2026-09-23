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
    let songKey: String
    let title: String
    let artist: String
    let sleeve: UIImage?
    let accent: Color
    var ink: GlassInk = .dark
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var store = PressingStore.shared
    @State private var page = 0
    @State private var photoItem: PhotosPickerItem?
    @State private var saveName = ""
    @State private var saving = false
    @State private var photoError: String?
    private var art: UIImage? { store.photo(choice.photo) ?? sleeve }
    private var palette: [Pressing.RGB] { choice.safeColours ?? Pressing.palette(of: art) }
    private var kept: PressingChoice { store.choice(for: albumKey) ?? PressingChoice() }
    private var labels: [LabelStyle] { [.paper, .neon, .coin, .holo, .mono] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Make it yours").font(.displayMid(typeSize.isAccessibilitySize ? 18 : 26)).foregroundStyle(ink.ink)
                Spacer(minLength: 8)
                if !choice.isEmpty {
                    Button("Reset") { choice = PressingChoice() }.font(.ui(13, .medium))
                        .foregroundStyle(ink.ink).frame(minHeight: 44).accessibilityLabel("Reset to the album’s automatic pressing")
                }
            }
            Picker("Pressing controls", selection: $page) {
                Text("Vinyl").tag(0); Text("Label").tag(1); Text("Saved").tag(2)
            }.pickerStyle(.segmented)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if page == 0 { kinds }
                    else if page == 1 { appearance }
                    else { shelf }
                    if let problem = photoError ?? store.saveError {
                        Label(problem, systemImage: "exclamationmark.circle").font(.ui(13)).foregroundStyle(Ink.signal)
                    }
                }.padding(.vertical, 4)
            }
            .scrollIndicators(.hidden).clipped().frame(height: typeSize.isAccessibilitySize ? 310 : 264)
            if albumKey.isEmpty {
                Text("Previewing a record. Play an album to keep this pressing for it.")
                    .font(.ui(12)).foregroundStyle(ink.dim).fixedSize(horizontal: false, vertical: true)
            }
            Button {
                if store.set(choice, for: albumKey) { Taps.commit() }
            } label: {
                Label(choice == kept ? "Kept for this album" : "Keep for this album", systemImage: choice == kept ? "checkmark.circle" : "bookmark")
                    .font(.ui(15, .semibold)).foregroundStyle(choice == kept ? ink.ink : Ink.ground)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(choice == kept ? ink.fill : accent.toned(forDark: true), in: RoundedRectangle(cornerRadius: 16))
            }.buttonStyle(PressStyle()).disabled(choice == kept || albumKey.isEmpty)
        }
        .padding(18).background(Slab(radius: 26, ink: ink)).padding(.horizontal, 16)
        .environment(\.colorScheme, ink.ink == Ink.ink ? .dark : .light)
        .task(id: photoItem) {
            guard let item = photoItem else { return }
            photoError = nil
            do {
                guard let data = try await item.loadTransferable(type: Data.self), !Task.isCancelled,
                      let image = UIImage(data: data) else {
                    if !Task.isCancelled { photoError = "This photo couldn’t be opened." }; return
                }
                guard let name = store.keepPhoto(image), !Task.isCancelled else { return }
                choice.photo = name
                if choice.kind.flatMap({ Pressing.Kind(rawValue: $0) })?.wantsPicture != true { choice.kind = Pressing.Kind.centre.rawValue }
                photoItem = nil
            } catch { if !Task.isCancelled { photoError = "This photo couldn’t be opened. Try another image." } }
        }
        .onAppear {
            #if DEBUG
            if CommandLine.arguments.contains("-pressing-labels") { page = 1 }
            if CommandLine.arguments.contains("-pressing-saved") { page = 2 }
            #endif
        }
    }

    private var kinds: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: typeSize.isAccessibilitySize ? 1 : 3), spacing: 10) {
            kindOption(nil, title: "Automatic")
            ForEach(Pressing.Kind.allCases, id: \.rawValue) { kind in kindOption(kind, title: kind.title) }
        }
    }

    private func kindOption(_ kind: Pressing.Kind?, title: String) -> some View {
        var candidate = choice
        candidate.kind = kind?.rawValue
        let selected = choice.kind == kind?.rawValue
        return Button { choice.kind = kind?.rawValue; Taps.detent() } label: {
            VStack(spacing: 8) {
                ShelfRecord(choice: candidate, sleeve: sleeve, key: candidate.isEmpty ? songKey : albumKey, title: self.title, artist: artist)
                    .frame(width: 62, height: 62)
                Text(title).font(.ui(12, .medium)).foregroundStyle(ink.ink).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 30)
            }.padding(10).frame(maxWidth: .infinity)
                .background(selected ? accent.opacity(0.16) : ink.fill, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(selected ? accent : ink.ink.opacity(0.08), lineWidth: selected ? 1.5 : 0.5))
                .overlay(alignment: .topTrailing) {
                    if selected { Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(accent).padding(7) }
                }
        }.buttonStyle(PressStyle(scale: 0.97)).accessibilityLabel("\(title) vinyl")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("A label for your record").font(.ui(15, .semibold)).foregroundStyle(ink.ink)
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    labelOption(nil, title: "Auto")
                    ForEach(labels, id: \.rawValue) { labelOption($0, title: $0.title) }
                }
            }.scrollIndicators(.hidden)
            ColourBar(colours: (0..<3).map { index in
                Binding(get: {
                    let colour = palette.isEmpty ? .black : palette[min(index, palette.count - 1)]
                    return Color(red: Double(colour.r), green: Double(colour.g), blue: Double(colour.b))
                }, set: { value in
                    var colours = palette
                    while colours.count < 3 { colours.append(colours.last ?? .black) }
                    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                    guard UIColor(value).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
                    colours[index] = Pressing.RGB(r: Float(red), g: Float(green), b: Float(blue))
                    choice.colours = colours.map { [$0.r, $0.g, $0.b] }
                })
            }, stroke: ink.ink.opacity(0.14), names: ["Primary", "Secondary", "Accent"])
            HStack {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Choose photo", systemImage: "photo.badge.plus").font(.ui(14, .medium)).frame(minHeight: 44)
                }
                Spacer()
                if choice.photo != nil || choice.colours != nil {
                    Button("Use sleeve") { choice.photo = nil; choice.colours = nil }
                        .font(.ui(14, .medium)).frame(minHeight: 44)
                }
            }.foregroundStyle(ink.ink)
        }
    }

    private func labelOption(_ style: LabelStyle?, title: String) -> some View {
        let selected = choice.label == style?.rawValue
        return Button { choice.label = style?.rawValue; Taps.detent() } label: {
            VStack(spacing: 8) {
                LabelPreview(style: style, art: art, palette: palette, key: "\(albumKey)|\(String(describing: choice.colours))|\(choice.photo ?? "")|\(art != nil)", title: self.title, artist: artist)
                    .frame(width: 72, height: 72).overlay(Circle().strokeBorder(selected ? accent : .clear, lineWidth: 2))
                Text(title).font(.ui(12, .medium)).foregroundStyle(ink.ink)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? accent : ink.dim).font(.system(size: 13))
            }.padding(4)
        }.buttonStyle(PressStyle()).accessibilityLabel("\(title) record label").accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var shelf: some View {
        VStack(alignment: .leading, spacing: 14) {
            if store.library.isEmpty {
                Label("Your own small pressing plant.", systemImage: "opticaldisc").font(.displayMid(21)).foregroundStyle(ink.ink)
                Text("Save a vinyl style, its colours and label. Use it on another album whenever you like.").font(.ui(14)).foregroundStyle(ink.dim)
            } else {
                ForEach(store.library) { saved in
                    HStack(spacing: 12) {
                        Button { choice = saved.choice; Taps.detent() } label: {
                            HStack(spacing: 12) {
                                ShelfRecord(choice: saved.choice, sleeve: sleeve, key: saved.choice.isEmpty ? songKey : albumKey, title: title, artist: artist).frame(width: 56, height: 56)
                                Text(saved.name).font(.ui(15, .medium)).foregroundStyle(ink.ink).frame(maxWidth: .infinity, alignment: .leading)
                                if choice == saved.choice { Image(systemName: "checkmark").foregroundStyle(accent) }
                            }.frame(minHeight: 64)
                        }.buttonStyle(PressStyle()).accessibilityLabel("Use \(saved.name)")
                        Button(role: .destructive) { store.forget(saved) } label: {
                            Image(systemName: "trash").frame(width: 44, height: 44)
                        }.accessibilityLabel("Delete saved pressing \(saved.name)")
                    }
                }
            }
            if saving {
                TextField("Name this pressing", text: $saveName).font(.ui(15)).padding(12)
                    .background(ink.fill, in: RoundedRectangle(cornerRadius: 12)).submitLabel(.done).onSubmit(keep)
                Button("Save pressing", action: keep).font(.ui(15, .semibold)).frame(minHeight: 44)
            } else {
                Button { saving = true } label: { Label("Save this pressing", systemImage: "plus").font(.ui(15, .semibold)).frame(minHeight: 44) }
            }
        }.foregroundStyle(ink.ink)
    }

    private func keep() {
        let name = saveName.trimmingCharacters(in: .whitespacesAndNewlines)
        if store.keep(choice, named: name.isEmpty ? "Pressing \(store.library.count + 1)" : name) {
            saving = false; saveName = ""; Taps.commit()
        }
    }
}

private struct LabelPreview: View {
    let style: LabelStyle?
    let art: UIImage?
    let palette: [Pressing.RGB]
    let key: String
    let title: String
    let artist: String
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Circle().fill(Ink.plaster) }
        }.clipShape(Circle()).accessibilityHidden(true)
            .task(id: "\(key)|\(style?.rawValue ?? -1)") {
                let result = await Task.detached(priority: .utility) {
                    RecordLabel.styled(sleeve: art, title: title, artist: artist, palette: palette, key: key, forcedStyle: style)
                }.value
                guard !Task.isCancelled else { return }; image = result
            }
    }
}

private struct ShelfRecord: View {
    let choice: PressingChoice
    let sleeve: UIImage?
    let key: String
    let title: String
    let artist: String
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().interpolation(.high).scaledToFit() }
            else { Circle().fill(Ink.plaster).overlay(Circle().strokeBorder(Ink.dim.opacity(0.3), lineWidth: 1)) }
        }.clipShape(Circle()).accessibilityHidden(true)
            .task(id: "\(key)|\(title)|\(artist)|\(sleeve != nil)|\(String(describing: choice))") {
                let art = PressingStore.shared.photo(choice.photo) ?? sleeve
                let palette = choice.safeColours ?? Pressing.palette(of: art)
                let pressing = Pressing.make(key: key, palette: palette, hasPicture: true, title: title, artist: artist, forced: choice.kind)
                let result = await Task.detached(priority: .utility) {
                    let label = RecordLabel.styled(sleeve: art, title: title, artist: artist, palette: palette,
                                                   key: "\(key)|\(String(describing: choice))|\(art != nil)",
                                                   forcedStyle: choice.label.flatMap(LabelStyle.init(rawValue:)))
                    return RecordDesign.render(pressing, sleeve: art, printed: label, size: 160)
                }.value
                guard !Task.isCancelled else { return }; image = result
            }
    }
}
