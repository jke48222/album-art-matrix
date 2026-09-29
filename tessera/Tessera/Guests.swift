import SwiftUI

struct GuestsPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.scenePhase) private var scene
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let accent: Color
    @AppStorage("guests.ssid") private var ssid = ""
    @State private var password = ""
    @State private var link = ""
    @State private var kind = "wifi"
    @State private var security = GuestCodeInput.Security.password
    @State private var hidden = false
    @State private var seconds = 120.0
    @State private var display = TemporaryWallDisplay()
    @State private var code: GuestQRCode?
    // Built once per code, not on every body pass. Both carry the password's
    // modules, so they are cleared with the rest of the private draft.
    @State private var codeImage: CGImage?
    @State private var presentedImage: CGImage?
    @State private var presentedName = ""
    @State private var layoutSide = Panel.side
    @State private var closesAt: Date?
    @State private var timedOut = false
    // The page has seen its guest code on the wall and has not hidden it, so
    // a code that leaves the wall on its own can be explained.
    @State private var upHere = false
    // A refused Show or Hide, kept here until the person acts. The poll
    // loop's refresh() clears display.problem once the wall agrees, which
    // would otherwise wipe the reason within seconds.
    @State private var failure: String?
    @State private var failedWhileShowing = false
    @State private var notice: String?
    @State private var validation: String?
    // The input is valid but its code is larger than the wall, so no amount
    // of waiting brings a preview. The ticket says so instead of promising one.
    @State private var tooLarge = false
    @State private var sourceHost = ""
    // Font.custom scales with .body, and so does this, so a symbol sized
    // through glyph() keeps its proportion to the Switzer label beside it.
    @ScaledMetric(relativeTo: .body) private var bodyScale: CGFloat = 17
    #if DEBUG
    @State private var autoShown = false
    #endif
    @FocusState private var field: Field?
    private enum Field { case ssid, password, link }
    private let sand = Color(hex: 0xD9B78E)
    private let paper = Color(hex: 0xF4ECDD)
    private let dark = Color(hex: 0x302B24)
    // Offline, the last receipt never updates, so the wall's own timer is
    // tracked here and the code stops claiming the wall once it has run out.
    private var showing: Bool { display.active && display.purpose == "guests" && !timedOut }
    private var available: Bool { wall.link.isLive }
    private var editing: Bool { !showing && !display.busy }
    private var name: String {
        kind == "wifi" ? (ssid.isEmpty ? "Guest Wi-Fi" : ssid) : (GuestCodeInput.url(link)?.host ?? "Link")
    }
    private var ticketName: String { showing ? (presentedName.isEmpty ? "Your guest code" : presentedName) : name }
    private var visibleImage: CGImage? { showing ? presentedImage : codeImage }
    private var canShow: Bool {
        available && !display.busy && code != nil && !display.active && display.occupiedBy == nil
    }
    /// Why Show can't be pressed, said under the button so a dimmed button
    /// is never the only answer. What the person can do next comes first.
    private var showBlocker: String? {
        guard !canShow, !display.busy, !showing else { return nil }
        if code == nil {
            if let validation { return validation }
            if kind == "link" { return "Enter a website address below." }
            if ssid.isEmpty {
                return security == .password ? "Enter a network name and password below." : "Enter a network name below."
            }
            return "Enter the Wi-Fi password below."
        }
        if !available { return "Reconnect to the wall to show this code." }
        if display.occupiedBy != nil { return "Another check is using the wall. Show the code once it ends." }
        if display.active { return "The last guest code is still closing on the wall. Try again in a moment." }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: typeSize.isAccessibilitySize ? 18 : 24) {
                introduction
                if !available {
                    message("Your wall is offline", "You can prepare a code here. Reconnect to the wall to put it up or take it down.", symbol: "wifi.slash")
                }
                // Offline, refresh() cannot run, so occupiedBy may be stale.
                if available, let other = display.occupiedBy {
                    message("The wall is in use", occupiedDetail(other), symbol: "square.dashed")
                        .accessibilityIdentifier("guests.occupied")
                }
                sharingKind
                if typeSize.isAccessibilitySize { wallControls }
                ticket
                if !typeSize.isAccessibilitySize { wallControls }
                // Only a Show or Hide from this page is reported here. A
                // takeover is told by the in-use message and the notice.
                if let failure {
                    message("The wall didn't confirm", failure, symbol: "exclamationmark.circle")
                        .accessibilityIdentifier("guests.problem")
                    Button("Check wall status", systemImage: "arrow.clockwise") {
                        // Asking the wall again is acting on the message.
                        self.failure = nil
                        Task { await display.refresh(on: wall, adopting: "guests") }
                    }.font(.ui(15, .semibold)).frame(minHeight: 44).disabled(!available || display.busy)
                        .accessibilityIdentifier("guests.retry")
                }
                if let notice {
                    Label(notice, systemImage: "checkmark.circle").font(.ui(14, .medium)).foregroundStyle(sand)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("guests.notice")
                }
                if !showing { editor; duration }
                privacy
            }.padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 44)
        }
        .scrollIndicators(.hidden).scrollDismissesKeyboard(.interactively)
        .background(Color(hex: 0x171511)).foregroundStyle(Ink.ink).tint(sand)
        .navigationTitle("Guests").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { field = nil }
            }
        }
        .task(id: "\(wall.host)|\(scene)") {
            guard scene == .active else { return }
            if sourceHost != wall.host {
                sourceHost = wall.host; clearPrivateDraft(); display = TemporaryWallDisplay()
                failure = nil; upHere = false
            }
            seedFixture()
            refreshCode()
            while !Task.isCancelled {
                // The wall states its size in /state, which can land after
                // this page opened. The code is laid out for that size.
                if layoutSide != Panel.side { refreshCode() }
                // Read before refresh() can drop the receipt it came from.
                let deadline = closesAt
                await display.refresh(on: wall, adopting: "guests")
                let over = display.active && display.purpose == "guests" && (closesAt.map { $0 <= .now } ?? false)
                if over != timedOut { timedOut = over }
                // While a Show or Hide is on its way the state is in motion,
                // and that action reports its own outcome.
                if !display.busy {
                    // The code left the wall without a hide from here. Online
                    // the wall's idle answer usually lands before the phone's
                    // own deadline, so the reason is given here, not only
                    // when the offline timer runs out.
                    if upHere, !showing {
                        if display.occupiedBy != nil {
                            notice = "Another check took over the wall, so the guest code has closed."
                        } else if over || (deadline.map { $0 <= .now.addingTimeInterval(5) } ?? false) {
                            notice = "Time is up. The wall has taken the guest code down."
                        } else {
                            notice = "The guest code has closed on the wall."
                        }
                    }
                    // A code that appears without a Show from here (adopted,
                    // or back after a timeout) makes a closing notice stale.
                    if showing, !upHere { notice = nil }
                    upHere = showing
                    // The wall now reports what the failed action asked for:
                    // a start whose reply was lost did land, or a code whose
                    // hide failed has since left the wall.
                    if failure != nil, showing != failedWhileShowing { failure = nil }
                }
                if !showing { presentedImage = nil; presentedName = "" }
                #if DEBUG
                if !autoShown, ProcessInfo.processInfo.arguments.contains("-guests-show"), canShow {
                    autoShown = true; showCode()
                }
                #endif
                try? await Task.sleep(for: .seconds(showing ? 2 : 5))
            }
        }
        .onChange(of: display.secondsRemaining) { _, remaining in
            closesAt = remaining.map { Date.now.addingTimeInterval(max(0, $0)) }
        }
        // /state can report the wall's size between two passes of the loop.
        // Re-lay the code as soon as it does, so a fresh install never
        // previews the 192 layout on a 64 wall.
        .onChange(of: wall.lastSync) { if layoutSide != Panel.side { refreshCode() } }
        // An edit is the person acting on a failure, so it goes.
        .onChange(of: ssid) { failure = nil; refreshCode() }
        .onChange(of: password) { if scene == .active { failure = nil }; refreshCode() }
        .onChange(of: link) { if scene == .active { failure = nil }; refreshCode() }
        .onChange(of: kind) { notice = nil; failure = nil; refreshCode() }
        .onChange(of: security) { password = ""; failure = nil; refreshCode() }
        .onChange(of: hidden) { failure = nil; refreshCode() }
        .onChange(of: seconds) { failure = nil }
        .onChange(of: scene) { _, next in if next != .active { clearPrivateDraft() } }
        .onDisappear { clearPrivateDraft() }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: typeSize.isAccessibilitySize ? 10 : 16) {
            Label("Guest Wi-Fi and links", systemImage: "door.left.hand.open")
                .font(.ui(typeSize.isAccessibilitySize ? 9 : 13, .medium)).foregroundStyle(sand)
            if !typeSize.isAccessibilitySize {
                HStack(alignment: .center, spacing: 18) {
                    Text("Share with guests").font(.display(43)).tracking(-0.8).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    GuestDoor(tint: sand).frame(width: 51, height: 62).accessibilityHidden(true)
                }
                Text("Show your Wi-Fi or a link as a QR code on the wall.")
                    .font(.ui(15)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var sharingKind: some View {
        HStack(spacing: 6) {
            kindButton("Wi-Fi", value: "wifi", symbol: "wifi")
            kindButton("A link", value: "link", symbol: "link")
        }.padding(5).background(Ink.sunk, in: RoundedRectangle(cornerRadius: 16)).disabled(!editing)
    }

    private func kindButton(_ title: String, value: String, symbol: String) -> some View {
        // Locked while a code is up. Its own quieter colours say so, and
        // stay readable (5.0 and 4.7:1), where a fade fell to 2.3:1.
        let selected = kind == value
        return Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { kind = value }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(glyph(typeSize.isAccessibilitySize ? 11.5 : 17))
                Text(title).font(.ui(typeSize.isAccessibilitySize ? 10 : 15, .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(selected ? (editing ? paper : Ink.dim) : (editing ? Ink.dim : Ink.faint))
                .background(selected ? Color(hex: editing ? 0x343027 : 0x24211B) : .clear, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(GuestPress()).accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("guests.kind.\(value)")
    }

    /// A symbol sized like Switzer text of the same point size.
    private func glyph(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size * bodyScale / 17, weight: weight)
    }

    private var ticket: some View {
        VStack(spacing: typeSize.isAccessibilitySize ? 14 : 18) {
            VStack(spacing: 6) {
                Text(showing ? "ON YOUR WALL" : "PREVIEW")
                    .font(.machine(typeSize.isAccessibilitySize ? 8 : 9)).tracking(0.8).foregroundStyle(dark.opacity(0.72))
                Text(ticketName)
                    .font(.ui(typeSize.isAccessibilitySize ? 12 : 21, .semibold)).foregroundStyle(dark)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            if let image = visibleImage {
                // The wall's own frame, one image pixel per LED. The label
                // names the network or site and never the password.
                Image(image, scale: 1, label: Text("QR code for \(ticketName)")).resizable().interpolation(.none)
                    .frame(width: typeSize.isAccessibilitySize ? 160 : 192, height: typeSize.isAccessibilitySize ? 160 : 192)
                    .background(.white)
                    .accessibilityIdentifier("guests.code")
            } else {
                // A code too large for the wall never arrives, so the card
                // says that. Why, and what to change, sits under Show.
                let blocked = !showing && tooLarge
                VStack(spacing: 14) {
                    Image(systemName: showing ? "eye.slash" : (blocked ? "exclamationmark.circle" : "qrcode"))
                        .font(.system(size: 40, weight: .ultraLight)).accessibilityHidden(true)
                    Text(showing ? "Code is on the wall" : (blocked ? "Too long for this wall" : "Your code appears here"))
                        .font(.ui(typeSize.isAccessibilitySize ? 11 : 14, .medium)).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }.foregroundStyle(dark.opacity(0.8)).frame(maxWidth: .infinity, minHeight: typeSize.isAccessibilitySize ? 112 : 132)
            }
            // Only a code there is to scan gets the scan caption.
            if showing || visibleImage != nil {
                Rectangle().fill(dark.opacity(0.15)).frame(height: 1)
                Label(showing ? "Point a camera at your wall" : (kind == "wifi" ? "Scan to join the network" : "Scan to open the link"), systemImage: "camera")
                    .font(.ui(typeSize.isAccessibilitySize ? 11 : 13, .medium)).foregroundStyle(dark.opacity(0.8))
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(22).frame(maxWidth: .infinity)
            .background(paper, in: RoundedRectangle(cornerRadius: 22))
            .overlay(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 1).fill(sand).frame(width: 26, height: 4).padding(.leading, 22).padding(.top, 0)
            }.accessibilityElement(children: .contain).accessibilityIdentifier("guests.ticket")
    }

    private var wallControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showing {
                (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))) {
                    Label("Showing on the wall", systemImage: "checkmark.circle.fill")
                        .font(.ui(typeSize.isAccessibilitySize ? 10 : 14, .medium)).fixedSize(horizontal: false, vertical: true)
                    if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                    if let closesAt {
                        // Counts down from the wall's last receipt, so it keeps
                        // moving while the phone is offline.
                        TimelineView(.periodic(from: .now, by: 10)) { context in
                            Text("\(Int(ceil(max(0, closesAt.timeIntervalSince(context.date)) / 60))) min left")
                                .font(.machine(10)).foregroundStyle(Ink.dim)
                        }
                    }
                }.foregroundStyle(sand).accessibilityIdentifier("guests.showing")
                action("Hide guest code", symbol: "eye.slash", enabled: available && !display.busy, id: "guests.hide") {
                    field = nil
                    failure = nil
                    Task {
                        if await display.end(on: wall) {
                            presentedImage = nil; presentedName = ""; upHere = false
                            notice = "Guest code removed. Your wall is back to its previous view."
                            Taps.commit()
                        } else {
                            recordFailure()
                            // A refused hide that already ended the session
                            // (it changed on the wall) is explained by the
                            // failure, so no second notice follows.
                            if !showing { upHere = false }
                        }
                    }
                }
            } else {
                action("Show on wall", symbol: "arrow.up.right", enabled: canShow, id: "guests.show") { showCode() }
                if let showBlocker {
                    Label(showBlocker, systemImage: "info.circle")
                        .font(.ui(typeSize.isAccessibilitySize ? 10 : 13, .medium)).foregroundStyle(sand)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("guests.showReason")
                }
                Text("Closes after \(Int(seconds / 60)) \(seconds == 60 ? "minute" : "minutes") and returns to your previous view.")
                    .font(.ui(typeSize.isAccessibilitySize ? 9 : 12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func action(_ title: String, symbol: String, enabled: Bool, id: String, perform: @escaping () -> Void) -> some View {
        // Disabled gets its own colours, not a fade. Fading the label and the
        // sand fill separately drew them together at about 1:1, so the words
        // vanished. Here the label is 4.5:1 on a dark fill with a hairline.
        let lit = enabled || display.busy
        return Button(action: perform) {
            HStack(spacing: 12) {
                if display.busy { ProgressView().tint(dark) } else { Image(systemName: symbol).font(glyph(typeSize.isAccessibilitySize ? 14 : 19)) }
                Text(display.busy ? "Waiting for the wall…" : title).font(.ui(typeSize.isAccessibilitySize ? 11 : 15, .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.padding(.horizontal, 18).padding(.vertical, 15).frame(maxWidth: .infinity, minHeight: 52)
                .foregroundStyle(lit ? dark : Ink.dim)
                .background(lit ? sand : Color(hex: 0x2E2922), in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    if !lit { RoundedRectangle(cornerRadius: 14).strokeBorder(Ink.hairline, lineWidth: 1) }
                }
        }.buttonStyle(GuestPress()).disabled(!enabled).accessibilityIdentifier(id)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(kind == "wifi" ? "The network" : "The destination").font(.ui(22, .semibold))
            if kind == "wifi" {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Network name").font(.ui(13, .medium)).foregroundStyle(Ink.dim)
                    TextField("As shown in Wi-Fi settings", text: $ssid)
                        .textContentType(.none).focused($field, equals: .ssid).submitLabel(.next)
                        .onSubmit { field = security == .password ? .password : nil }
                        .accessibilityIdentifier("guests.ssid").modifier(GuestField())
                }
                if typeSize.isAccessibilitySize {
                    VStack(spacing: 8) {
                        securityChoice("Password protected", value: .password)
                        securityChoice("Open network", value: .open)
                    }.accessibilityIdentifier("guests.security")
                } else {
                    Picker("Network security", selection: $security) {
                        Text("Password").tag(GuestCodeInput.Security.password)
                        Text("Open network").tag(GuestCodeInput.Security.open)
                    }.pickerStyle(.segmented).accessibilityIdentifier("guests.security")
                }
                if security == .password {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Wi-Fi password").font(.ui(13, .medium)).foregroundStyle(Ink.dim)
                        SecureField("Password for this network", text: $password)
                            .textContentType(.password).focused($field, equals: .password).submitLabel(.done)
                            .onSubmit { field = nil }.accessibilityIdentifier("guests.password").modifier(GuestField())
                        Text("For personal WPA and WPA2 networks. The password is cleared when you leave this page or switch apps.")
                            .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Anyone nearby can join an open network without a password.")
                        .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                }
                Toggle(isOn: $hidden) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hidden network").font(.ui(15, .medium))
                        Text("Its name isn't broadcast.").font(.ui(12)).foregroundStyle(Ink.dim)
                    }
                }.tint(sand).accessibilityIdentifier("guests.hidden")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Website address").font(.ui(13, .medium)).foregroundStyle(Ink.dim)
                    TextField("https://…", text: $link).keyboardType(.URL).textContentType(.URL)
                        .focused($field, equals: .link).submitLabel(.done).onSubmit { field = nil }
                        .accessibilityIdentifier("guests.url").modifier(GuestField())
                    Text("Use a full http:// or https:// address. Shorter links make room for larger QR modules.")
                        .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let validation {
                Label(validation, systemImage: "info.circle").font(.ui(13)).foregroundStyle(sand)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("guests.validation")
            }
        }.disabled(!editing)
    }

    private func securityChoice(_ title: String, value: GuestCodeInput.Security) -> some View {
        Button { security = value } label: {
            HStack(spacing: 12) {
                Text(title).font(.ui(11, .medium)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: security == value ? "checkmark.circle.fill" : "circle")
                    .font(glyph(12.5))
            }.padding(14).frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(security == value ? sand : Ink.dim)
                .background(Ink.plaster, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityAddTraits(security == value ? .isSelected : [])
    }

    private var duration: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Leave it up for").font(.ui(15, .medium))
            (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))) {
                ForEach([60.0, 120.0, 300.0], id: \.self) { value in
                    Button {
                        seconds = value
                    } label: {
                        HStack(spacing: 8) {
                            Text("\(Int(value / 60)) \(value == 60 ? "minute" : "minutes")").font(.ui(13, .medium))
                            if seconds == value { Image(systemName: "checkmark").font(glyph(11, .semibold)) }
                        }.frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(seconds == value ? sand : Ink.dim)
                            .background(seconds == value ? sand.opacity(0.12) : Ink.plaster, in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).accessibilityAddTraits(seconds == value ? .isSelected : [])
                        .accessibilityIdentifier("guests.duration.\(Int(value))")
                }
            }
        }.disabled(!editing)
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(Ink.hairline).frame(height: 1)
            Label("Privacy", systemImage: "hand.raised")
                .font(.ui(13, .medium)).foregroundStyle(sand)
            Text("The QR contains the network password or link. Anyone who can see it can scan it. Tessera sends the code as pixels, keeps it temporarily in the wall's memory, and never saves it to your creations.")
                .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            Text("If a camera struggles with the LEDs, scan the code on this phone instead. It is the same frame the wall shows.")
                .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func message(_ title: String, _ detail: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.ui(15, .semibold)).foregroundStyle(sand)
            Text(detail).font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func occupiedDetail(_ purpose: String) -> String {
        switch purpose {
        case "calibration": return "True colour is running a check on the wall. Finish it before showing a guest code."
        case "panel": return "Panel check is showing a test pattern on the wall. Finish it before showing a guest code."
        case "onboarding": return "First run is using the wall for a moment. Try again when it is done."
        // Seen for one poll only: while this page still holds its own
        // expired code, refresh() reports another phone's code as occupying.
        // The next refresh adopts it, and it can then be hidden from here.
        case "guests": return "A guest code from another phone is on the wall. It closes by itself when its time is up."
        case "identify": return "A short glow is on the wall. Try again in a few seconds."
        case "tuning": return "Panel tuning is showing a test pattern on the wall. Choose Your wall there before showing a guest code."
        default: return "Another check is showing on the wall. Finish it before showing a guest code."
        }
    }

    private func showCode() {
        if code?.side != Panel.side { refreshCode() }
        guard let code else { return }
        field = nil
        let title = name, host = wall.host
        notice = nil
        failure = nil
        Task {
            let shown = await display.show(on: wall, pixels: code.frame(), purpose: "guests", seconds: seconds)
            if shown, scene == .active, wall.host == host {
                presentedImage = code.image(); presentedName = title; upHere = true; Taps.commit()
            } else if !shown {
                recordFailure()
            }
        }
    }

    /// Keeps the reason a Show or Hide failed, and whether the code was up
    /// at that moment, so the loop can tell when the wall later agrees.
    private func recordFailure() {
        failure = display.problem ?? "The wall could not make this change. Try again."
        failedWhileShowing = showing
    }

    private func refreshCode() {
        code = nil; codeImage = nil; validation = nil; tooLarge = false; layoutSide = Panel.side
        let payload: String
        if kind == "wifi" {
            guard GuestCodeInput.wifiProblem(ssid: ssid, password: password, security: security) == nil else {
                if !ssid.isEmpty && (!password.isEmpty || security == .open || ssid.utf8.count > 32) {
                    validation = GuestCodeInput.wifiProblem(ssid: ssid, password: password, security: security)
                }
                return
            }
            payload = GuestCodeInput.wifi(ssid: ssid, password: password, security: security, hidden: hidden)
        } else {
            guard let url = GuestCodeInput.url(link) else {
                if !link.isEmpty { validation = "Enter a full http:// or https:// address without a username, password or spaces." }
                return
            }
            payload = url.absoluteString
        }
        code = GuestQRCode(payload: payload, side: Panel.side)
        codeImage = code?.image()
        if code == nil {
            tooLarge = true
            validation = kind == "wifi"
                ? "This code needs more space than your wall has. Use a shorter network name or password."
                : "This code needs more space than your wall has. Use a shorter link."
        }
    }

    private func clearPrivateDraft() {
        password = ""; link = ""; code = nil; codeImage = nil; presentedImage = nil; presentedName = ""; field = nil
    }

    #if DEBUG
    /// "-guests.ssid ''" as a launch argument would pin the saved name to ""
    /// for the whole run, so typing and fixtures could never set it. Tests
    /// ask for one reset instead.
    nonisolated(unsafe) private static var resetDone = false
    #endif

    private func seedFixture() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if !Self.resetDone, args.contains("-guests-reset") { Self.resetDone = true; ssid = "" }
        guard let index = args.firstIndex(of: "-guests-fixture"), args.indices.contains(index + 1) else { return }
        switch args[index + 1] {
        case "wifi": ssid = "Tessera guest"; password = "A good evening"; security = .password; hidden = false
        case "hidden": ssid = "Tessera guest"; password = "A good evening"; security = .password; hidden = true
        case "open": ssid = "Tessera guest"; security = .open; password = ""
        case "dense": ssid = "Tessera guest room upstairs"; password = "A good evening with friends"; security = .password; hidden = false
        case "link": kind = "link"; link = "https://example.com/hello"
        case "long": kind = "link"; link = "https://example.com/" + String(repeating: "tessera", count: 110)
        default: break
        }
        #endif
    }
}

/// Press feedback only. Unlike .plain it adds no fade of its own when the
/// button is disabled, so each control can set a disabled look that stays
/// readable. The group keeps a pressed label and fill fading as one.
private struct GuestPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(Rectangle())
            .compositingGroup().opacity(configuration.isPressed ? 0.78 : 1)
    }
}

private struct GuestField: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.ui(15)).foregroundStyle(Ink.ink).textInputAutocapitalization(.never).autocorrectionDisabled()
            .padding(16).frame(minHeight: 50).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.hairline, lineWidth: 1))
    }
}

private struct GuestDoor: View {
    let tint: Color
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let frame = CGRect(x: w * 0.1, y: h * 0.05, width: w * 0.68, height: h * 0.88)
            context.stroke(Path(roundedRect: frame, cornerRadius: 3), with: .color(tint.opacity(0.3)), lineWidth: 1.2)
            var door = Path()
            door.move(to: CGPoint(x: w * 0.13, y: h * 0.07))
            door.addLine(to: CGPoint(x: w * 0.6, y: h * 0.23))
            door.addLine(to: CGPoint(x: w * 0.6, y: h * 0.79))
            door.addLine(to: CGPoint(x: w * 0.13, y: h * 0.91)); door.closeSubpath()
            context.fill(door, with: .color(tint.opacity(0.13)))
            context.stroke(door, with: .color(tint), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
            context.fill(Path(ellipseIn: CGRect(x: w * 0.46, y: h * 0.52, width: 3, height: 3)), with: .color(tint))
        }
    }
}
