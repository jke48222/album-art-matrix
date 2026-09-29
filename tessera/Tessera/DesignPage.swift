// App design: which home this phone shows, Room, Panel or iPod.
//
// Choosing is looking, then acting: a tap previews a design, and only Use
// writes it, the same pick-then-act as Panel check. Each preview is a small
// composition of that home drawn with the wall's current frame, captioned
// with where the frame came from, so it never claims to be a screenshot or
// a colour-accurate panel. Nothing here is sent to the wall.

import SwiftUI
import UIKit

struct DesignPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.dynamicTypeSize) private var type
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.scenePhase) private var scene
    /// The room's steady accent from Settings: what the Room preview's light
    /// is tinted with, as the Room home tints its own.
    let accent: Color
    @AppStorage("design") private var current = Design.room.rawValue
    @AppStorage(OpeningStyle.key) private var introStyle = OpeningStyle.sting.rawValue
    @State private var picked: Design?
    @State private var notice: String?
    /// The frame, rendered once as emitters and shared by all three previews,
    /// with its reading and light taken at the same moment, so the Room
    /// gradient under the Room and iPod previews holds with the tile. Only
    /// refreshTile reads the session's frame: read in body, every frame the
    /// wall sent redrew the page and both gradients at full rate.
    @State private var tile: UIImage?
    @State private var tileFrame: Data?
    @State private var tileDuty: Double = -1
    @State private var tileOff = false
    /// True while a raster is being made off the main thread. One at a time:
    /// a frame that arrives meanwhile is taken on the next pass.
    @State private var rendering = false
    @State private var reading = FrameReading.dark
    @State private var lit: Double = 0
    @State private var source = Source.none
    @State private var art = DesignArt.cached
    #if DEBUG
    @State private var hooked = false
    #endif

    private let linen = Color(hex: 0xD7CCB6)
    /// The page's ground, which the navigation bar takes too.
    private let ground = Color(hex: 0x151413)
    private var ax: Bool { type.isAccessibilitySize }
    private var inUse: Design { Design(rawValue: current) ?? .room }
    private var choice: Design { picked ?? inUse }
    private var reduced: Bool { reducedMotion || Motion.forcedReduced }
    private var off: Bool { wall.state.mode == "off" }

    /// Where the previews' frame came from, most telling first. The caption
    /// is one sentence under the whole row, so it never reads as a label of
    /// one preview, and "preview" is kept for the picked design's state.
    private enum Source: Equatable {
        case none, phone, last, off, live
        var caption: String {
            switch self {
            case .none: "No frame from the wall yet"
            case .phone: "Drawn with this phone’s own picture"
            case .last: "Drawn with the last frame"
            case .off: "The wall is off"
            case .live: "Drawn with the live frame"
            }
        }
        var spoken: String {
            switch self {
            case .none: "no frame yet"
            case .phone: "drawn with the phone preview"
            case .last: "drawn with the last frame"
            case .off: "drawn with the wall off"
            case .live: "drawn with the live frame"
            }
        }
    }
    private func currentSource(_ frame: Data?) -> Source {
        if frame == nil { return .none }
        if wall.link.isStandIn { return .phone }
        if !wall.link.isLive { return .last }
        if off { return .off }
        return .live
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    masthead
                    if ax {
                        choiceRows
                        axPreview
                    } else {
                        chooser
                        pickedBlock
                    }
                }
                .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            // Use's confirmation takes the button's place, but on a short
            // phone or at a large size that can still be under the fold.
            .onChange(of: notice) { _, text in
                guard text != nil else { return }
                withAnimation(reduced ? nil : Motion.settle) { proxy.scrollTo("design.notice", anchor: .bottom) }
            }
            #if DEBUG
            .onAppear { debugHooks(proxy) }
            #endif
        }
        .background(ground)
        .foregroundStyle(Ink.ink)
        .tint(linen)
        .navigationTitle("App design").navigationBarTitleDisplayMode(.inline)
        // A solid bar in the page's own ground, as on About: Settings hides
        // the bar for its whole stack, and what scrolls under the title
        // would otherwise stay sharp behind it.
        .toolbarBackground(ground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        // The room renders load on their own, so the frame fills the
        // previews at once rather than after the art has decoded.
        .task {
            await DesignArt.load()
            art = DesignArt.cached
        }
        .task(id: scene) {
            guard scene == .active else { return }
            // At most twice a second: three previews of a 0.5 to 0.9 pt LED
            // gain nothing from following the wall faster, while the home
            // under the sheet is drawing too. Under Reduce Motion the loop
            // still runs, so the caption stays true, but the picture holds
            // (see refreshTile).
            while !Task.isCancelled {
                refreshTile()
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
        .onAppear { refreshTile() }
    }

    #if DEBUG
    private func debugHooks(_ proxy: ScrollViewProxy) {
        guard !hooked else { return }
        hooked = true
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "-design-pick"), args.indices.contains(i + 1),
           let design = Design(rawValue: args[i + 1]) {
            picked = design
            // At accessibility sizes the picked row and its Use button are
            // under the fold, so the capture scrolls them into view. At the
            // default sizes the picked block is already on the first screen.
            if ax {
                Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    withAnimation(reduced ? nil : Motion.settle) { proxy.scrollTo("design.row.\(design.rawValue)", anchor: .top) }
                }
            }
        }
        // The notice Use would show, for the design already in use, so
        // the committed state can be captured without writing past the
        // launch argument domain.
        if args.contains("-design-notice") { notice = committedNotice(inUse) }
    }
    #endif

    // MARK: - Masthead

    /// The navigation title already names the page, so there is no kicker,
    /// and the headline says something the title does not. At accessibility
    /// sizes the page starts with the prose line.
    private var masthead: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !ax {
                // Measured in Technor Bold with the tracking: the longer line,
                // "the app looks.", is 314 pt at xxxLarge, under the 327 pt a
                // 375 pt phone leaves, so the forced break never strands a
                // word (the headline is hidden at accessibility sizes).
                Text("Choose how\nthe app looks.").font(.display(34)).tracking(-1)
                    .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            }
            // The stand-in has no wall to show, only the phone's own picture.
            Text(wall.link.isStandIn
                 ? "All three show the same picture. The choice applies to this phone only."
                 : "All three show the same wall. The choice applies to this phone only.")
                .font(.ui(ax ? 12 : 15)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - The chooser

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(Design.displayOrder, id: \.self) { design in option(design) }
            }
            caption
        }
    }

    private func option(_ design: Design) -> some View {
        let chosen = design == choice, using = design == inUse
        return Button { pick(design) } label: {
            VStack(spacing: 8) {
                thumb(design)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.hairline, lineWidth: 1) }
                    .padding(3)
                    .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(chosen ? linen : .clear, lineWidth: 2) }
                // The design in use carries a checkmark, so which is in use
                // never rests on the ring's colour alone.
                HStack(spacing: 4) {
                    if using { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)) }
                    Text(design.name).font(.ui(13, chosen ? .semibold : .medium)).lineLimit(1).minimumScaleFactor(0.8)
                }
                .foregroundStyle(chosen ? Ink.ink : Ink.dim)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.97))
        // The thumbnails and the caption are hidden, so the button says what
        // they show: which design, whether it is in use, whether it is picked.
        .accessibilityLabel(design.name)
        .accessibilityValue(using ? "In use" : chosen ? "Preview" : "")
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(using ? "" : "Shows a preview. Use it with the button below.")
        .accessibilityIdentifier("design.option.\(design.rawValue)")
    }

    /// Where the previews' frame came from: one centred line under the whole
    /// row. Hidden from VoiceOver, which hears it as design.state's value.
    private var caption: some View {
        Text(source.caption).font(.ui(12)).foregroundStyle(Ink.dim)
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityHidden(true)
            .accessibilityIdentifier("design.previewCaption")
    }

    /// At accessibility sizes the previews give way to plain choices. The
    /// radio marks the design in use, as the checkmark does under the
    /// previews, and the picked one says Preview. The Use button and its
    /// confirmation sit directly under the picked row, not after all three.
    private var choiceRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(Design.displayOrder.enumerated()), id: \.element) { index, design in
                if index > 0 { Rule(inset: 50) }
                choiceRow(design).id("design.row.\(design.rawValue)")
                if design == choice { pickedActions }
            }
        }
        .background(linen.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
    }

    private func choiceRow(_ design: Design) -> some View {
        let chosen = design == choice, using = design == inUse
        return Button { pick(design) } label: {
            // The radio is text, so it sits on the title's first baseline
            // rather than in the middle of a six-line block.
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(Image(systemName: using ? "checkmark.circle.fill" : "circle"))
                    .font(.ui(16)).foregroundStyle(using ? linen : Ink.faint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(design.name).font(.ui(16)).foregroundStyle(Ink.ink)
                    if using || chosen {
                        Text(using ? "In use" : "Preview").font(.ui(12, .semibold)).foregroundStyle(linen)
                    }
                    Text(design.summary).font(.ui(12)).foregroundStyle(Ink.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.99))
        // The label replaces the row's text, so the summary goes in the hint,
        // and the picked row carries where the preview's frame came from, as
        // design.state does at the default sizes.
        .accessibilityLabel(design.name)
        .accessibilityValue(rowValue(design))
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(using ? design.summary : "\(design.summary) Shows a preview. Use it with the button below.")
        .accessibilityIdentifier("design.option.\(design.rawValue)")
    }

    private func rowValue(_ design: Design) -> String {
        let state = design == inUse ? "In use" : design == choice ? "Preview" : ""
        guard design == choice else { return state }
        return "\(state), \(source.spoken)"
    }

    /// Under the picked row: Use, when it can do something, and the notice
    /// once it has.
    @ViewBuilder private var pickedActions: some View {
        if choice != inUse || notice != nil {
            VStack(alignment: .leading, spacing: 12) {
                if choice != inUse { useButton }
                noticeView
            }
            .padding(.horizontal, 16).padding(.bottom, 16)
        }
    }

    /// The picked design's preview at accessibility sizes, after the choices.
    private var axPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            thumb(choice)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.hairline, lineWidth: 1) }
                .frame(width: 150)
                .accessibilityHidden(true)
            // Hidden from VoiceOver, which hears it in the picked row's value.
            Text(source.caption).font(.ui(11)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
                .accessibilityIdentifier("design.previewCaption")
            footnote
        }
    }

    // MARK: - The picked design

    /// When the picked design is the one in use, the checkmark and IN USE say
    /// so, and there is no button: a dead "In use" capsule only drew the eye.
    /// Use's confirmation then takes the button's place, in place of the
    /// footnote, so it lands where the tap was.
    private var pickedBlock: some View {
        let using = choice == inUse
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(choice.name).font(.display(28))
                Spacer(minLength: 8)
                Text(using ? "IN USE" : "PREVIEW").font(.machine(10)).tracking(1).foregroundStyle(linen)
                    .accessibilityLabel(using ? "\(choice.name), in use" : "\(choice.name), preview")
                    .accessibilityValue(source.spoken)
                    .accessibilityIdentifier("design.state")
            }
            Text(choice.summary).font(.ui(15)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            if !using { useButton }
            if notice != nil { noticeView } else { footnote }
        }
    }

    /// A fixed 52 pt capsule holding one line, so its type stops at
    /// accessibility2, and a long press shows the label large.
    private var useButton: some View {
        PrimaryButton(title: "Use \(choice.name)", accent: linen) { use() }
            .dynamicTypeSize(...DynamicTypeSize.accessibility2).accessibilityShowsLargeContentViewer()
            .accessibilityIdentifier("design.use")
    }

    @ViewBuilder private var noticeView: some View {
        if let notice {
            Label(notice, systemImage: "checkmark.circle").font(.ui(ax ? 12 : 14)).foregroundStyle(linen)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("design.notice")
                .id("design.notice")
        }
    }

    private var footnote: some View {
        Text("You can change this any time. Openings follow the design you choose.")
            .font(.ui(ax ? 11 : 12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
    }

    private func thumb(_ design: Design) -> some View {
        DesignThumb(design: design, tile: tile, reading: reading, lit: lit, roomLight: accent, art: art)
    }

    // MARK: - Actions

    private func pick(_ design: Design) {
        guard design != choice else { return }
        picked = design
        notice = nil
        Taps.detent(intensity: 0.4)
    }

    private func use() {
        let chosen = choice
        guard chosen != inUse else { return }
        // The home under the sheet swaps at once. OpeningLaunch is settled by
        // now, so the new home does not play its film.
        current = chosen.rawValue
        Taps.commit()
        let text = committedNotice(chosen)
        notice = text
        AccessibilityNotification.Announcement(text).post()
    }

    /// Also says when the saved film or mark has nothing to play in the new
    /// design, so the next launch opening straight to the wall is expected.
    private func committedNotice(_ design: Design) -> String {
        var text = "\(design.name) is now the app design. You’ll see it when you close Settings."
        let saved = OpeningStyle.saved(introStyle)
        if saved == .film || saved == .mark, OpeningStyle.kind(saved, in: design, assets: .bundled) == .none {
            text += " \(design.name) has no film of its own, so Tessera opens straight to the wall."
        }
        return text
    }

    /// Renders the frame as emitters, and reads it once for the gradient,
    /// when it, the brightness or the off state changed. The wall switched
    /// off draws its unlit lattice, and so does a phone that has no frame yet.
    /// Under Reduce Motion a new frame alone does not redraw the previews: the
    /// picture holds until the source, the brightness or the off state
    /// changes, or the first frame arrives.
    ///
    /// The emitters are the Panel and iPod homes' own (PanelRaster: the core,
    /// its halo, the warm dimming), so a preview carries as much light as
    /// the home it stands for. The archive's smaller dots came out about half
    /// as bright and screen-doored at this size.
    ///
    /// The raster is made off the main thread, and the tile, its reading and
    /// its light land together, so the gradient never runs ahead of the
    /// picture. A wall the home draws live (64 LEDs a side and so on) is
    /// rastered at about the preview's own pixels, never under four a LED:
    /// at four the discs' edges keep the average light within about 2
    /// percent of a 768 px raster, and a 64 wall costs about a ninth. A
    /// wall the home itself rasters asks for the home's own size, so the
    /// home under the sheet usually has it cached already, and it is shrunk
    /// once to the preview's pixels.
    private func refreshTile() {
        let latest = wall.frame
        let now = currentSource(latest)
        let take = !reduced || tile == nil || tileFrame == nil || now != source
        let frame = take ? latest : tileFrame
        let duty = off ? 1 : wall.state.brightness
        if now != source { source = now }
        guard !rendering else { return }
        guard tile == nil || frame != tileFrame || duty != tileDuty || off != tileOff else { return }
        tileFrame = frame; tileDuty = duty; tileOff = off
        let side = Panel.square(frame) ?? (Panel.learned ? Panel.side : Panel.bench)
        let px: [UInt8] = off || frame == nil ? Panel.blank(side: side) : [UInt8](frame ?? Data())
        let cell: Int? = side > PanelCanvas.liveLimit ? nil : max(4, Int(Self.tilePixels) / side)
        let pixels = Self.tilePixels
        let read = FrameRenderer.read(frame)
        let light = off ? 0 : read.lit * wall.state.brightness
        rendering = true
        Task {
            let image = await Task.detached(priority: .userInitiated) {
                PanelRaster.image(px, side: side, duty: duty, cell: cell).map { PanelRaster.shrink($0, to: pixels) }
            }.value
            tile = image
            reading = read
            lit = light
            rendering = false
        }
    }

    /// The Panel preview's wall is about 86 pt, 258 px at 3x. The Room and
    /// iPod walls are smaller.
    private static let tilePixels: CGFloat = 288
}

// MARK: - The previews

/// The two room renders, shrunk once for the previews. RoomBase and RoomLight
/// are 1170 x 2532 each, about 12 MB apiece decoded, and a Panel or iPod phone
/// never decodes them otherwise. Until they arrive the Room preview shows the
/// room's gradient alone.
@MainActor
enum DesignArt {
    struct Images {
        let base: UIImage
        let light: UIImage?
    }
    private(set) static var cached: Images?
    /// The decode under way, so a page reopened before it finishes waits for
    /// the same result rather than showing the gradient alone for that visit.
    private static var loading: Task<Void, Never>?

    static func load() async {
        guard cached == nil else { return }
        if let loading { await loading.value; return }
        let task = Task { await decode() }
        loading = task
        await task.value
        loading = nil
    }

    private static func decode() async {
        let size = CGSize(width: 360, height: 780)
        // byPreparingThumbnail decodes off the main thread, straight to size.
        guard let base = await UIImage(named: "RoomBase")?.byPreparingThumbnail(ofSize: size) else { return }
        let light = await UIImage(named: "RoomLight")?.byPreparingThumbnail(ofSize: size)
        cached = Images(base: base, light: light)
    }
}

/// One home, small. Composed at the homes' own 390 x 844 point layout and
/// scaled down, so the room's gradient, its blur and every placement keep
/// their proportions. There is no text inside. Kept in a compositing group:
/// the room light's screen blend must stay inside the preview, and nothing
/// here may sit under a layer effect (GlitchIn), which isolates blends.
struct DesignThumb: View {
    let design: Design
    /// The frame as emitters, shared by all three previews. Nil draws black.
    let tile: UIImage?
    let reading: FrameReading
    /// How much light the wall gives: its lit share times brightness, 0 off.
    let lit: Double
    /// The room's steady accent, the colour the Room home's light takes.
    let roomLight: Color
    let art: DesignArt.Images?

    private static let size = CGSize(width: 390, height: 844)

    var body: some View {
        GeometryReader { geo in
            composition
                .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
                .scaleEffect(geo.size.width / Self.size.width, anchor: .topLeading)
        }
        .aspectRatio(Self.size.width / Self.size.height, contentMode: .fit)
        .compositingGroup()
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var composition: some View {
        switch design {
        case .room: room
        case .classic: panel
        case .ipod: ipod
        }
    }

    /// The sleeve's gradient every page sits on (RootView draws it behind
    /// both homes). Without it the room's clear back wall and the iPod's
    /// surroundings would show a dark hole the real homes never have.
    private var gradient: some View {
        Room(palette: lit > 0.001 ? (Room.palette(reading.px) ?? reading.palette) : [],
             px: lit > 0.001 ? reading.px : nil, light: lit, surge: 0)
    }

    private var room: some View {
        ZStack(alignment: .topLeading) {
            gradient
            if let art {
                Image(uiImage: art.base).resizable().interpolation(.medium)
                    .frame(width: Self.size.width, height: Self.size.height)
                if lit > 0.001, let light = art.light {
                    Image(uiImage: light).resizable().interpolation(.medium)
                        .colorMultiply(roomLight)
                        .blendMode(.screen)
                        .opacity(min(0.9, 1.1 * lit))
                        .frame(width: Self.size.width, height: Self.size.height)
                }
            }
            wall(in: Self.roomFace)
        }
    }

    /// Where the wall is in the room render: the bounding box of its face,
    /// from the same geometry the Room home uses.
    private static let roomFace: CGRect = {
        if let face = RoomGeometry.loaded?.face, face.count == 4, face.allSatisfy({ $0.count >= 2 }) {
            let xs = face.map { $0[0] }, ys = face.map { $0[1] }
            let x0 = xs.min() ?? 0, x1 = xs.max() ?? 0, y0 = ys.min() ?? 0, y1 = ys.max() ?? 0
            return CGRect(x: x0 * size.width, y: y0 * size.height, width: (x1 - x0) * size.width, height: (y1 - y0) * size.height)
        }
        return CGRect(x: 0.228 * size.width, y: 0.190 * size.height, width: 0.544 * size.width, height: 0.252 * size.height)
    }()

    /// Panel: the wall across the top on the app's ground, in its bezel.
    private var panel: some View {
        let side = 0.84 * Self.size.width, x = 0.08 * Self.size.width, y = 0.166 * Self.size.height
        let bezel = 0.012 * Self.size.width
        return ZStack(alignment: .topLeading) {
            Ink.ground
            Color(hex: 0x12110F)
                .frame(width: side + bezel * 2, height: side + bezel * 2)
                .offset(x: x - bezel, y: y - bezel)
            wall(in: CGRect(x: x, y: y, width: side, height: side))
        }
    }

    /// iPod: the rendered body over the gradient, its screen's paper, the
    /// status strip, and the wall where Now Playing puts it (NowPlayingScreen:
    /// 11 in from the left, under the 28 pt strip and a 10 pt gap, 130 wide).
    private var ipod: some View {
        let k = 0.83 * Self.size.width / IPodMetrics.bodyW
        let origin = CGPoint(x: (Self.size.width - IPodMetrics.bodyW * k) / 2, y: 0.17 * Self.size.height)
        let screen = IPodMetrics.screen
        let lcd = CGRect(x: origin.x + screen.minX * k, y: origin.y + screen.minY * k,
                         width: screen.width * k, height: screen.height * k)
        return ZStack(alignment: .topLeading) {
            gradient
            Group {
                if let front = IPodBody.rendered {
                    Image(uiImage: front).resizable().interpolation(.medium)
                } else {
                    RoundedRectangle(cornerRadius: IPodMetrics.bodyRadius * k, style: .continuous).fill(Color(hex: 0x151412))
                }
            }
            .frame(width: IPodMetrics.bodyW * k, height: IPodMetrics.bodyH * k)
            .offset(x: origin.x, y: origin.y)
            ZStack(alignment: .topLeading) {
                IPodLCD.paper
                IPodLCD.header.frame(height: 28 * k)
                    .overlay(alignment: .bottom) { IPodLCD.rule.frame(height: 1) }
                wall(in: CGRect(x: 11 * k, y: 38 * k, width: 130 * k, height: 130 * k))
                // Where the song's name and artist sit, as two quiet bars.
                IPodLCD.rule.frame(width: 110 * k, height: 11 * k).clipShape(Capsule())
                    .offset(x: 152 * k, y: 41 * k)
                IPodLCD.rule.opacity(0.7).frame(width: 76 * k, height: 8 * k).clipShape(Capsule())
                    .offset(x: 152 * k, y: 61 * k)
            }
            .frame(width: lcd.width, height: lcd.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 3 * k))
            .offset(x: lcd.minX, y: lcd.minY)
        }
    }

    private func wall(in rect: CGRect) -> some View {
        Group {
            if let tile {
                Image(uiImage: tile).resizable().interpolation(.medium)
            } else {
                Color.black
            }
        }
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
    }
}
