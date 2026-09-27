import SwiftUI

struct PanelPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.scenePhase) private var scene
    @Environment(\.dynamicTypeSize) private var type
    let accent: Color
    @State private var pattern: PanelDiagnostic = .white
    @State private var display = TemporaryWallDisplay()
    @State private var notice: String?
    // display.busy is also true for a pattern change and for the poll after a
    // finish, so the button labels track their own write.
    @State private var starting = false
    @State private var finishing = false
    #if DEBUG
    @State private var hooked = false
    #endif
    private let ice = Color(hex: 0xC4CFCA)
    private var ours: Bool { display.active && display.purpose == "panel" }
    /// The purpose of another screen's check that holds the wall. Ignored
    /// offline, where the last answer may be stale.
    private var occupied: String? { wall.link.isLive && !ours ? display.occupiedBy : nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("PANEL CHECK", systemImage: "square.grid.3x3.square").font(.machine(type.isAccessibilitySize ? 8 : 11)).tracking(type.isAccessibilitySize ? 0 : 1.4).foregroundStyle(ice)
                    if !type.isAccessibilitySize {
                        // Both lines stay under 327 pt up to xxxLarge (the
                        // headline is hidden at accessibility sizes), so the
                        // forced break never leaves a word on its own line.
                        Text("Check your\npanel lights.").font(.display(40)).tracking(-1).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(type.isAccessibilitySize ? "Choose a pattern to check the lights." : "Choose a pattern, then look closely at the lights on the wall.").font(.ui(type.isAccessibilitySize ? 12 : 15)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                }
                if !wall.link.isLive {
                    // The status comes before the controls it disables. The
                    // footnote already says "Connect to your wall", so the card
                    // states the status, as the other offline cards do.
                    CreativeConnectionNotice(title: "Your wall is offline",
                                             detail: type.isAccessibilitySize ? "You can still explore the patterns here." : "You can explore patterns here. A physical panel is needed to check its lights.",
                                             symbol: "wifi.slash", tint: ice)
                }
                // The choices sit right under the preview (first at accessibility
                // sizes, where the preview moves down), so "Choose a pattern"
                // has its answer on the first screen.
                VStack(alignment: .leading, spacing: 16) {
                    if !type.isAccessibilitySize { preview }
                    picker
                }
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(pattern.title).font(type.isAccessibilitySize ? .ui(18, .semibold) : .display(28))
                        Spacer(minLength: 8)
                        Text(ours ? "ON THE WALL" : "PREVIEW").font(.machine(type.isAccessibilitySize ? 7 : 10)).tracking(1).foregroundStyle(ice)
                    }
                    Text(pattern.detail).font(.ui(type.isAccessibilitySize ? 12 : 15)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                    // PrimaryButton draws its own disabled look only from
                    // `enabled`, so the conditions go there, not in .disabled.
                    // It is a fixed 52 pt capsule holding one line, so its type
                    // stops growing at accessibility2, where the whole label
                    // still fits. A long press shows the label large.
                    if ours {
                        PrimaryButton(title: finishing ? "Finishing…" : "Finish panel check", enabled: !display.busy, accent: ice) {
                            Task { await finish() }
                        }.dynamicTypeSize(...DynamicTypeSize.accessibility2).accessibilityShowsLargeContentViewer()
                            .accessibilityIdentifier("panel.end")
                    } else {
                        PrimaryButton(title: starting ? "Starting…" : "Start panel check",
                                      enabled: wall.link.isLive && !display.busy && !display.active && occupied == nil, accent: ice) {
                            Task { await start() }
                        }.dynamicTypeSize(...DynamicTypeSize.accessibility2).accessibilityShowsLargeContentViewer()
                            .accessibilityIdentifier("panel.start")
                    }
                    Text(footnote).font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                }
                if let owner = occupied {
                    // Shown instead of the problem. After a takeover, or once the
                    // next poll learns what refused a start, naming what holds
                    // the wall says more. The footnote above says when Start
                    // comes back, so this only names the holder.
                    CreativeConnectionNotice(title: "The wall is in use", detail: Self.occupant(owner),
                                             symbol: "square.dashed", tint: ice).accessibilityIdentifier("panel.occupied")
                } else if let issue = display.problem {
                    CreativeConnectionNotice(title: "Check not confirmed", detail: issue, symbol: "exclamationmark.circle", tint: ice).accessibilityIdentifier("panel.problem")
                }
                if let notice { Text(notice).font(.ui(14)).foregroundStyle(ice).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("panel.notice") }
                if type.isAccessibilitySize { preview }
                Text("The phone shows the same pattern. Judge brightness, colour, and individual emitters on the wall itself.")
                    .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }.padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 40)
        }.background(Color(hex: 0x161B1A)).foregroundStyle(Ink.ink).tint(ice)
            .navigationTitle("Panel check").navigationBarTitleDisplayMode(.inline)
            .task(id: scene) {
                guard scene == .active else { return }
                while !Task.isCancelled {
                    // Also poll while idle, so a check another screen owns is
                    // known before Start is tapped. Poll while a failure is shown
                    // too: refresh() keeps the message on an idle answer, and it
                    // learns what refused a start (occupiedBy) or picks up a
                    // start whose reply was lost.
                    await display.refresh(on: wall)
                    do { try await Task.sleep(for: .seconds(2)) } catch { break }
                }
            }
            // Always end, even before the start is confirmed: end() waits for a
            // write in flight, falls back to the attempted token, and sends
            // nothing when no start was tried.
            .onDisappear {
                let session = display, source = wall
                Task { _ = await session.end(on: source) }
            }
            .onChange(of: scene) { _, phase in
                guard phase == .background else { return }
                let held = ours
                Task { if await display.end(on: wall), held { notice = "The panel check ended when you left the app." } }
            }
            .onAppear {
                #if DEBUG
                let args = CommandLine.arguments
                if let i = args.firstIndex(of: "-panel-pattern"), args.indices.contains(i + 1), let item = PanelDiagnostic(rawValue: args[i + 1]) { pattern = item }
                // -panel-state running|finished starts the check on the wall at
                // -wall.host (the QA fixture), and "finished" ends it again, so
                // captures reach those states without touches.
                if !hooked, let i = args.firstIndex(of: "-panel-state"), args.indices.contains(i + 1) {
                    hooked = true
                    let state = args[i + 1]
                    Task {
                        var tries = 0
                        while !wall.link.isLive, tries < 40 { tries += 1; try? await Task.sleep(for: .milliseconds(250)) }
                        await start()
                        // Finish only a check the wall confirmed, so a failed start
                        // cannot be captured as "Panel check finished".
                        if state == "finished", ours { await finish() }
                    }
                }
                #endif
            }
    }

    private var footnote: String {
        if ours {
            return type.isAccessibilitySize ? "Ends after two minutes without a change." : "Ends when you finish or leave this page, or after two minutes without a change."
        }
        if !wall.link.isLive { return "Connect to your wall to start the check." }
        // The notice below names what holds the wall, so this only says when.
        if occupied != nil { return "You can start when the wall is free." }
        // The wall may be showing a clock, Nine or video, not only artwork.
        // Nothing runs yet, so the short form says that rather than when a
        // check ends.
        return type.isAccessibilitySize ? "Your wall keeps its display until you start." : "Your wall keeps its current display until you start. The check ends when you leave this page, or after two minutes without a change."
    }

    /// What holds the wall, from the purpose its screen registered.
    private static func occupant(_ purpose: String) -> String {
        switch purpose {
        case "calibration": "True colour is measuring the wall."
        case "guests": "A guest code is on the wall."
        case "onboarding": "Setup is showing a preview on the wall."
        case "panel": "Another panel check is on the wall."
        default: "Another screen is using the wall."
        }
    }

    private func start() async {
        starting = true
        defer { starting = false }
        if await display.show(on: wall, pixels: pattern.pixels(side: Panel.side), purpose: "panel", seconds: 120) {
            notice = nil; Taps.commit()
        }
    }

    private func finish() async {
        finishing = true
        defer { finishing = false }
        if await display.end(on: wall) { notice = "Panel check finished. Your previous display is back."; Taps.commit() }
    }

    private var preview: some View {
        VStack(spacing: 12) {
            // 160 pt keeps the preview, the patterns and the button on the
            // first screen at the default text size.
            swatch(pattern).aspectRatio(1, contentMode: .fit)
                // A hairline just outside the pattern, so Black still has an
                // edge on the dark well. It covers no pattern pixel.
                .overlay { Rectangle().stroke(Ink.hairline, lineWidth: 1).padding(-0.5) }
                .frame(maxWidth: type.isAccessibilitySize ? 140 : 160)
                .padding(type.isAccessibilitySize ? 12 : 16)
                .background(Color(hex: 0x0C0E0D), in: RoundedRectangle(cornerRadius: 16))
            if !type.isAccessibilitySize {
                HStack { Text("64 x 64 COMPOSITION"); Spacer(); Text("\(Panel.side) x \(Panel.side) OUTPUT") }
                    .font(.machine(9)).foregroundStyle(Ink.faint).accessibilityHidden(true)
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel("\(pattern.title) pattern, \(ours ? "on the wall" : "preview")")
    }
    /// One row of small swatches, so every choice shows on the first screen.
    /// The selected one is named in full just below it. Swatches do not grow
    /// with text size, and at accessibility sizes the names are left off: the
    /// title under the row names the choice. Seven 40 pt columns fit a 375 pt
    /// phone on one row, and the label area keeps each tap target at 44 pt.
    private var picker: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 40, maximum: 72), spacing: 6)], spacing: 10) {
            ForEach(PanelDiagnostic.allCases) { item in
                let chosen = pattern == item
                Button { select(item) } label: {
                    VStack(spacing: 6) {
                        swatch(item).aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Ink.hairline) }
                            .padding(3)
                            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(chosen ? ice : .clear, lineWidth: 2) }
                        if !type.isAccessibilitySize {
                            Text(item.title).font(.ui(11, chosen ? .semibold : .medium))
                                .foregroundStyle(chosen ? Ink.ink : Ink.dim)
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(PressStyle()).disabled(display.busy)
                    .accessibilityLabel("\(item.title) pattern").accessibilityAddTraits(chosen ? .isSelected : [])
                    .accessibilityIdentifier("panel.pattern.\(item.rawValue)")
            }
        }
    }
    private func swatch(_ item: PanelDiagnostic) -> some View {
        Canvas { context, size in
            let pixels = item.pixels(side: 64)
            for y in 0..<64 { for x in 0..<64 {
                let i = (y * 64 + x) * 3
                let colour = Color(red: Double(pixels[i]) / 255, green: Double(pixels[i + 1]) / 255, blue: Double(pixels[i + 2]) / 255)
                context.fill(Path(CGRect(x: CGFloat(x) * size.width / 64, y: CGFloat(y) * size.height / 64,
                                        width: size.width / 64, height: size.height / 64)), with: .color(colour), style: FillStyle(antialiased: false))
            } }
        }.accessibilityHidden(true)
    }
    private func select(_ item: PanelDiagnostic) {
        guard !display.busy else { return }
        if ours {
            Task { if await display.update(on: wall, pixels: item.pixels(side: Panel.side)) { pattern = item; Taps.commit() } }
        } else { pattern = item }
    }
}
