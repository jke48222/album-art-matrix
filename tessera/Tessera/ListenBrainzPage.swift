import SwiftUI

/// Public playback follows a username. Vinyl listens belong to the token’s account.
struct ListenBrainzPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.scenePhase) private var scene
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let accent: Color
    @Binding var services: WallServices?

    @State private var user = ""
    @State private var token = ""
    @State private var busy = false
    @State private var checked = false
    @State private var readFailed = false
    @State private var readExpanded = false
    @State private var writeExpanded = false
    @State private var unlink: String?
    @State private var problem: String?
    @State private var notice: String?
    @State private var request: Task<Void, Never>?
    @State private var operation = UUID()
    @State private var sourceHost = ""
    @FocusState private var focus: Field?
    private enum Field: Hashable { case username, token }
    private let amber = Color(hex: 0xEABB8B)
    private let paper = Color(hex: 0xEEDCCA)
    private var lb: WallServices.Listenbrainz? { services?.listenbrainz }
    private var savedUser: String { lb?.user ?? "" }
    private var tokenSet: Bool { lb?.token_set == true }
    private var available: Bool { wall.link.isLive && checked && !readFailed && lb != nil }
    private var typedUser: String { user.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var typedToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSaveUser: Bool {
        available && !busy && typedUser != savedUser
            && typedUser.range(of: "^[^\\s/]{1,64}$", options: .regularExpression) != nil
    }
    private var canSaveToken: Bool { available && !busy && UUID(uuidString: typedToken) != nil }
    private var writerState: String { lb?.state ?? (tokenSet ? "checking" : "unlinked") }
    private var readerState: String { lb?.read_state ?? (savedUser.isEmpty ? "unlinked" : "checking") }
    private var current: WallServices.Listenbrainz.Playing? { available ? lb?.playing : nil }
    private var journalTitle: String {
        if !available { return checked ? "Waiting for the wall" : "Opening your journal" }
        if let current {
            if current.listened { return (lb?.queued ?? 0) > 0 ? "Counted. Waiting to send." : "A listen to remember." }
            return lb?.counting == true ? "A record is becoming\na memory." : "A moment of quiet."
        }
        return tokenSet ? "The next record\nstarts here." : "Keep what\nyou listen to."
    }
    private var writerTitle: String {
        guard available else { return "Not checked" }
        switch writerState {
        case "ready": return "Writing as \(lb?.user_name ?? "your account")"
        case "refused": return "Token needs replacing"
        case "offline": return "Waiting for the network"
        case "rate_limited": return "Waiting for ListenBrainz"
        case "unavailable": return "Connection needs attention"
        case "disabled": return "Writing is off on this wall"
        case "checking": return "Checking the token"
        default: return "Writing is off"
        }
    }
    private var readerTitle: String {
        guard available else { return "Not checked" }
        switch readerState {
        case "playing": return "Following \(savedUser)"
        case "ready": return "Ready for \(savedUser)’s next song"
        case "refused": return "Username needs attention"
        case "offline", "unavailable": return "Listening status unavailable"
        case "rate_limited": return "Waiting for ListenBrainz"
        case "checking": return "Checking the username"
        default: return "No username connected"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                journal
                if let problem { feedback(problem, symbol: "exclamationmark.circle") }
                if let notice { feedback(notice, symbol: "checkmark.circle") }
                if !available {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Your details stay saved on the wall.").font(.ui(16, .semibold)).foregroundStyle(Ink.ink)
                        Text("Reconnect to read the journal or change this connection.").font(.ui(14)).foregroundStyle(Ink.dim)
                        Button("Check the wall again", systemImage: "arrow.clockwise") { Task { await refresh(host: wall.host) } }
                            .font(.ui(15, .semibold)).foregroundStyle(amber).frame(minHeight: 44)
                            .accessibilityIdentifier("listenbrainz.wallRetry")
                    }.fixedSize(horizontal: false, vertical: true)
                }
                reading
                writing
                if available && (lb?.last_listen != nil || (lb?.queued ?? 0) > 0 || (lb?.held_queued ?? 0) > 0) { history }
                VStack(alignment: .leading, spacing: 9) {
                    Text("Your music. An open history.").font(.ui(16, .semibold)).foregroundStyle(Ink.ink)
                    Text("ListenBrainz is the open listening journal from the MusicBrainz community. Reading and writing can use different accounts.")
                        .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                    Link("Explore ListenBrainz", destination: URL(string: "https://listenbrainz.org/")!)
                        .font(.ui(14, .medium)).foregroundStyle(amber).frame(minHeight: 44)
                }
            }.padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 38)
        }.background(Ink.ground).scrollIndicators(.hidden).scrollDismissesKeyboard(.interactively)
            .navigationTitle("ListenBrainz").navigationBarTitleDisplayMode(.inline).tint(amber)
            .refreshable { await refresh(host: wall.host) }
            .task(id: "\(wall.host)|\(scene == .active)") {
                guard scene == .active else { return }
                let host = wall.host
                if sourceHost != host {
                    sourceHost = host; checked = false; readFailed = false
                    user = savedUser; token = ""
                }
                while !Task.isCancelled {
                    if !busy { await refresh(host: host) }
                    do { try await Task.sleep(for: .seconds(3)) } catch { break }
                }
            }
            .onChange(of: savedUser) { old, value in if user.isEmpty || user == old { user = value } }
            .onChange(of: wall.host) { _, _ in cancel(); services = nil; user = ""; token = ""; checked = false; notice = nil; problem = nil; unlink = nil }
            .onChange(of: scene) { _, next in if next != .active { cancel(); token = ""; focus = nil } }
            .onDisappear { cancel(); token = "" }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: readExpanded)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: writeExpanded)
    }

    private var journal: some View {
        VStack(alignment: .leading, spacing: typeSize.isAccessibilitySize ? 14 : 24) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "waveform").font(.system(size: 23, weight: .medium)).accessibilityHidden(true)
                Text(typeSize.isAccessibilitySize ? "Listening journal" : "THE LISTENING JOURNAL")
                    .font(typeSize.isAccessibilitySize ? .ui(12, .medium) : .machine(9))
                    .tracking(typeSize.isAccessibilitySize ? 0 : 1.4)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.foregroundStyle(amber)
            if !typeSize.isAccessibilitySize {
                Text(journalTitle).font(.display(37)).tracking(-0.5).foregroundStyle(paper)
                    .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            }
            if let current {
                VStack(alignment: .leading, spacing: 10) {
                    Text(current.title).font(.ui(typeSize.isAccessibilitySize ? 16 : 21, .semibold)).foregroundStyle(paper).fixedSize(horizontal: false, vertical: true)
                    Text(current.artist).font(.ui(typeSize.isAccessibilitySize ? 12 : 14)).foregroundStyle(paper.opacity(0.72))
                    countMeter(current)
                    Label(current.listened ? "Listen counted" : lb?.counting == true ? (typeSize.isAccessibilitySize ? "Counting room audio" : "Counting sound in the room") : (typeSize.isAccessibilitySize ? "Counting paused" : "Counting paused while the room is quiet"),
                          systemImage: current.listened ? "checkmark.circle" : lb?.counting == true ? "waveform" : "pause.circle")
                        .font(.ui(12, .medium)).foregroundStyle(amber).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("listenbrainz.countingState")
                }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    if !typeSize.isAccessibilitySize { journalMotif }
                    VStack(alignment: .leading, spacing: 7) {
                        Text(typeSize.isAccessibilitySize ? journalTitle.replacingOccurrences(of: "\n", with: " ") : "Every record leaves a little trace.")
                            .font(.ui(15, .semibold)).foregroundStyle(paper).fixedSize(horizontal: false, vertical: true)
                        Text(available ? "Follow a player’s reports, or keep the records the wall hears." : "Listening status appears when your wall answers.")
                            .font(.ui(13)).foregroundStyle(paper.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }.padding(typeSize.isAccessibilitySize ? 20 : 24).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(hex: 0x30241F), in: RoundedRectangle(cornerRadius: 25))
            .overlay(RoundedRectangle(cornerRadius: 25).strokeBorder(amber.opacity(0.14), lineWidth: 1))
    }

    private var journalMotif: some View {
        ZStack {
            ForEach(0..<5) { i in
                Circle().stroke(amber.opacity(0.15 + Double(i) * 0.09), lineWidth: 1)
                    .frame(width: CGFloat(54 - i * 9), height: CGFloat(54 - i * 9))
            }
            Circle().fill(amber).frame(width: 5, height: 5)
        }.frame(width: 58, height: 58).accessibilityHidden(true)
    }

    private func countMeter(_ playing: WallServices.Listenbrainz.Playing) -> some View {
        let fraction = min(1, max(0, Double(playing.heard_s) / Double(max(1, playing.needs_s))))
        return VStack(alignment: .leading, spacing: 10) {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    Text(duration(playing.heard_s)).font(.machine(19)).monospacedDigit().foregroundStyle(paper)
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    Text("of \(duration(playing.needs_s)) to count").font(.ui(11)).foregroundStyle(paper.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(duration(playing.heard_s)).font(.machine(33)).monospacedDigit().foregroundStyle(paper)
                        .lineLimit(1).minimumScaleFactor(0.65)
                    Text("/ \(duration(playing.needs_s)) to count").font(.ui(12)).foregroundStyle(paper.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(amber.opacity(0.14))
                    Capsule().fill(amber).frame(width: geometry.size.width * fraction)
                }
            }.frame(height: 5)
        }.padding(.top, 8).padding(.bottom, 5)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(playing.heard_s) seconds heard of \(playing.needs_s) seconds needed")
            .accessibilityIdentifier("listenbrainz.countedTime")
    }

    private var reading: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeading("01", "Reading", "Bring a player’s song to the wall.")
            Label(readerTitle, systemImage: readerState == "playing" ? "waveform" : readerState == "ready" ? "checkmark.circle" : "person.crop.circle")
                .font(.ui(15, .medium)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
            if available, let track = lb?.read_playing {
                VStack(alignment: .leading, spacing: 5) {
                    Text(track.title).font(.ui(17, .semibold)).foregroundStyle(Ink.ink)
                    Text(track.artist).font(.ui(13)).foregroundStyle(Ink.dim)
                }.fixedSize(horizontal: false, vertical: true)
            }
            if available, let why = lb?.read_problem { feedback(why, symbol: "exclamationmark.circle") }
            if available && ["refused", "offline", "unavailable", "rate_limited"].contains(readerState) { retryButton }
            DisclosureGroup(isExpanded: $readExpanded) {
                VStack(alignment: .leading, spacing: 13) {
                    Text("A username reads public now-playing reports. No token is needed.").font(.ui(13)).foregroundStyle(Ink.dim)
                    TextField("ListenBrainz username", text: $user).font(.ui(16)).foregroundStyle(Ink.ink)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.username)
                        .submitLabel(.done).focused($focus, equals: .username).onSubmit { if canSaveUser { save(["user": typedUser], label: "Username saved.") } }
                        .padding(15).background(Ink.ground, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("listenbrainz.username")
                    primary("Save username", enabled: canSaveUser, id: "listenbrainz.saveUsername") { save(["user": typedUser], label: "Username saved.") }
                }.padding(.top, 14)
            } label: { Text(savedUser.isEmpty ? "Add a username" : "Change username").font(.ui(14, .semibold)).foregroundStyle(amber).accessibilityIdentifier("listenbrainz.readSetup") }
            if !savedUser.isEmpty {
                if unlink == "user" { unlinkConfirmation("Stop following this username?", detail: "Writing records stays connected.", field: "user") }
                else { Button("Stop following", role: .destructive) { unlink = "user" }.font(.ui(13)).frame(minHeight: 44).disabled(!available || busy).accessibilityIdentifier("listenbrainz.unlinkRead") }
            }
        }.padding(20).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 21))
    }

    private var writing: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeading("02", "Writing", "Keep the vinyl the wall recognizes.")
            Label(writerTitle, systemImage: lb?.valid == true ? "checkmark.circle" : "pencil.line")
                .font(.ui(15, .medium)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
            Text("Only sound recognized by the wall’s ears is written. A listen counts after half the track or four minutes, whichever comes first.")
                .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            if available, let why = lb?.problem { feedback(why, symbol: "exclamationmark.circle") }
            if available && ["refused", "offline", "unavailable", "rate_limited"].contains(writerState) { retryButton }
            DisclosureGroup(isExpanded: $writeExpanded) {
                VStack(alignment: .leading, spacing: 13) {
                    Text("Your user token writes to its own account. It never changes the username above.")
                        .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                    SecureField(tokenSet ? "Replace user token" : "User token", text: $token)
                        .font(.ui(16)).foregroundStyle(Ink.ink).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .privacySensitive().focused($focus, equals: .token).submitLabel(.done)
                        .onSubmit { if canSaveToken { save(["token": typedToken], label: "Token saved. ListenBrainz is checking it.") } }
                        .padding(15).background(Ink.ground, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("listenbrainz.token")
                    if !typedToken.isEmpty && UUID(uuidString: typedToken) == nil {
                        Text("Paste the complete user token from ListenBrainz settings.").font(.ui(12)).foregroundStyle(amber)
                    }
                    Link("Find your user token", destination: URL(string: "https://listenbrainz.org/settings/")!)
                        .font(.ui(14, .medium)).foregroundStyle(amber).frame(minHeight: 44)
                    primary(tokenSet ? "Replace token" : "Start writing", enabled: canSaveToken, id: "listenbrainz.saveToken") {
                        save(["token": typedToken], label: "Token saved. ListenBrainz is checking it.")
                    }
                }.padding(.top, 14)
            } label: { Text(tokenSet ? "Manage user token" : "Connect writing").font(.ui(14, .semibold)).foregroundStyle(amber).accessibilityIdentifier("listenbrainz.writeSetup") }
            if tokenSet {
                if unlink == "token" { unlinkConfirmation("Stop writing records?", detail: "The token is removed. Queued listens stay held for their original account for up to seven days. Reading stays connected.", field: "token") }
                else { Button("Disconnect writing", role: .destructive) { unlink = "token" }.font(.ui(13)).frame(minHeight: 44).disabled(!available || busy).accessibilityIdentifier("listenbrainz.unlinkWrite") }
            }
        }.padding(20).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 21))
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("The journal so far").font(.ui(20, .semibold)).foregroundStyle(Ink.ink).accessibilityAddTraits(.isHeader)
            if let last = lb?.last_listen {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "checkmark.circle").foregroundStyle(amber).frame(width: 24)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Last written").font(.machine(9)).foregroundStyle(amber)
                        Text(last.title).font(.ui(17, .semibold)).foregroundStyle(Ink.ink)
                        Text(last.artist).font(.ui(14)).foregroundStyle(Ink.dim)
                        Text(Date(timeIntervalSince1970: Double(last.at)), style: .relative).font(.ui(12)).foregroundStyle(Ink.dim)
                    }.fixedSize(horizontal: false, vertical: true)
                }
            }
            if (lb?.queued ?? 0) > 0 {
                queueRow(count: lb?.queued ?? 0, title: "Waiting to send", detail: "Retried automatically when ListenBrainz is available.", symbol: "arrow.up.circle")
            }
            if (lb?.held_queued ?? 0) > 0 {
                queueRow(count: lb?.held_queued ?? 0, title: "Held for another account", detail: "Reconnect the original token to send these listens. They are never sent to a different account.", symbol: "lock.circle")
            }
            if (lb?.legacy_queued ?? 0) > 0 {
                Text("\(lb?.legacy_queued ?? 0) older listens have no account record. They stay held and will not be submitted to an unverified account.")
                    .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
            if lb?.queue_saved == false { feedback("The wall could not save its queue to disk. Waiting listens are in memory until storage is available.", symbol: "exclamationmark.circle") }
            if (lb?.submitted ?? 0) > 0 {
                Text("\(lb?.submitted ?? 0) written since this connection started.").font(.ui(12)).foregroundStyle(Ink.dim)
            }
            Text("Unsent listens are kept for up to seven days.").font(.ui(12)).foregroundStyle(Ink.dim)
        }
    }

    private func sectionHeading(_ number: String, _ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(number).font(.machine(11)).foregroundStyle(amber)
                Text(title).font(.ui(21, .semibold)).foregroundStyle(Ink.ink).accessibilityAddTraits(.isHeader)
            }
            Text(subtitle).font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func queueRow(count: Int, title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).foregroundStyle(amber).frame(width: 24)
            VStack(alignment: .leading, spacing: 6) {
                Text("\(count) \(title.lowercased())").font(.ui(15, .semibold)).foregroundStyle(Ink.ink)
                Text(detail).font(.ui(13)).foregroundStyle(Ink.dim)
            }.fixedSize(horizontal: false, vertical: true)
        }
    }
    private func feedback(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.ui(13)).foregroundStyle(amber).fixedSize(horizontal: false, vertical: true)
    }
    private var retryButton: some View {
        Button {
            act { host in
                guard let fresh = await WallServices.retryListenBrainz(host: host) else { return (nil, "The wall could not start a retry. Check its connection.") }
                return (fresh, nil)
            }
        } label: {
            Label((lb?.retry_after ?? 0) > 0 ? "Retry available in \(lb?.retry_after ?? 0) s" : "Check connection again", systemImage: "arrow.clockwise")
                .font(.ui(14, .semibold)).fixedSize(horizontal: false, vertical: true).frame(minHeight: 44)
        }.foregroundStyle(amber).disabled(busy || (lb?.retry_after ?? 0) > 0)
            .accessibilityIdentifier("listenbrainz.retry")
    }
    private func primary(_ label: String, enabled: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if busy { ProgressView().tint(Ink.ground) }
                Text(label).font(.ui(15, .semibold)).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, minHeight: 50).padding(.vertical, 5)
        }.buttonStyle(PressStyle()).foregroundStyle(Ink.ground).background(amber, in: RoundedRectangle(cornerRadius: 13))
            .disabled(!enabled).opacity(enabled ? 1 : 0.4).accessibilityIdentifier(id)
    }
    private func unlinkConfirmation(_ title: String, detail: String, field: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.ui(15, .semibold)).foregroundStyle(Ink.ink)
            Text(detail).font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            Button("Confirm disconnect", role: .destructive) { save([field: ""], label: field == "token" ? "Writing disconnected." : "Username disconnected.") }
                .font(.ui(14, .semibold)).frame(minHeight: 44).disabled(busy || !available)
                .accessibilityIdentifier("listenbrainz.confirmDisconnect")
            Button("Keep connected") { unlink = nil }.font(.ui(14)).foregroundStyle(amber).frame(minHeight: 44)
        }.padding(.top, 4)
    }
    private func duration(_ seconds: Int) -> String { String(format: "%d:%02d", max(0, seconds) / 60, max(0, seconds) % 60) }
    private func refresh(host: String) async {
        guard wall.host == host else { return }
        guard wall.link.isLive else { checked = true; readFailed = true; return }
        let generation = operation
        let result = await WallServices.read(host: host)
        guard !Task.isCancelled, wall.host == host, scene == .active, operation == generation else { return }
        let first = !checked
        checked = true; readFailed = result == nil
        if let result {
            services = result
            if first { readExpanded = savedUser.isEmpty; writeExpanded = !tokenSet }
        }
    }
    private func save(_ patch: [String: String], label: String) {
        guard available, !busy else { return }
        focus = nil
        act(success: label) { host in await ServiceSave.send(["listenbrainz": patch], to: host) }
    }
    private func act(success: String? = nil, work: @escaping (String) async -> (WallServices?, String?)) {
        guard available, !busy else { return }
        busy = true; problem = nil; notice = nil
        let host = wall.host
        let id = UUID(); operation = id
        request = Task {
            let (fresh, why) = await work(host)
            guard !Task.isCancelled, operation == id, wall.host == host, scene == .active else { return }
            busy = false; request = nil
            if let fresh { services = fresh; readFailed = false }
            problem = why
            if why == nil {
                token = ""; unlink = nil; notice = success
                if success != nil { readExpanded = savedUser.isEmpty; writeExpanded = !tokenSet; Taps.commit() }
            }
        }
    }
    private func cancel() { request?.cancel(); request = nil; operation = UUID(); busy = false }
}

extension WallServices {
    struct Listenbrainz: Decodable {
        struct Listen: Decodable {
            var title: String
            var artist: String
            var album: String?
            var at: Int
            var kind: String?
        }
        struct Playing: Decodable {
            var title: String
            var artist: String
            var heard_s: Int
            var needs_s: Int
            var listened: Bool
        }
        struct Reading: Decodable { var title: String; var artist: String; var album: String? }
        var user: String
        var token_set: Bool?
        var valid: Bool?
        var user_name: String?
        var state: String?
        var checked_at: Double?
        var counting: Bool?
        var retry_after: Int?
        var read_state: String?
        var read_problem: String?
        var read_checked_at: Double?
        var read_playing: Reading?
        var playing: Playing?
        var last_listen: Listen?
        var queued: Int?
        var held_queued: Int?
        var legacy_queued: Int?
        var queue_saved: Bool?
        var submitted: Int?
        var problem: String?
    }
}
