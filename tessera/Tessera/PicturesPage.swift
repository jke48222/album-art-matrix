import SwiftUI

/// Connection settings live here; searching lives in Show me. Optional Google
/// credentials never block the built-in web, Wikipedia and Openverse route.
struct PicturesPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.scenePhase) private var scene
    @Environment(\.dynamicTypeSize) private var typeSize
    let accent: Color
    @Binding var services: WallServices?
    @State private var key = ""
    @State private var cx = ""
    @State private var editing = false
    @State private var removing = false
    @State private var busy = false
    @State private var operationTitle = "Updating Google connection"
    @State private var loading = true
    @State private var failed = false
    @State private var problem: String?
    @State private var notice: String?
    @State private var revision = UUID()
    @State private var sourceHost: String?
    /// Bumped by pull to refresh, so a failed last-picture frame is fetched again at once.
    @State private var pulls = 0
    @FocusState private var focused: Field?
    private enum Field { case key, engine }
    private let blue = Color(hex: 0xB7CAD6)
    private var google: WallServices.Google? { services?.google }
    private var available: Bool { wall.link.isLive && services != nil && !failed }
    private var configured: Bool { google?.key_set == true && google?.cx_set == true }
    private var hasCredentials: Bool { google?.key_set == true || google?.cx_set == true }
    private var working: Bool { busy || google?.checking == true }
    /// The wall was built with Show me switched off: nothing here can search, show or save.
    private var off: Bool { google?.state == "off" }
    private var typedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var typedCX: String { cx.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var validKey: Bool { typedKey.range(of: "^[A-Za-z0-9_-]{30,80}$", options: .regularExpression) != nil }
    private var validCX: Bool { typedCX.range(of: "^[A-Za-z0-9:_-]{8,80}$", options: .regularExpression) != nil }
    private var canSave: Bool {
        available && !working && (!typedKey.isEmpty || !typedCX.isEmpty)
        && (typedKey.isEmpty ? google?.key_set == true : validKey)
        && (typedCX.isEmpty ? google?.cx_set == true : validCX)
    }
    private var connectionTitle: String {
        guard wall.link.isLive else { return "Wall offline" }
        if loading && google == nil { return "Reading connection" }
        if failed { return "Connection status unavailable" }
        if off { return "The Show me feature is off on this wall" }
        if busy { return operationTitle }
        if google?.checking == true { return "Checking saved Google connection" }
        if google?.problem != nil { return "Google needs attention" }
        if google?.verified == true { return "Google connection verified" }
        if configured { return "Credentials saved, not checked" }
        return hasCredentials ? "Complete your Google connection" : "Built-in search is ready"
    }
    /// Something is being read, saved or checked right now.
    private var inProgress: Bool { wall.link.isLive && ((loading && google == nil) || working) }
    /// The wall's own report on the saved Google connection. It sits under the
    /// status line, so "needs attention" is explained on the first screen. A
    /// problem from a save or check made here shows beside the form instead.
    private var wallProblem: String? {
        guard problem == nil, available, !off, !working else { return nil }
        return google?.problem
    }
    private var googleDetail: String {
        guard google?.problem != nil else { return "Your saved connection is tried first." }
        switch google?.state {
        case "refused": return "Refused by Google. Check the key and engine ID."
        case "limited": return "Google’s search limit was reached. The other sources are used meanwhile."
        default: return "Google did not answer the last check. The other sources still work."
        }
    }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView { page(proxy) }
                .scrollIndicators(.hidden).scrollDismissesKeyboard(.interactively).background(Color(hex: 0x14191C)).foregroundStyle(Ink.ink).tint(blue)
        }
            .navigationTitle("Pictures").navigationBarTitleDisplayMode(.inline)
            .refreshable { pulls += 1; await refresh() }
            .task(id: "\(wall.host)|\(scene)") {
                guard scene == .active else { return }
                if sourceHost == nil { sourceHost = wall.host }
                else if sourceHost != wall.host { reset(host: wall.host) }
                while !Task.isCancelled {
                    await refresh()
                    do { try await Task.sleep(for: .seconds(google?.checking == true ? 1 : 7)) } catch { return }
                }
            }
            .onChange(of: wall.host) { _, host in reset(host: host) }
            .onChange(of: scene) { _, phase in if phase != .active { clearSensitiveDraft() } }
            .onDisappear { clearSensitiveDraft() }
    }
    private func page(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 27) {
            hero
            if !wall.link.isLive {
                CreativeConnectionNotice(title: "Search and settings unavailable", detail: "Saved details may be out of date. Searches and connection settings will be available when the wall is back online.", symbol: "wifi.slash", tint: blue).accessibilityIdentifier("pictures.offline")
            } else if failed {
                CreativeConnectionNotice(title: "Couldn’t read this connection", detail: "The saved Google details have not changed. Try reading the wall again.", symbol: "exclamationmark.circle", tint: blue)
                Button("Read again") { Task { await refresh() } }.frame(minHeight: 44).accessibilityIdentifier("pictures.retry")
            } else if off {
                CreativeConnectionNotice(title: "Picture search is unavailable", detail: "The Show me feature is switched off in the wall’s settings, so pictures cannot be searched or shown.", symbol: "eye.slash", tint: blue).accessibilityIdentifier("pictures.off")
            } else if let wallProblem {
                googleProblem(wallProblem, proxy)
            }
            if !off {
                searchLink
                if typeSize.isAccessibilitySize { connectionSection }
                routes
                if let last = google?.last { lastPicture(last) }
                else if google != nil { emptyHistory }
                if !typeSize.isAccessibilitySize { connectionSection }
            }
        }.padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 40)
    }
    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            // The navigation bar already says "Pictures": one heading is enough.
            if !typeSize.isAccessibilitySize {
                Text("Picture search").font(.display(42)).tracking(-0.9).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            }
            HStack(alignment: .center, spacing: 10) {
                if inProgress { ProgressView().tint(blue).accessibilityHidden(true) }
                Text(connectionTitle).font(.ui(typeSize.isAccessibilitySize ? 12 : 14, .medium)).foregroundStyle(blue).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("pictures.status")
            }
        }
    }
    /// Google's own complaint, with a way to the form that fixes it.
    private func googleProblem(_ issue: String, _ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(issue, systemImage: "exclamationmark.circle").font(.ui(15, .medium)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("pictures.problem")
            Button {
                editing = true
                withAnimation { proxy.scrollTo(Self.connectionAnchor, anchor: .top) }
            } label: {
                Text("Review Google details").font(.ui(14, .semibold)).multilineTextAlignment(.leading).frame(minHeight: 44)
            }.foregroundStyle(blue)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
    }
    /// Off the wall this page cannot search, so the one big control says so
    /// instead of offering what the notice above rules out.
    private var searchLink: some View {
        let live = wall.link.isLive
        return NavigationLink { ShowPage(accent: accent) } label: {
            HStack(spacing: 14) {
                Image(systemName: "magnifyingglass").font(.system(size: 20, weight: .medium))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Find a picture").font(.ui(typeSize.isAccessibilitySize ? 12 : 17, .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(live ? "Open the Show me page" : "Available when the wall is online").font(.ui(typeSize.isAccessibilitySize ? 9 : 13)).opacity(live ? 0.75 : 1).fixedSize(horizontal: false, vertical: true)
                }.multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Image(systemName: live ? "arrow.up.right" : "wifi.slash").font(.system(size: 18, weight: .medium))
            }
            // Disabled: no fill, dim label (about 4.8:1 on this ground), a quiet outline.
            .foregroundStyle(live ? Color(hex: 0x17222A) : Ink.dim).padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(live ? blue : blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 17))
            .overlay { RoundedRectangle(cornerRadius: 17).strokeBorder(blue.opacity(live ? 0 : 0.22), lineWidth: 1) }
        }.buttonStyle(PressStyle()).disabled(!live).accessibilityIdentifier("pictures.openShow")
    }
    private var sources: [(title: String, detail: String, symbol: String)] {
        var list: [(title: String, detail: String, symbol: String)] = []
        if configured { list.append(("Google Images", googleDetail, "photo.on.rectangle")) }
        list.append(("The web", "A broad image search through DuckDuckGo.", "globe"))
        list.append(("Wikipedia", "The lead image from a matching article.", "book.closed"))
        list.append(("Openverse", "A final search across openly licensed images.", "photo.stack"))
        return list
    }
    private var routes: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("Search sources").font(.ui(typeSize.isAccessibilitySize ? 13 : 22, .semibold)).accessibilityAddTraits(.isHeader)
            Text(configured ? "Tessera tries these sources in order until a picture reaches your wall." : "No search account needed. Tessera tries these sources in order until a picture reaches your wall.").font(.ui(typeSize.isAccessibilitySize ? 10 : 14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                // Numbered by position, so a saved Google connection is 01.
                ForEach(Array(sources.enumerated()), id: \.offset) { index, source in
                    sourceRow(String(format: "%02d", index + 1), source.title, source.detail, source.symbol)
                }
            }
        }.accessibilityIdentifier("pictures.sources")
    }
    private func sourceRow(_ number: String, _ title: String, _ detail: String, _ symbol: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            // Never wraps: the width grows with the text size instead.
            Text(number).font(.machine(typeSize.isAccessibilitySize ? 8 : 10)).foregroundStyle(blue).lineLimit(1).fixedSize().frame(minWidth: 24, alignment: .leading).padding(.top, 4).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.ui(typeSize.isAccessibilitySize ? 12 : 15, .semibold)); Text(detail).font(.ui(typeSize.isAccessibilitySize ? 10 : 12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if !typeSize.isAccessibilitySize { Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(blue).frame(width: 24).accessibilityHidden(true) }
        }.padding(.vertical, 12).overlay(alignment: .bottom) { Rectangle().fill(blue.opacity(0.1)).frame(height: 1) }.accessibilityElement(children: .combine)
    }
    /// The square the wall made, from the wall itself: the same composition as
    /// the panel, and no third-party picture host is contacted from the phone.
    private func lastPicture(_ last: WallServices.Google.Last) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("LAST PICTURE ON THE WALL").font(.machine(typeSize.isAccessibilitySize ? 8 : 10)).tracking(0.8).foregroundStyle(blue)
            if last.frame == true {
                LastWallFrame(host: wall.host, picture: "\(last.at ?? 0)|\(last.title)", live: available, retry: pulls, title: last.title, tint: blue)
                // Only under the square: an older brain (or a fixture) sends no
                // frame, and then there is nothing on screen for this to describe.
                Text("The frame the wall showed. It is not a live view.").font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
            Text(last.title).font(typeSize.isAccessibilitySize ? .ui(18, .semibold) : .display(28)).fixedSize(horizontal: false, vertical: true)
            if let source = last.source, !source.isEmpty { Label(Self.sourceName(source), systemImage: "link").font(.ui(13, .medium)).foregroundStyle(blue) }
            if let credit = last.credit, !credit.isEmpty { Text(credit).font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true) }
            if let stamp = last.at, stamp.isFinite, stamp > 0 {
                // The wall's clock can run slightly ahead of the phone's.
                Text("Shown " + min(Date(timeIntervalSince1970: stamp), Date.now).formatted(.relative(presentation: .named))).font(.ui(12)).foregroundStyle(Ink.dim)
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(blue.opacity(0.055), in: RoundedRectangle(cornerRadius: 20)).accessibilityIdentifier("pictures.last")
    }
    /// The brain reports its internal finder ids.
    private static func sourceName(_ id: String) -> String {
        switch id.lowercased() {
        case "google": return "Google Images"
        case "web": return "The web"
        case "wikipedia": return "Wikipedia"
        case "openverse": return "Openverse"
        default: return id.prefix(1).uppercased() + id.dropFirst()
        }
    }
    private var emptyHistory: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No pictures shown yet").font(.ui(20, .semibold))
            Text("Search for a place, an object or a moment on the Show me page. The last picture the wall shows will appear here with its source.").font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 3).accessibilityIdentifier("pictures.empty")
    }
    private static let connectionAnchor = "pictures.connection"
    /// The form, then what a save or check made from it returned, right under it.
    @ViewBuilder private var connectionSection: some View {
        googleConnection.id(Self.connectionAnchor)
        if let problem {
            Label(problem, systemImage: "exclamationmark.circle").font(.ui(14)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("pictures.problem")
        }
        if let notice { Label(notice, systemImage: "checkmark.circle").font(.ui(14)).foregroundStyle(blue).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("pictures.notice") }
    }
    private var googleConnection: some View {
        DisclosureGroup(isExpanded: $editing) {
            credentials.padding(.top, 18)
        } label: {
            // The label is a button, and buttons centre wrapped lines: pin them left.
            VStack(alignment: .leading, spacing: 5) {
                Text(hasCredentials ? "Manage Google connection" : "Use an existing Google connection").font(.ui(typeSize.isAccessibilitySize ? 12 : 17, .semibold)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                Text(hasCredentials ? connectionTitle : "Optional, for existing API customers").font(.ui(typeSize.isAccessibilitySize ? 9 : 12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }.multilineTextAlignment(.leading).frame(maxWidth: .infinity, minHeight: 55, alignment: .leading).accessibilityIdentifier("pictures.manage")
        }.tint(blue)
    }
    private var credentials: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Google’s Custom Search JSON API is closed to new customers. Existing customers can use it until January 1, 2027. The built-in search above works without it.").font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            Link("Google’s service notice", destination: URL(string: "https://developers.google.com/custom-search/v1/overview")!).font(.ui(14, .medium)).frame(minHeight: 44)
            VStack(alignment: .leading, spacing: 8) {
                Text("API key").font(.ui(14, .medium))
                SecureField(google?.key_set == true ? "Saved on the wall. Paste a replacement." : "Paste your existing API key", text: $key).font(.machine(13)).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.asciiCapable).focused($focused, equals: .key).padding(15).background(Ink.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 12)).accessibilityIdentifier("pictures.key")
                if !typedKey.isEmpty && !validKey { Text("Use 30 to 80 letters, numbers, hyphens or underscores.").font(.ui(12)).foregroundStyle(Ink.dim) }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Search engine ID").font(.ui(14, .medium))
                TextField(google?.cx_set == true ? "Saved on the wall. Paste a replacement." : "Your existing engine ID", text: $cx).font(.machine(13)).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.asciiCapable).focused($focused, equals: .engine).padding(15).background(Ink.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 12)).accessibilityIdentifier("pictures.engine")
                if !typedCX.isEmpty && !validCX { Text("Use 8 to 80 letters, numbers, colons, hyphens or underscores.").font(.ui(12)).foregroundStyle(Ink.dim) }
            }
            Button { save(removing: false) } label: { Text(busy ? "Saving…" : "Save connection").font(.ui(15, .semibold)).frame(maxWidth: .infinity, minHeight: 51).foregroundStyle(Color(hex: 0x17222A)).background(blue, in: RoundedRectangle(cornerRadius: 13)) }.disabled(!canSave).opacity(canSave ? 1 : 0.4).accessibilityIdentifier("pictures.save")
            Text("Credentials stay on your wall. Blank fields keep saved values. Saving does not verify that Google accepts them.").font(.ui(12)).foregroundStyle(Ink.dim)
            if configured {
                Button { check() } label: { Label(working ? "Checking Google…" : "Check saved connection", systemImage: "arrow.clockwise").font(.ui(15, .semibold)).frame(minHeight: 44) }.disabled(!available || working).accessibilityIdentifier("pictures.check")
                Text("This check makes one Google search request and uses your API quota. It does not change the picture on your wall.").font(.ui(12)).foregroundStyle(Ink.dim)
                if let stamp = google?.checked_at, stamp.isFinite, stamp > 0 {
                    HStack { Text("Last checked"); Text(Date(timeIntervalSince1970: stamp), style: .relative) }.font(.ui(12)).foregroundStyle(Ink.dim)
                }
            }
            if hasCredentials {
                if removing {
                    Text("Remove this key and engine ID? Picture search will continue using the built-in sources.").font(.ui(14)).foregroundStyle(Ink.dim)
                    Button("Remove Google connection", role: .destructive) { save(removing: true) }.frame(minHeight: 44).disabled(!available || working).accessibilityIdentifier("pictures.confirmRemove")
                    Button("Keep connection") { removing = false }.frame(minHeight: 44).disabled(working)
                } else {
                    Button("Remove Google connection", role: .destructive) { removing = true }.frame(minHeight: 44).disabled(!available || working).accessibilityIdentifier("pictures.remove")
                }
            }
        }
    }
    private func clearSensitiveDraft() {
        key = ""; cx = ""; focused = nil; revision = UUID(); busy = false
    }
    private func reset(host: String) {
        clearSensitiveDraft(); sourceHost = host; services = nil; loading = true; failed = false; removing = false; editing = false; problem = nil; notice = nil
    }
    private func refresh() async {
        guard !busy, wall.link.isLive, scene == .active else { loading = false; return }
        let host = wall.host, id = revision
        let fresh = await WallServices.read(host: host)
        guard !Task.isCancelled, wall.host == host, revision == id, scene == .active else { return }
        loading = false; failed = fresh == nil
        // A check started here has finished: its "started" notice is stale.
        if services?.google?.checking == true, let fresh, fresh.google?.checking != true {
            notice = fresh.google?.verified == true ? "Google accepted the saved connection." : nil
        }
        if let fresh { services = fresh }
    }
    private func save(removing: Bool) {
        guard available, !working, removing || canSave else { return }
        let host = wall.host, id = UUID(); revision = id; busy = true; problem = nil; notice = nil; focused = nil
        operationTitle = removing ? "Removing Google connection" : "Saving Google connection"
        var patch: [String: String] = [:]
        if removing { patch = ["api_key": "", "cx": ""] }
        else {
            if !typedKey.isEmpty { patch["api_key"] = typedKey }
            if !typedCX.isEmpty { patch["cx"] = typedCX }
        }
        Task {
            let (fresh, why) = await ServiceSave.send(["google": patch], to: host)
            guard !Task.isCancelled, revision == id, wall.host == host, scene == .active else { return }
            revision = UUID(); busy = false
            if let fresh { services = fresh; failed = false }
            problem = why
            guard why == nil else { return }
            guard let connection = fresh?.google,
                  removing ? (!connection.key_set && !connection.cx_set) : (connection.key_set && connection.cx_set) else {
                problem = "The wall did not confirm these details. Your draft is kept."; return
            }
            key = ""; cx = ""; self.removing = false; notice = removing ? "Google removed. Built-in picture search stays available." : "Connection saved. Check it when you’re ready."; Taps.commit()
        }
    }
    private func check() {
        guard configured, available, !working else { return }
        let host = wall.host, id = UUID(); revision = id; busy = true; problem = nil; notice = nil; focused = nil
        operationTitle = "Checking saved Google connection"
        Task {
            let fresh = await Self.checkSaved(host: host)
            guard !Task.isCancelled, revision == id, wall.host == host, scene == .active else { return }
            revision = UUID(); busy = false
            if let fresh { services = fresh; failed = false; notice = fresh.google?.checking == true ? "Google check started. The result will appear here." : fresh.google?.verified == true ? "Google accepted the saved connection." : nil }
            else { problem = "The check was not confirmed. Wait a moment, then try again." }
        }
    }
    private static func checkSaved(host: String) async -> WallServices? {
        guard let url = URL(string: "http://\(host)/pictures/check") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"; request.httpBody = Data("{}".utf8); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let fresh = try? JSONDecoder().decode(WallServices.self, from: data), fresh.google != nil else { return nil }
        return fresh
    }
}

/// Fetched once per picture and kept across offline spells. The wall's pixels
/// are drawn as hard squares, as the panel shows them.
private struct LastWallFrame: View {
    @Environment(\.scenePhase) private var scene
    let host: String
    let picture: String
    let live: Bool
    /// The page's pull-to-refresh count: a pull retries a failed fetch now.
    let retry: Int
    let title: String
    let tint: Color
    @State private var image: UIImage?
    @State private var loaded: String?
    @State private var tried: String?
    @State private var failed = false
    var body: some View {
        ZStack {
            tint.opacity(0.06)
            if let image {
                Image(uiImage: image).resizable().interpolation(.none).scaledToFit()
            } else if failed {
                VStack(spacing: 9) { Image(systemName: "photo").font(.system(size: 26)); Text("Frame unavailable").font(.ui(13)) }.foregroundStyle(tint)
            } else {
                ProgressView().tint(tint)
            }
        }.aspectRatio(1, contentMode: .fit).frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 9))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(image != nil ? "The wall’s frame for \(title)" : failed ? "The wall’s frame is unavailable" : "Loading the wall’s frame")
            .task(id: "\(host)|\(picture)|\(live)|\(retry)|\(scene == .active)") {
                guard scene == .active else { return }
                // One failed fetch (a timeout, a brief 503) must not leave the square
                // empty until the next picture: while the link is up, try again on the
                // page's 7 second refresh cadence until the frame arrives.
                while !Task.isCancelled {
                    await load()
                    guard live, scene == .active, loaded != "\(host)|\(picture)" else { return }
                    do { try await Task.sleep(for: .seconds(7)) } catch { return }
                }
            }
    }
    private func load() async {
        let id = "\(host)|\(picture)"
        guard loaded != id else { return }
        // A new picture starts from the spinner. A retry of the same one keeps
        // "Frame unavailable" up until it succeeds, so the square does not flicker.
        if tried != id { image = nil; failed = false; tried = id }
        guard live else { failed = true; return }
        guard let url = URL(string: "http://\(host)/pictures/last.png") else { failed = true; return }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        let result = try? await URLSession.shared.data(for: request)
        guard !Task.isCancelled else { return }
        guard let (data, response) = result, (response as? HTTPURLResponse)?.statusCode == 200, let picture = UIImage(data: data) else {
            failed = true; return
        }
        image = picture; failed = false; loaded = id
    }
}
