import SwiftUI

struct DiscogsPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    let accent: Color
    @Binding var services: WallServices?
    @State private var user = ""
    @State private var token = ""
    @State private var editing = false
    @State private var removing = false
    @State private var busy = false
    @State private var loading = true
    @State private var readFailed = false
    @State private var problem: String?
    @State private var feedback: String?
    @State private var awaitedSync: String?
    @State private var revision = UUID()
    @State private var sourceHost = ""
    private let parchment = Color(hex: 0xDCC69A)
    private var dg: WallServices.Discogs? { services?.discogs }
    private var savedUser: String { dg?.user ?? "" }
    private var ready: Bool { !savedUser.isEmpty && dg?.token_set == true }
    private var count: Int { max(0, dg?.releases ?? 0) }
    private var syncing: Bool { dg?.syncing == true || awaitedSync != nil }
    private var typedUser: String { user.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var typedToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        guard wall.link.isLive, services != nil, !busy else { return false }
        let validUser = typedUser.range(of: "^[^\\s/]{1,64}$", options: .regularExpression) != nil
        let validToken = typedToken.range(of: "^[A-Za-z0-9]{20,100}$", options: .regularExpression) != nil
        return validUser && (validToken || (typedToken.isEmpty && dg?.token_set == true))
            && (validToken || typedUser != savedUser)
    }
    private var statusTitle: String {
        if !wall.link.isLive { return "Wall offline" }
        if loading && dg == nil { return "Checking the wall" }
        if readFailed { return "Status unavailable" }
        if syncing { return "Reading your collection" }
        if dg?.problem != nil { return "Read needs attention" }
        if ready { return dg?.synced_at == nil ? "Ready for the first read" : "Collection on the wall" }
        return count > 0 ? "Local collection · disconnected" : "Not connected"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                hero
                if !wall.link.isLive {
                    CreativeConnectionNotice(title: "Your wall is offline", detail: "Reconnect to manage Discogs or read the collection again. Saved records stay on the wall.", symbol: "wifi.slash", tint: parchment)
                } else if readFailed {
                    CreativeConnectionNotice(title: "Couldn't read this connection", detail: "Your saved account and collection haven't changed.", symbol: "exclamationmark.circle", tint: parchment)
                    Button("Try again") { Task { await refresh() } }.font(.ui(16, .semibold)).foregroundStyle(parchment).frame(minHeight: 44)
                }
                if loading && dg == nil {
                    ProgressView("Reading Discogs status").font(.ui(15)).tint(parchment).frame(maxWidth: .infinity, minHeight: 90)
                } else {
                    if let issue = problem ?? dg?.problem {
                        CreativeConnectionNotice(title: "The collection couldn't update", detail: issue, symbol: "exclamationmark.circle", tint: parchment)
                    }
                    if ready || count > 0 {
                        collection
                        if ready { syncControls }
                    }
                    if ready {
                        DisclosureGroup(isExpanded: $editing) {
                            credentials.padding(.top, 20)
                        } label: {
                            Text("Manage Discogs account").font(.ui(17, .semibold)).foregroundStyle(Ink.ink)
                                .fixedSize(horizontal: false, vertical: true).frame(minHeight: 48)
                                .accessibilityIdentifier("discogs.manage")
                        }.tint(parchment)
                    } else { credentials }
                    if let feedback {
                        Label(feedback, systemImage: "checkmark.circle").font(.ui(14)).foregroundStyle(parchment).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Label {
                    Text("Tessera reads your collection and pressing details. It never edits your Discogs collection or places marketplace orders.")
                        .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                } icon: { Image(systemName: "lock").font(.system(size: 14)).foregroundStyle(parchment) }
            }.padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 40)
        }
        .scrollIndicators(.hidden).background(Color(hex: 0x151614)).foregroundStyle(Ink.ink)
        .navigationTitle("Discogs").navigationBarTitleDisplayMode(.inline).tint(parchment)
        .refreshable { await refresh() }
        .task(id: "\(wall.host)|\(scenePhase)") {
            guard scenePhase == .active else { return }
            if sourceHost.isEmpty { sourceHost = wall.host; user = savedUser }
            else if sourceHost != wall.host { reset(host: wall.host) }
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(syncing ? 2 : 8))
            }
        }
        .onChange(of: wall.host) { _, host in reset(host: host) }
        .onDisappear { token = ""; revision = UUID(); busy = false }
    }
    private var hero: some View {
        VStack(alignment: .leading, spacing: typeSize.isAccessibilitySize ? 12 : 18) {
            HStack(spacing: 10) {
                Image(systemName: "opticaldisc").font(.system(size: 22, weight: .medium))
                Text("DISCOGS").font(.machine(typeSize.isAccessibilitySize ? 10 : 12)).tracking(2)
                Spacer(minLength: 0)
                if !typeSize.isAccessibilitySize { Text("YOUR EDITION").font(.machine(9)).tracking(1) }
            }.foregroundStyle(parchment)
            if !typeSize.isAccessibilitySize {
                Text("Every record.\nA place here.").font(.display(39)).tracking(-1).fixedSize(horizontal: false, vertical: true)
                DiscogsGrooves(tint: parchment).frame(height: 92).accessibilityHidden(true)
            }
            Group {
                if typeSize.isAccessibilitySize { Text(statusTitle).font(.ui(12, .medium)) }
                else { Label(statusTitle, systemImage: !wall.link.isLive ? "wifi.slash" : syncing ? "arrow.triangle.2.circlepath" : ready ? "checkmark.circle" : "circle.dotted").font(.ui(14, .medium)) }
            }.foregroundStyle(parchment).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("discogs.status")
            if !ready && count == 0 {
                Text("Bring your record collection into the room, pressing by pressing.")
                    .font(.ui(16)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var collection: some View {
        NavigationLink { ShelfPage(accent: accent) } label: {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(savedUser.isEmpty ? "Your collection" : savedUser).font(.ui(15, .medium)).foregroundStyle(Color(hex: 0x534938)).fixedSize(horizontal: false, vertical: true)
                        if dg?.synced_at != nil || count > 0 {
                            Text(count.formatted()).font(typeSize.isAccessibilitySize ? .ui(26, .semibold) : .display(58)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                            Text(count == 1 ? "record on your wall" : "records on your wall").font(.ui(14)).fixedSize(horizontal: false, vertical: true)
                        } else { Text("Your first read\nis waiting.").font(.ui(25, .semibold)).fixedSize(horizontal: false, vertical: true) }
                    }
                    Spacer(minLength: 0)
                    if !typeSize.isAccessibilitySize { Image(systemName: "arrow.up.right").font(.system(size: 22, weight: .medium)) }
                }
                Rectangle().fill(Color(hex: 0x342C20).opacity(0.16)).frame(height: 1)
                HStack { Text("Explore The shelf").font(.ui(16, .semibold)).fixedSize(horizontal: false, vertical: true); Spacer(minLength: 0); Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)) }
            }.foregroundStyle(Color(hex: 0x252218)).padding(22).frame(maxWidth: .infinity, alignment: .leading)
                .background(parchment, in: RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(.plain).accessibilityIdentifier("discogs.openShelf")
    }
    private var syncControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            if syncing {
                HStack(spacing: 12) { ProgressView().tint(parchment); Text(syncLine).font(.ui(15, .medium)).foregroundStyle(parchment) }
                    .accessibilityIdentifier("discogs.progress")
                if let read = dg?.pages_read, let total = dg?.pages_total, total > 0 {
                    ProgressView(value: Double(read), total: Double(total)).tint(parchment)
                        .accessibilityLabel("Collection pages read").accessibilityValue("\(read) of \(total)")
                }
                Text("You can leave this page. Your previous collection stays available until this read finishes.").font(.ui(13)).foregroundStyle(Ink.dim)
            } else {
                CreativeConnectionAction(title: dg?.problem == nil ? "Read collection again" : "Retry collection read", tint: parchment, busy: busy, enabled: wall.link.isLive) { sync() }
                    .accessibilityIdentifier("discogs.sync")
            }
            if let stamp = dg?.synced_at, stamp.isFinite, stamp > 0 {
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 5)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 5))
                layout {
                    Text("Last read"); Text(Date(timeIntervalSince1970: stamp), format: .dateTime.month(.abbreviated).day().hour().minute()).fixedSize(horizontal: false, vertical: true)
                }.font(.ui(12)).foregroundStyle(Ink.dim).accessibilityElement(children: .combine)
            } else { Text("No completed collection read yet.").font(.ui(13)).foregroundStyle(Ink.dim) }
        }
    }
    private var syncLine: String {
        if let count = dg?.releases_read, count > 0 { return "\(count.formatted()) records read so far" }
        return "Reading your Discogs collection"
    }
    private var credentials: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(ready ? "Your account" : "Connect your collection").font(.ui(22, .semibold))
            CreativeCredentialField(title: "Discogs username", hint: "Your username", text: $user)
                .accessibilityIdentifier("discogs.username")
            CreativeCredentialField(title: "Personal access token", hint: dg?.token_set == true ? "Paste a replacement token" : "Paste your token", text: $token, secure: true)
                .accessibilityIdentifier("discogs.token")
            if !typedUser.isEmpty && !savedUser.isEmpty && typedUser != savedUser {
                Text("Changing the account replaces the wall's cached collection after it saves.").font(.ui(13)).foregroundStyle(parchment)
            }
            CreativeConnectionAction(title: busy ? "Saving…" : ready ? "Save account" : "Connect Discogs", tint: parchment, busy: busy, enabled: canSave) {
                var patch = ["user": typedUser]
                if !typedToken.isEmpty { patch["token"] = typedToken }
                save(patch, receipt: "Account saved. The wall will read your collection.")
            }.accessibilityIdentifier("discogs.save")
            Button { openURL(URL(string: "https://www.discogs.com/settings/developers")!) } label: {
                Label("Get a token from Discogs", systemImage: "arrow.up.right").font(.ui(14, .medium)).frame(minHeight: 44, alignment: .leading)
            }.foregroundStyle(parchment)
            Text("In Discogs, open Settings → Developers → Generate new token. Your token is saved on the wall and isn't shown again here.")
                .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            if dg?.token_set == true {
                Divider().overlay(parchment.opacity(0.16))
                if removing {
                    Text("Disconnect Discogs? The wall keeps this account's last collection, but stops reading updates and pressing details. The token remains active in Discogs.")
                        .font(.ui(14)).foregroundStyle(Ink.dim)
                    Button("Disconnect and keep local collection", role: .destructive) { save(["token": ""], receipt: "Discogs disconnected. Your local collection is still here.") }
                        .font(.ui(15, .semibold)).frame(minHeight: 44).disabled(busy || !wall.link.isLive).accessibilityIdentifier("discogs.confirmRemove")
                    Button("Keep connected") { removing = false }.font(.ui(15)).frame(minHeight: 44)
                } else {
                    Button("Disconnect Discogs", role: .destructive) { removing = true }.font(.ui(14, .medium)).frame(minHeight: 44)
                        .disabled(busy || !wall.link.isLive).accessibilityIdentifier("discogs.remove")
                }
            }
        }
    }
    private func reset(host: String) {
        sourceHost = host; revision = UUID(); user = ""; token = ""; busy = false; awaitedSync = nil
        loading = true; readFailed = false; problem = nil; feedback = nil; removing = false; services = nil
    }
    private func refresh() async {
        guard !busy else { return }
        let host = wall.host, id = revision
        let fresh = await WallServices.read(host: host)
        guard !Task.isCancelled, wall.host == host, id == revision else { return }
        loading = false; readFailed = fresh == nil
        if let fresh {
            services = fresh
            if user.isEmpty { user = savedUser }
            if let awaitedSync {
                if dg?.completed_sync_id == awaitedSync {
                    self.awaitedSync = nil
                    if dg?.problem == nil { feedback = "Collection read by your wall"; Taps.commit() }
                } else if dg?.syncing != true && dg?.sync_id != awaitedSync {
                    self.awaitedSync = nil; problem = "The wall restarted before confirming this read. Try again."
                }
            }
        }
    }
    private func save(_ patch: [String: String], receipt: String) {
        guard wall.link.isLive, !busy else { return }
        let host = wall.host, id = UUID(); revision = id; busy = true; problem = nil; feedback = nil
        Task {
            let (fresh, why) = await ServiceSave.send(["discogs": patch], to: host)
            guard !Task.isCancelled, wall.host == host, revision == id else { return }
            revision = UUID(); busy = false
            if let fresh { services = fresh; readFailed = false }
            problem = why
            if why == nil { token = ""; user = savedUser; removing = false; editing = false; awaitedSync = nil; feedback = receipt; Taps.commit() }
        }
    }
    private func sync() {
        guard ready, wall.link.isLive, !busy, !syncing else { return }
        let host = wall.host, id = UUID(); revision = id; busy = true; problem = nil; feedback = nil
        Task {
            do {
                let receipt = try await ShelfList.requestSync(host: host)
                guard !Task.isCancelled, wall.host == host, revision == id else { return }
                revision = UUID(); busy = false; awaitedSync = receipt.sync_id
                await refresh()
            } catch {
                guard !Task.isCancelled, wall.host == host, revision == id else { return }
                revision = UUID(); busy = false
                problem = (error as? ShelfRequestError)?.localizedDescription ?? "The wall didn't confirm this read. Reconnect and try again."
            }
        }
    }
}

private struct DiscogsGrooves: View {
    let tint: Color
    var body: some View {
        Canvas { context, size in
            for record in 0..<3 {
                let center = CGPoint(x: size.width * (0.2 + Double(record) * 0.31), y: size.height * 0.74)
                let radius = size.height * 0.82
                context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)), with: .color(Color(hex: 0x151614)))
                for groove in 0..<8 {
                    let r = radius * (0.4 + Double(groove) * 0.077)
                    context.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)), with: .color(tint.opacity(groove == 7 ? 0.52 : 0.14)), lineWidth: 0.8)
                }
                context.fill(Path(ellipseIn: CGRect(x: center.x - 16, y: center.y - 16, width: 32, height: 32)), with: .color(tint.opacity(0.75 - Double(record) * 0.18)))
                context.fill(Path(ellipseIn: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)), with: .color(Color(hex: 0x151614)))
            }
        }.clipped()
    }
}

extension WallServices {
    struct Discogs: Decodable {
        var user: String
        var token_set: Bool?
        var releases: Int?
        var synced_at: Double?
        var syncing: Bool?
        var problem: String?
        var sync_id: String?
        var completed_sync_id: String?
        var pages_read: Int?
        var pages_total: Int?
        var releases_read: Int?
    }
}
