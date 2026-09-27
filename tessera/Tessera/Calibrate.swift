import AVFoundation
import CoreImage
import PhotosUI
import SwiftUI

/// A temporary display transaction owns every measurement and comparison.
/// Cancellation always restores the original frame and gains, including after
/// several repeated measurements. Only Keep makes a correction permanent.
struct CalibrateScreen: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scene
    let accent: Color
    private enum Step { case card, aim, result }
    @State private var step: Step = .card
    @State private var display = TemporaryWallDisplay()
    @State private var original = CalibrationMeasurement.Gains.neutral
    @State private var measurementBase = CalibrationMeasurement.Gains.neutral
    @State private var reading: CalibrationMeasurement.Reading?
    @State private var shot: CGImage?
    @State private var pick: PhotosPickerItem?
    @State private var showCamera = false
    @State private var denied = false
    @State private var restricted = false
    @State private var busy = false
    @State private var began = false
    @State private var closing = false
    @State private var imported = false
    @State private var showingBefore = false
    @State private var comparisonConfirmed = true
    @State private var needsCard = false
    @State private var problem: String?
    @State private var notice: String?
    @State private var fixture = false
    @State private var fixtureStep = ""
    private let pearl = Color(hex: 0xDFE8DC)
    private var active: Bool { fixture ? fixtureStep != "occupied" : display.active }
    private var offline: Bool { fixture ? fixtureStep == "offline" : !wall.link.isLive }
    private var occupier: String? { fixture ? (fixtureStep == "occupied" ? "panel" : nil) : display.occupiedBy }
    private var locked: Bool { busy || display.busy || closing }
    private var flat: [UInt8] { [UInt8](repeating: 191, count: Panel.side * Panel.side * 3) }
    private static let top = "calibration.scrollTop"

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if step == .aim, let shot {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Keep the measuring area inside the lit panel. Exclude the bezel and the room.").font(.ui(14)).foregroundStyle(Ink.dim).padding(.horizontal, 24).padding(.top, 12)
                    Framing(source: [shot], accent: pearl, onCancel: { step = .card }, onUse: { _ in }, onCrop: { crop in measure(shot, crop: crop) }, commitTitle: "Measure white")
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        // Problems, camera access and notices sit under each
                        // step's headline (see messages), never below the fold.
                        VStack(alignment: .leading, spacing: 0) {
                            if step == .result { result } else { card }
                        }.id(Self.top).padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 30)
                    }.scrollIndicators(.hidden)
                        // The actions bar does not scroll. A short fade here and a
                        // hairline on the bar make its edge read as more content.
                        .overlay(alignment: .bottom) {
                            LinearGradient(colors: [Ink.ground.opacity(0), Ink.ground], startPoint: .top, endPoint: .bottom)
                                .frame(height: 16).allowsHitTesting(false).accessibilityHidden(true)
                        }
                        // A message that arrives after the person scrolled down
                        // brings the view back up to it.
                        .onChange(of: problem ?? display.problem) { _, now in if now != nil { proxy.scrollTo(Self.top, anchor: .top) } }
                        .onChange(of: denied) { _, now in if now { proxy.scrollTo(Self.top, anchor: .top) } }
                }
                actions
            }
        }.background(Ink.ground).tint(pearl).preferredColorScheme(.dark).interactiveDismissDisabled()
            .task {
                if !began {
                    began = true
                    #if DEBUG
                    if configureFixture() { return }
                    #endif
                }
                if fixture { return }
                while !Task.isCancelled {
                    // The first look happens before any sleep, so Start already
                    // knows whether another check has the wall.
                    if !locked, scene == .active {
                        let wasActive = display.active
                        await display.refresh(on: wall)
                        if wasActive && !display.active { problem = "The measurement session ended. Start again to show a fresh card."; step = .card; reading = nil }
                        // The card came up without this screen seeing start()
                        // succeed, for example a start whose reply was lost and
                        // that the refresh adopted. Any start failure message is
                        // stale. start() set the prior before it asked.
                        if !wasActive && display.active { problem = nil }
                    }
                    do { try await Task.sleep(for: .seconds(8)) } catch { return }
                }
            }
            // A session can vanish outside the refresh loop too: a change the
            // wall answers with 400 or 409 drops it inside the write. Go back
            // to the card whenever that happens, not only when the loop sees it.
            .onChange(of: display.active) { was, now in
                guard was, !now, !closing, !fixture, step != .card else { return }
                if problem == nil { problem = "The measurement session ended. Start again to show a fresh card." }
                step = .card; reading = nil
            }
            .onDisappear {
                // No display.active check, like Panel check: end() waits for a
                // write in flight, falls back to a start the wall accepted but
                // never confirmed, and costs nothing when no card was shown.
                // close() already ends its own session, and presenting the
                // camera cover also fires onDisappear, which must not take the
                // card down mid-measurement.
                guard !closing, !fixture, !showCamera else { return }
                let session = display, link = wall
                Task { _ = await session.end(on: link) }
            }
            .onChange(of: scene) { _, phase in
                // Back from Settings with Camera allowed: offer the camera again
                // instead of leaving Settings as the main action.
                if phase == .active, denied, !restricted, !fixture, AVCaptureDevice.authorizationStatus(for: .video) == .authorized { denied = false }
                // The camera and photo import run inside Tessera, so leaving the
                // app means leaving the wall. Take the full-brightness card and
                // any unsaved balance down now, not after the wall's timeout.
                guard phase == .background, !closing, !fixture else { return }
                let held = display.active || display.busy || busy
                let session = display, link = wall
                if held { showCamera = false }
                Task {
                    _ = await session.end(on: link)
                    guard held, !session.active else { return }
                    step = .card; reading = nil; shot = nil; needsCard = false; showingBefore = false; comparisonConfirmed = true; notice = nil
                    problem = "The card was taken down while Tessera was in the background. Show it again to continue."
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CalibrationCamera { outcome in
                    showCamera = false
                    switch outcome {
                    case .captured(let image):
                        if let upright = Self.upright(image) { imported = false; shot = upright; step = .aim; problem = nil }
                        else { problem = "The photo could not be opened. Take another shot." }
                    case .cancelled: break
                    case .failed(let message): problem = message
                    }
                }.ignoresSafeArea()
            }
            .onChange(of: pick) { _, item in
                guard let item else { return }; busy = true; problem = nil
                Task {
                    defer { busy = false; pick = nil }
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data), let upright = Self.upright(image) else {
                        problem = "This photo could not be opened. Choose another image or use the camera."; return
                    }
                    guard await restoreMeasurementCardIfNeeded() else { return }
                    imported = true; shot = upright; step = .aim
                }
            }
    }
    private var topBar: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("TRUE COLOUR").font(.machine(typeSize.isAccessibilitySize ? 8 : 10)).tracking(1).foregroundStyle(pearl)
                Text(step == .card ? "Step 1 of 3. Photograph" : step == .aim ? "Step 2 of 3. Measure" : "Step 3 of 3. Compare").font(.ui(13)).foregroundStyle(Ink.dim)
            }
            Spacer(minLength: 0)
            Button { close(keep: false) } label: { Image(systemName: "xmark").font(.system(size: 16, weight: .medium)).frame(width: 44, height: 44).background(Ink.plaster, in: Circle()) }
                .foregroundStyle(Ink.ink).disabled(locked).accessibilityLabel("Cancel calibration and restore the wall").accessibilityIdentifier("calibration.cancel")
        }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 8)
    }
    private var card: some View {
        VStack(alignment: .leading, spacing: 23) {
            headline(active ? "Photograph the\ncard on your wall." : "Show a grey card\non your wall.", size: 40, tracking: -0.5)
            messages
            cardPreview
            VStack(alignment: .leading, spacing: 14) {
                instruction("1", "Face the panel squarely.", "Include the whole lit surface. Keep bright room reflections off it.")
                instruction("2", "Leave room in the highlights.", "Lower the camera exposure until the individual LEDs are visible.")
                instruction("3", "Frame only the light.", "After the photo, keep the panel inside the crop. Tessera reads its centre.")
            }
            Text("Daylight white balance is locked in Tessera’s camera. Camera processing still affects the reading. Compare on the real panel before keeping it.").font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }
    }
    /// At default sizes the display face keeps its two set lines. At
    /// accessibility sizes it drops the fixed break and uses a size where the
    /// longest word still fits the width, so lines only break between words.
    private func headline(_ lines: String, size: CGFloat, tracking: CGFloat) -> some View {
        let ax = typeSize.isAccessibilitySize
        return Text(ax ? lines.replacingOccurrences(of: "\n", with: " ") : lines)
            .font(.display(ax ? 14 : size)).tracking(ax ? 0 : tracking).foregroundStyle(Ink.ink)
            .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
    }
    /// Right under the headline, so a failed reading, missing camera access
    /// or a notice is on screen without scrolling and never under the bar.
    @ViewBuilder private var messages: some View {
        if let problem = problem ?? display.problem {
            Label(problem, systemImage: "exclamationmark.circle").font(.ui(14)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("calibration.problem")
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .background(Ink.plaster, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(pearl.opacity(0.16), lineWidth: 1))
        }
        if step != .result, denied { cameraAccess }
        if let notice { Text(notice).font(.ui(13)).foregroundStyle(pearl).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("calibration.notice") }
    }
    private var cameraAccess: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(restricted ? "Camera is not available" : "Camera access is off", systemImage: "camera.fill").font(.ui(15, .semibold)).foregroundStyle(Ink.ink)
            // Screen Time or a device profile sets .restricted. Settings
            // has no switch for it, so only offer the photo route.
            Text(restricted ? "Camera use is restricted on this iPhone. Choose a photo instead." : "Allow Camera in iPhone Settings, then come back and show the card again. You can also choose a photo.").font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            // Once the card is up, Settings is the main action in the bar.
            if !restricted, !active {
                Button("Open iPhone Settings") { openSettings() }.frame(minHeight: 44).accessibilityIdentifier("calibration.settings")
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(Ink.plaster, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(pearl.opacity(0.16), lineWidth: 1))
            .accessibilityIdentifier("calibration.denied")
    }
    /// A small swatch beside its labels at default sizes, so all three
    /// instructions fit above the actions bar. Stacked at accessibility sizes.
    private var cardPreview: some View {
        let ax = typeSize.isAccessibilitySize
        let swatch = Rectangle().fill(Color(red: 191.0 / 255, green: 191.0 / 255, blue: 191.0 / 255))
            .aspectRatio(1, contentMode: .fit)
            .overlay { Rectangle().strokeBorder(Ink.ink.opacity(0.35), lineWidth: 1) }
            .accessibilityLabel("Neutral measurement card, red green and blue each 191 of 255")
        let title = Text(active ? "ON YOUR WALL" : "MEASUREMENT CARD").font(.machine(ax ? 8 : 9)).tracking(1).foregroundStyle(pearl)
        let value = Text("191 / 255").font(.machine(ax ? 8 : 10)).foregroundStyle(Ink.dim)
        let caption = Text(active ? (measurementBase == original ? "Neutral grey with your current balance." : "Neutral grey with the proposed balance.") : "Your wall goes back to what it was showing when you finish.").font(.ui(12)).foregroundStyle(Ink.dim)
        return Group {
            if ax {
                VStack(spacing: 16) {
                    HStack(alignment: .top) { title; Spacer(); value }
                    swatch.frame(maxWidth: 116)
                    caption.multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity)
            } else {
                HStack(alignment: .center, spacing: 18) {
                    swatch.frame(width: 96, height: 96)
                    VStack(alignment: .leading, spacing: 6) {
                        title
                        value
                        caption.fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.padding(ax ? 20 : 18).background(Color(hex: 0x1A221E), in: RoundedRectangle(cornerRadius: 22))
    }
    private var result: some View {
        VStack(alignment: .leading, spacing: 24) {
            headline("Review the\ncorrection.", size: 38, tracking: -0.6)
            messages
            if let reading {
                VStack(alignment: .leading, spacing: 18) {
                    Label("PROPOSED CORRECTION", systemImage: "slider.horizontal.3").font(.machine(typeSize.isAccessibilitySize ? 8 : 10)).tracking(0.5).foregroundStyle(pearl)
                    CalibrationGainRows(before: original, after: reading.gains, accent: pearl)
                    Text("Relative light output. The brightest channel stays at 1.00.").font(.ui(12)).foregroundStyle(Ink.dim)
                }.padding(22).background(Color(hex: 0x1A221E), in: RoundedRectangle(cornerRadius: 22)).accessibilityIdentifier("calibration.result")
                VStack(alignment: .leading, spacing: 12) {
                    Text("Compare on your wall").font(.ui(21, .semibold)).foregroundStyle(Ink.ink)
                    // Offline the switch cannot reach the wall, so the text
                    // says so and the status line, which it cannot confirm,
                    // waits for the link.
                    if offline {
                        Label("Comparing needs the wall. Reconnect to switch between Before and After.", systemImage: "wifi.slash").font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("The same neutral card, with your original balance or this adjustment. The phone card is a reference. Only the LEDs can show the physical change.").font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        comparison("Before", before: true)
                        comparison("After", before: false)
                    }
                    if !offline {
                        Label(!comparisonConfirmed ? "Comparison not confirmed. Try again." : showingBefore ? "Original balance is on the wall" : "Proposed balance is on the wall", systemImage: comparisonConfirmed ? "square.grid.3x3.fill" : "exclamationmark.circle").font(.ui(13)).foregroundStyle(pearl).accessibilityIdentifier("calibration.comparison")
                    }
                }
                if imported { Text("Photo-library images may already have automatic white balance or edits. Treat this adjustment as a visual starting point.").font(.ui(13)).foregroundStyle(Ink.dim) }
                Text("Repeated readings are optional. Each starts from the proposed correction. Discard restores the balance you had before this session.").font(.ui(12)).foregroundStyle(Ink.dim)
            }
        }
    }
    private func instruction(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Text(number).font(.machine(11)).foregroundStyle(pearl).frame(width: 23, height: 23).overlay(Circle().stroke(pearl.opacity(0.3), lineWidth: 1)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.ui(15, .semibold)).foregroundStyle(Ink.ink); Text(detail).font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true) }
        }
    }
    private func comparison(_ title: String, before: Bool) -> some View {
        // Offline, a change could only wait out the write timeout, so the
        // comparison waits for the link like the primary action does.
        // Turned off, both sides take a quiet fill with a readable label
        // (4.5:1) instead of a fade, and the chosen side keeps its check
        // and a pearl outline.
        let off = locked || !active || offline
        let selected = showingBefore == before
        return Button { compare(before: before) } label: {
            HStack(spacing: 8) {
                if selected { Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)) }
                Text(title).font(.ui(15, .semibold))
            }.frame(maxWidth: .infinity, minHeight: 49).foregroundStyle(off ? Ink.faint : selected ? Ink.ground : Ink.ink)
                .background(selected && !off ? pearl : Ink.plaster, in: RoundedRectangle(cornerRadius: 13))
                .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(off ? (selected ? pearl.opacity(0.35) : Ink.hairline) : .clear, lineWidth: 1) }
                .contentShape(RoundedRectangle(cornerRadius: 13))
        }.buttonStyle(CalibrationLinkStyle()).disabled(off).accessibilityAddTraits(selected ? .isSelected : []).accessibilityIdentifier(before ? "calibration.before" : "calibration.after")
    }
    private var actions: some View {
        VStack(spacing: 4) {
            if locked { ProgressView().tint(pearl).accessibilityLabel("Waiting for the wall").padding(.bottom, 8) }
            if offline {
                // This bar does not scroll, so at accessibility sizes the note
                // is shorter and smaller and leaves room for the result above.
                let ax = typeSize.isAccessibilitySize
                note(active ? (ax ? "The wall is not connected. It undoes this check by itself." : "The wall is not connected. Nothing is saved, and the wall undoes this check by itself within 5 minutes.") : (ax ? "Connect to your wall first." : "Connect to your wall to show the measurement card."), icon: "wifi.slash", id: "calibration.offline")
            } else if !active, let occupier {
                note(Self.occupied(by: occupier), icon: "hourglass", id: "calibration.occupied")
            }
            if step == .result {
                primary("Keep correction", id: "calibration.keep") { close(keep: true) }
                // Side by side when both fit, so the bar stays short and the
                // comparison above it stays in view. Stacked at larger sizes.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 24) { repeatButton; discardButton }
                    VStack(spacing: 4) { repeatButton; discardButton }
                }
            } else if active {
                if denied && restricted {
                    // Screen Time or a profile blocks the camera, so a photo
                    // is the only route and becomes the main action.
                    photoPicker(primary: true)
                } else if denied {
                    primary("Open iPhone Settings", id: "calibration.settings", needsWall: false) { openSettings() }
                    photoPicker(primary: false)
                } else {
                    primary("Open the camera", id: "calibration.camera") { openCamera() }
                    photoPicker(primary: false)
                }
            } else {
                primary("Show measurement card", id: "calibration.start", blocked: occupier != nil) { Task { await start() } }
            }
        }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 8).background(Ink.ground)
            .overlay(alignment: .top) { Rectangle().fill(Ink.hairline).frame(height: 1).accessibilityHidden(true) }
    }
    // Like Keep, a repeat and a photo need the wall, so they wait for the
    // link instead of timing out. Discard never waits.
    private var repeatButton: some View {
        let off = locked || !active || offline
        return Button("Take another reading") { repeatMeasurement() }.font(.ui(14, .medium)).foregroundStyle(off ? Ink.faint : pearl).frame(minHeight: 44)
            .buttonStyle(CalibrationLinkStyle()).disabled(off).accessibilityIdentifier("calibration.repeat")
    }
    private var discardButton: some View {
        Button("Discard this session") { close(keep: false) }.font(.ui(13)).foregroundStyle(locked ? Ink.faint : Ink.dim).frame(minHeight: 44)
            .buttonStyle(CalibrationLinkStyle()).disabled(locked).accessibilityIdentifier("calibration.discard")
    }
    @ViewBuilder private func photoPicker(primary: Bool) -> some View {
        let off = locked || offline
        if primary {
            PhotosPicker(selection: $pick, matching: .images) { primaryLabel("Choose a photo", off: off) }
                .buttonStyle(PressStyle()).disabled(off).accessibilityIdentifier("calibration.photo")
        } else {
            PhotosPicker(selection: $pick, matching: .images) { Text("Choose a photo").font(.ui(14, .medium)).foregroundStyle(off ? Ink.faint : pearl).frame(minHeight: 44) }
                .buttonStyle(CalibrationLinkStyle()).disabled(off).accessibilityIdentifier("calibration.photo")
        }
    }
    /// Turned off, the button keeps a readable label (4.5:1) on a quiet fill
    /// instead of fading. A fade also faded the label into its own fill.
    private func primaryLabel(_ title: String, off: Bool) -> some View {
        Text(title).font(.ui(16, .semibold)).frame(maxWidth: .infinity, minHeight: 53)
            .foregroundStyle(off ? Ink.faint : Color(hex: 0x132018))
            .background(off ? Ink.plaster : pearl, in: RoundedRectangle(cornerRadius: 15))
            .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(off ? Ink.hairline : .clear, lineWidth: 1) }
            .contentShape(RoundedRectangle(cornerRadius: 15))
    }
    private func primary(_ title: String, id: String, blocked: Bool = false, needsWall: Bool = true, action: @escaping () -> Void) -> some View {
        let off = locked || (needsWall && offline) || blocked
        return Button(action: action) { primaryLabel(title, off: off) }.buttonStyle(PressStyle()).disabled(off).accessibilityIdentifier(id)
    }
    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
    private func note(_ text: String, icon: String, id: String) -> some View {
        Label(text, systemImage: icon).font(.ui(typeSize.isAccessibilitySize ? 9 : 13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 8).accessibilityIdentifier(id)
    }
    private static func occupied(by purpose: String) -> String {
        switch purpose {
        case "panel": "The panel check is on the wall. Finish it, then show the card."
        case "guests": "The guest Wi-Fi code is on the wall. Hide it, then show the card."
        case "onboarding": "First-run setup is using the wall. Finish it, then show the card."
        case "calibration": "Another colour measurement is on the wall. It ends by itself within 5 minutes."
        default: "Another check is on the wall. Finish it, then show the card."
        }
    }
    private func start() async {
        guard !busy else { return }; busy = true; problem = nil; notice = nil
        // Set the prior before asking. If the wall takes the card but its reply
        // is lost, the refresh loop adopts the session later, and measure() must
        // still build on the balance the wall shows. The card only overlays the
        // saved gains, so reading them now matches what the wall will show.
        original = .saved(r: wall.state.wbR, g: wall.state.wbG, b: wall.state.wbB)
        measurementBase = original; step = .card; reading = nil; showingBefore = false; needsCard = false; comparisonConfirmed = true
        let ok = await display.show(on: wall, pixels: flat, purpose: "calibration", seconds: 300, patch: ["brightness": 1])
        busy = false
        if !ok { problem = display.problem ?? "The wall has not confirmed the card. Reconnect and try again." }
    }
    private func openCamera() {
        guard active, !locked else { return }; problem = nil
        Task {
            busy = true
            let ready = await restoreMeasurementCardIfNeeded()
            busy = false
            guard ready else { return }
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: denied = false; showCamera = true
            case .notDetermined:
                if await AVCaptureDevice.requestAccess(for: .video) { denied = false; showCamera = true } else { denied = true; restricted = false }
            case .denied: denied = true; restricted = false
            case .restricted: denied = true; restricted = true
            @unknown default: problem = "Camera access is unavailable. Choose a photo instead."
            }
        }
    }
    private func measure(_ image: CGImage, crop: MediaCrop) {
        guard active, !locked else { return }
        let normalized = crop.normalizedRect(in: CGSize(width: image.width, height: image.height))
        let rect = CGRect(x: normalized.minX * CGFloat(image.width), y: normalized.minY * CGFloat(image.height), width: normalized.width * CGFloat(image.width), height: normalized.height * CGFloat(image.height))
        guard let pixels = Self.samples(image, rect: rect) else { problem = CalibrationMeasurement.Failure.malformed.localizedDescription; step = .card; return }
        do {
            let proposed = try CalibrationMeasurement.solve(pixels, prior: measurementBase)
            busy = true; problem = nil
            Task {
                let ok = fixture ? true : await display.update(on: wall, patch: gainPatch(proposed.gains))
                busy = false
                if ok { reading = proposed; showingBefore = false; comparisonConfirmed = true; step = .result; Taps.landed() }
                else { needsCard = true; problem = display.problem ?? "The wall did not confirm the comparison. Take another reading once it reconnects."; step = .card }
            }
        } catch { problem = error.localizedDescription; step = .card; Taps.error() }
    }
    private func compare(before: Bool) {
        guard let reading, !locked, active else { return }; busy = true; problem = nil
        Task {
            let ok = fixture ? true : await display.update(on: wall, patch: gainPatch(before ? original : reading.gains))
            busy = false
            if ok { showingBefore = before; comparisonConfirmed = true; Taps.detent() } else { comparisonConfirmed = false; problem = display.problem ?? "The comparison was not confirmed. Try again when the wall reconnects." }
        }
    }
    private func repeatMeasurement() {
        guard let reading, active, !locked else { return }; busy = true; problem = nil
        Task {
            let ok = fixture ? true : await display.update(on: wall, patch: cardPatch(reading.gains), pixels: flat)
            busy = false
            if ok { measurementBase = reading.gains; self.reading = nil; shot = nil; step = .card; showingBefore = false; comparisonConfirmed = true; needsCard = false; notice = "The proposed correction is active for this next reading." }
            else { problem = display.problem ?? "The next card was not confirmed. Your comparison is still here." }
        }
    }
    private func restoreMeasurementCardIfNeeded() async -> Bool {
        guard needsCard, !fixture else { return active }
        let ok = await display.update(on: wall, patch: cardPatch(measurementBase), pixels: flat)
        if ok { needsCard = false; problem = nil }
        else { problem = display.problem ?? "Confirm the measurement card before taking another photograph." }
        return ok
    }
    /// Only Keep waits for the wall. A discard saves nothing and the wall
    /// restores itself when the check times out, so an unreachable wall must
    /// never hold the person on this screen.
    private func close(keep: Bool) {
        guard !locked else { return }; closing = true; problem = nil
        let session = display, link = wall
        if !keep, !fixture, offline { Task { _ = await session.end(on: link) }; dismiss(); return }
        Task {
            let ok = fixture ? true : await session.end(on: link, keep: keep ? gainPatch(reading?.gains ?? original) : [:])
            if ok { Taps.commit(); dismiss() }
            else if !keep { dismiss() }
            else { closing = false; problem = session.problem ?? "The correction was not saved. Show the card and measure again." }
        }
    }
    private func gainPatch(_ gains: CalibrationMeasurement.Gains) -> [String: Double] { ["wb_r": gains.r, "wb_g": gains.g, "wb_b": gains.b] }
    /// A card sent again may open a fresh session if the wall's own timeout
    /// already ended the last one, so it carries full brightness each time.
    private func cardPatch(_ gains: CalibrationMeasurement.Gains) -> [String: Double] { gainPatch(gains).merging(["brightness": 1]) { $1 } }
    /// Preserve every source sample during orientation. The normal media importer
    /// makes a thumbnail, which can average saturated LEDs into valid-looking
    /// midtones before the clipping check ever sees them.
    private static func upright(_ image: UIImage) -> CGImage? {
        guard let source = image.cgImage, source.width > 0, source.height > 0,
              source.width <= 12_000, source.height <= 12_000,
              source.width * source.height <= 70_000_000 else { return nil }
        if image.imageOrientation == .up { return source }
        let orientation: Int32
        switch image.imageOrientation {
        case .up: orientation = 1
        case .upMirrored: orientation = 2
        case .down: orientation = 3
        case .downMirrored: orientation = 4
        case .leftMirrored: orientation = 5
        case .right: orientation = 6
        case .rightMirrored: orientation = 7
        case .left: orientation = 8
        @unknown default: return nil
        }
        let oriented = CIImage(cgImage: source).oriented(forExifOrientation: orientation)
        return CIContext().createCGImage(oriented, from: oriented.extent)
    }
    /// Convert the image's embedded colour profile into explicit sRGB before
    /// decoding. Nearest-neighbour sampling preserves clipped LEDs rather than
    /// averaging their saturation away during thumbnail downscaling.
    private static func samples(_ image: CGImage, rect: CGRect) -> [UInt8]? {
        guard rect.width >= 16, rect.height >= 16, rect.minX >= 0, rect.minY >= 0,
              rect.maxX <= CGFloat(image.width) + 0.01, rect.maxY <= CGFloat(image.height) + 0.01,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let side = 256
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .none
            let scale = CGFloat(side) / rect.width
            context.translateBy(x: -rect.minX * scale, y: -(CGFloat(image.height) - rect.maxY) * scale)
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale))
            return true
        }
        guard drawn else { return nil }
        var rgb = [UInt8](); rgb.reserveCapacity(side * side * 3)
        for index in stride(from: 0, to: rgba.count, by: 4) { rgb.append(contentsOf: rgba[index..<(index + 3)]) }
        return rgb
    }
    #if DEBUG
    private func configureFixture() -> Bool {
        let args = ProcessInfo.processInfo.arguments
        guard let key = args.firstIndex(of: "-calibration-step"), args.indices.contains(key + 1) else { return false }
        // Start from the wall's own balance, as start() does, so the result
        // step and the True colour page show the same starting values.
        fixture = true; fixtureStep = args[key + 1]; original = .saved(r: wall.state.wbR, g: wall.state.wbG, b: wall.state.wbB); measurementBase = original
        switch fixtureStep {
        case "result":
            reading = try? CalibrationMeasurement.solve(Array(repeating: [UInt8(172), 184, 178], count: 64 * 64).flatMap { $0 }, prior: original); step = .result
        case "dark": problem = CalibrationMeasurement.Failure.dark.localizedDescription
        case "clipped": problem = CalibrationMeasurement.Failure.clipped.localizedDescription
        case "denied": denied = true
        case "restricted": denied = true; restricted = true
        case "offline":
            reading = try? CalibrationMeasurement.solve(Array(repeating: [UInt8(172), 184, 178], count: 64 * 64).flatMap { $0 }, prior: original); step = .result
        default: break
        }
        return true
    }
    #endif
}

private enum CalibrationCameraOutcome {
    case captured(UIImage)
    case cancelled
    case failed(String)
}
private struct CalibrationCamera: UIViewControllerRepresentable {
    var onDone: (CalibrationCameraOutcome) -> Void
    func makeUIViewController(context: Context) -> CalibrationCameraController {
        let controller = CalibrationCameraController(); controller.onDone = onDone; return controller
    }
    func updateUIViewController(_ controller: CalibrationCameraController, context: Context) {}
}

/// Capture-session work stays off the main thread. The shutter is enabled only
/// once the session is running and custom daylight gains have been accepted.
private final class CalibrationCameraController: UIViewController, AVCapturePhotoCaptureDelegate {
    var onDone: ((CalibrationCameraOutcome) -> Void)?
    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "tessera.calibration.camera")
    private var camera: AVCaptureDevice?
    private var preview: AVCaptureVideoPreviewLayer?
    private let shutter = UIButton(type: .system)
    private let guide = CAShapeLayer()
    private var finished = false
    private let instruction = UILabel()
    private let exposure = UISlider()
    private var observers: [NSObjectProtocol] = []
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        let layer = AVCaptureVideoPreviewLayer(session: session); layer.videoGravity = .resizeAspectFill; view.layer.addSublayer(layer); preview = layer
        guide.strokeColor = UIColor.white.withAlphaComponent(0.85).cgColor; guide.fillColor = UIColor.clear.cgColor; guide.lineWidth = 2; view.layer.addSublayer(guide)
        instruction.text = "Face the panel squarely.\nKeep every LED below pure white."; instruction.textColor = .white; instruction.numberOfLines = 0; instruction.textAlignment = .center; instruction.font = .preferredFont(forTextStyle: .body); instruction.adjustsFontForContentSizeCategory = true
        instruction.backgroundColor = UIColor.black.withAlphaComponent(0.7); instruction.layer.cornerRadius = 14; instruction.clipsToBounds = true
        instruction.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(instruction)
        shutter.setImage(UIImage(systemName: "circle.inset.filled"), for: .normal); shutter.setPreferredSymbolConfiguration(.init(pointSize: 65), forImageIn: .normal); shutter.tintColor = .white; shutter.isEnabled = false; shutter.accessibilityLabel = "Photograph the panel"; shutter.accessibilityIdentifier = "calibration.shutter"; shutter.addTarget(self, action: #selector(capture), for: .touchUpInside)
        let cancel = UIButton(type: .system); cancel.setTitle("Back", for: .normal); cancel.titleLabel?.font = .preferredFont(forTextStyle: .headline); cancel.tintColor = .white; cancel.addTarget(self, action: #selector(back), for: .touchUpInside)
        let exposureLabel = UILabel(); exposureLabel.text = "Exposure. Lower it if the lights look blown out."; exposureLabel.textColor = .white; exposureLabel.numberOfLines = 0; exposureLabel.font = .preferredFont(forTextStyle: .caption1); exposureLabel.adjustsFontForContentSizeCategory = true
        exposure.minimumValue = -4; exposure.maximumValue = 0; exposure.value = -0.7; exposure.tintColor = UIColor(red: 0.87, green: 0.91, blue: 0.86, alpha: 1); exposure.accessibilityLabel = "Camera exposure"; exposure.addTarget(self, action: #selector(adjustExposure), for: .valueChanged)
        let controls = UIStackView(arrangedSubviews: [exposureLabel, exposure, shutter, cancel]); controls.axis = .vertical; controls.spacing = 10; controls.alignment = .fill; controls.translatesAutoresizingMaskIntoConstraints = false; controls.backgroundColor = UIColor.black.withAlphaComponent(0.75); controls.isLayoutMarginsRelativeArrangement = true; controls.directionalLayoutMargins = .init(top: 16, leading: 22, bottom: 8, trailing: 22); view.addSubview(controls)
        NSLayoutConstraint.activate([
            instruction.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16), instruction.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24), instruction.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24), instruction.heightAnchor.constraint(greaterThanOrEqualToConstant: 76),
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor), controls.trailingAnchor.constraint(equalTo: view.trailingAnchor), controls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor), shutter.heightAnchor.constraint(equalToConstant: 72), cancel.heightAnchor.constraint(greaterThanOrEqualToConstant: 44), exposure.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: .main) { [weak self] _ in
                self?.finish(.failed("The camera was interrupted. Return to the card and open it again when the camera is available."))
            })
        }
        queue.async { [weak self] in self?.configure() }
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    private func configure() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              device.isWhiteBalanceModeSupported(.locked) else { finish(.failed("This camera cannot lock white balance. Choose a photo, or use a supported rear camera.")); return }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input), session.canAddOutput(output) else { finish(.failed("The camera could not start. Close other camera apps and try again.")); return }
            session.beginConfiguration(); session.sessionPreset = .photo; session.addInput(input); session.addOutput(output); session.commitConfiguration(); camera = device
            try device.lockForConfiguration()
            let temperature = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: 6500, tint: 0)
            var gains = device.deviceWhiteBalanceGains(for: temperature)
            let maximum = device.maxWhiteBalanceGain
            gains.redGain = min(maximum, max(1, gains.redGain)); gains.greenGain = min(maximum, max(1, gains.greenGain)); gains.blueGain = min(maximum, max(1, gains.blueGain))
            if device.activeFormat.supportedColorSpaces.contains(.sRGB) { device.activeColorSpace = .sRGB }
            if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5) }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            device.setExposureTargetBias(max(device.minExposureTargetBias, min(device.maxExposureTargetBias, -0.7)))
            device.setWhiteBalanceModeLocked(with: gains) { [weak self] _ in
                DispatchQueue.main.async { guard let self, !self.finished else { return }; self.shutter.isEnabled = true }
            }
            device.unlockForConfiguration(); session.startRunning()
            if !session.isRunning { finish(.failed("The camera did not start. Close other camera apps and try again.")) }
        } catch { finish(.failed("The camera could not be configured. Check Camera access in Settings and try again.")) }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews(); preview?.frame = view.bounds
        let width = view.bounds.width * 0.76
        let rect = CGRect(x: (view.bounds.width - width) / 2, y: max(view.safeAreaInsets.top + 108, view.bounds.midY - width / 2 - 48), width: width, height: width)
        guide.path = UIBezierPath(roundedRect: rect, cornerRadius: 8).cgPath
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        queue.async { [session] in if session.isRunning { session.stopRunning() } }
    }
    @objc private func adjustExposure() {
        let value = exposure.value
        queue.async { [weak self] in
            guard let device = self?.camera else { return }
            do { try device.lockForConfiguration(); device.setExposureTargetBias(max(device.minExposureTargetBias, min(device.maxExposureTargetBias, value))); device.unlockForConfiguration() } catch { DispatchQueue.main.async { self?.instruction.text = "Exposure could not be adjusted. Return and open the camera again." } }
        }
    }
    @objc private func capture() {
        guard shutter.isEnabled, session.isRunning, !finished else { return }
        shutter.isEnabled = false
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }
    @objc private func back() { finish(.cancelled) }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else { finish(.failed("The camera did not return a usable photo. Take another shot.")); return }
        finish(.captured(image))
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if error != nil { finish(.failed("The capture was interrupted. Open the camera and take another shot.")) }
    }
    private func finish(_ result: CalibrationCameraOutcome) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.finished else { return }; self.finished = true; self.onDone?(result)
        }
    }
}
