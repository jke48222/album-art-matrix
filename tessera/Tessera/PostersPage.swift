import SwiftUI

struct PostersPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    let accent: Color
    @Binding var services: WallServices?
    @State private var key = ""
    @State private var title = ""
    @State private var busy = false
    @State private var editing = false
    @State private var removing = false
    @State private var loading = true
    @State private var readFailed = false
    @State private var problem: String?
    @State private var feedback: String?
    @State private var revision = UUID()
    @State private var sourceHost = ""
    private let gold = Color(hex: 0xE6C78F)
    private var tmdb: WallServices.Tmdb? { services?.tmdb }
    private var ready: Bool { tmdb?.key_set == true }
    private var working: Bool { busy || tmdb?.checking == true }
    private var typedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        guard wall.link.isLive, services != nil, !working else { return false }
        return typedKey.range(of: "^([0-9a-fA-F]{32}|eyJ[A-Za-z0-9._-]{40,800})$", options: .regularExpression) != nil
    }
    private var statusTitle: String {
        if !wall.link.isLive { return "Wall offline" }
        if loading && tmdb == nil { return "Reading connection" }
        if readFailed { return "Status unavailable" }
        if tmdb?.checking == true { return "Checking TMDB" }
        if tmdb?.problem != nil { return "Connection needs attention" }
        if tmdb?.verified == true { return "TMDB connected" }
        return ready ? "Key saved, not checked yet" : "No key saved"
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                hero
                if !wall.link.isLive {
                    CreativeConnectionNotice(title: "Your wall is offline", detail: "Reconnect to look up a poster or change its key. Saved details may be out of date.", symbol: "wifi.slash", tint: gold)
                } else if readFailed {
                    CreativeConnectionNotice(title: "Couldn't read this connection", detail: "The key and poster history on your wall haven't changed.", symbol: "exclamationmark.circle", tint: gold)
                    Button("Read again") { Task { await refresh() } }.font(.ui(15, .semibold)).foregroundStyle(gold).frame(minHeight: 44)
                }
                if loading && tmdb == nil {
                    ProgressView("Reading poster status").tint(gold).frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    if let issue = problem ?? tmdb?.problem {
                        CreativeConnectionNotice(title: "Needs attention", detail: issue, symbol: "exclamationmark.circle", tint: gold)
                            .accessibilityIdentifier("posters.problem")
                    }
                    if ready {
                        if typeSize.isAccessibilitySize { keyManagement }
                        if let last = tmdb?.last { recentPoster(last) }
                        else { emptyHistory }
                        lookup
                        if !typeSize.isAccessibilitySize { keyManagement }
                    } else { credentials }
                    if let feedback {
                        Label(feedback, systemImage: "checkmark.circle").font(.ui(14)).foregroundStyle(gold).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("posters.notice")
                    }
                    reporterLink
                }
                attribution
            }.padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 40)
        }.scrollIndicators(.hidden).background(Color(hex: 0x171715)).foregroundStyle(Ink.ink)
            .navigationTitle("Posters").navigationBarTitleDisplayMode(.inline).tint(gold)
            .refreshable { await refresh() }
            .task(id: "\(wall.host)|\(scenePhase)") {
                guard scenePhase == .active else { return }
                if sourceHost.isEmpty { sourceHost = wall.host }
                else if sourceHost != wall.host { reset(host: wall.host) }
                while !Task.isCancelled {
                    await refresh()
                    try? await Task.sleep(for: .seconds(tmdb?.checking == true ? 1 : 8))
                }
            }
            .onChange(of: wall.host) { _, host in reset(host: host) }
            .onDisappear { key = ""; revision = UUID(); busy = false }
    }
    private var hero: some View {
        VStack(alignment: .leading, spacing: typeSize.isAccessibilitySize ? 12 : 20) {
            HStack(spacing: 10) {
                Image(systemName: "film").font(.system(size: 21, weight: .medium))
                Text(typeSize.isAccessibilitySize ? "TMDB" : "POSTERS").font(.machine(typeSize.isAccessibilitySize ? 10 : 11)).tracking(typeSize.isAccessibilitySize ? 0 : 2)
                Spacer(minLength: 0)
                if !typeSize.isAccessibilitySize { Text("TMDB").font(.machine(10)).tracking(1) }
            }.foregroundStyle(gold)
            if !typeSize.isAccessibilitySize {
                Text("Film and TV posters").font(.display(40)).tracking(-1.3).fixedSize(horizontal: false, vertical: true)
                PosterAperture(tint: gold).frame(height: 78).accessibilityHidden(true)
            }
            Group {
                if typeSize.isAccessibilitySize { Text(statusTitle) }
                else { Label(statusTitle, systemImage: !wall.link.isLive ? "wifi.slash" : tmdb?.verified == true ? "checkmark.circle" : "circle.dotted") }
            }.font(.ui(typeSize.isAccessibilitySize ? 12 : 14, .medium)).foregroundStyle(gold).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("posters.status")
            if !ready {
                Text("The films and series playing on your Mac, with their own artwork on your wall.").font(.ui(16)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    /// `lookup` is the answer to this page's Look up title, which the wall
    /// keeps apart from the poster its Mac last found, and from the count.
    private func recentPoster(_ last: WallServices.Tmdb.Last, lookup: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(lookup ? "Lookup result" : "Latest match").font(.ui(13, .medium)).foregroundStyle(gold)
                Spacer()
                if !lookup && !typeSize.isAccessibilitySize { Text("\(tmdb?.posters ?? 0) FOUND").font(.machine(9)).tracking(1).foregroundStyle(Ink.dim) }
            }
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 18)) : AnyLayout(HStackLayout(alignment: .top, spacing: 20))
            layout {
                if !typeSize.isAccessibilitySize, let path = last.poster, let url = URL(string: path) {
                    AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: {
                        ZStack { gold.opacity(0.06); Image(systemName: "film").foregroundStyle(gold.opacity(0.5)) }
                    }.frame(width: 112, height: 166).clipped().clipShape(RoundedRectangle(cornerRadius: 6))
                        .accessibilityLabel("Poster for \(last.title)")
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(last.title).font(typeSize.isAccessibilitySize ? .ui(18, .semibold) : .display(28)).tracking(-0.5).fixedSize(horizontal: false, vertical: true)
                    Text([last.kind == "movie" ? "Film" : "Series", last.year.map(String.init)].compactMap { $0 }.joined(separator: ", "))
                        .font(.ui(13, .medium)).foregroundStyle(gold)
                    if let overview = last.overview, !overview.isEmpty, !typeSize.isAccessibilitySize {
                        Text(overview).font(.ui(13)).foregroundStyle(Ink.dim).lineLimit(4)
                    }
                    if let id = last.id, let kind = last.kind, ["tv", "movie"].contains(kind) {
                        Button { openURL(URL(string: "https://www.themoviedb.org/\(kind)/\(id)")!) } label: {
                            Label("View on TMDB", systemImage: "arrow.up.right").font(.ui(12, .medium)).frame(minHeight: 44)
                        }.foregroundStyle(gold)
                    }
                }
            }
            Text("A lookup result, not a live wall preview.").font(.ui(12)).foregroundStyle(Ink.dim)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(gold.opacity(0.055), in: RoundedRectangle(cornerRadius: 18)).accessibilityIdentifier(lookup ? "posters.lookupResult" : "posters.latest")
    }
    private var emptyHistory: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("No posters yet").font(.display(25)).fixedSize(horizontal: false, vertical: true)
            Text("Try a title below, or play a film on your Mac. Its reporter passes the name to your wall.").font(.ui(15)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 6)
    }
    private var lookup: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Find a poster").font(.ui(22, .semibold))
            TextField("Film or series title", text: $title).font(.ui(16)).padding(16)
                .background(Ink.ink.opacity(0.055), in: RoundedRectangle(cornerRadius: 12)).submitLabel(.search)
                .onSubmit { if canLookup { check(title: title.trimmingCharacters(in: .whitespacesAndNewlines)) } }
                .accessibilityLabel("Film or series title").accessibilityIdentifier("posters.title")
            CreativeConnectionAction(title: working ? "Checking…" : "Look up title", tint: gold, busy: working, enabled: canLookup) {
                check(title: title.trimmingCharacters(in: .whitespacesAndNewlines))
            }.accessibilityIdentifier("posters.lookup")
            // A lookup no longer replaces the Mac's latest match, so its
            // own answer is shown here, under the button that asked.
            if tmdb?.state == "matched", let checked = tmdb?.checked { recentPoster(checked, lookup: true) }
            if tmdb?.state == "no_match" {
                Text("No poster matched. Try the film or series name without an episode number.").font(.ui(14)).foregroundStyle(gold)
                    .accessibilityIdentifier("posters.noMatch")
            }
            Text("Checks TMDB without changing your wall. Series are searched before films.").font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var canLookup: Bool {
        let typed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return wall.link.isLive && ready && !working && !typed.isEmpty && typed.count <= 240 && (tmdb?.retry_after ?? 0) == 0
    }
    private var keyManagement: some View {
        DisclosureGroup(isExpanded: $editing) { credentials.padding(.top, 18) } label: {
            Text("Manage TMDB key").font(.ui(17, .semibold)).foregroundStyle(Ink.ink).frame(minHeight: 48)
                .accessibilityIdentifier("posters.manage")
        }.tint(gold)
    }
    private var credentials: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(ready ? "Your TMDB connection" : "Connect TMDB").font(.ui(22, .semibold)).fixedSize(horizontal: false, vertical: true)
            CreativeCredentialField(title: "API key or read access token", hint: ready ? "Paste a replacement key" : "Paste your TMDB key", text: $key, secure: true)
                .accessibilityIdentifier("posters.key")
            CreativeConnectionAction(title: busy ? "Saving…" : "Save key", tint: gold, busy: busy, enabled: canSave) {
                save(typedKey.hasPrefix("eyJ") ? typedKey : typedKey.lowercased())
            }.accessibilityIdentifier("posters.save")
            if ready {
                Button { check() } label: {
                    Label(tmdb?.checking == true ? "Checking TMDB…" : "Check saved key", systemImage: "arrow.clockwise").font(.ui(15, .semibold)).frame(minHeight: 44)
                }.disabled(working || !wall.link.isLive || (tmdb?.retry_after ?? 0) > 0).accessibilityIdentifier("posters.check")
                if let retry = tmdb?.retry_after, retry > 3 {
                    Text("Try again in about \(retry) seconds.").font(.ui(13)).foregroundStyle(Ink.dim)
                }
            }
            Button { openURL(URL(string: "https://www.themoviedb.org/settings/api")!) } label: {
                Label("Get a key from TMDB", systemImage: "arrow.up.right").font(.ui(14, .medium)).frame(minHeight: 44)
            }.foregroundStyle(gold)
            Text("Use a 32-character API key or an API Read Access Token. Saving stores it on your wall. Checking confirms whether TMDB accepts it.")
                .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            if ready {
                Divider().overlay(gold.opacity(0.15))
                if removing {
                    Text("Remove the key from this wall? Automatic poster lookup will stop. Previously found posters stay in the journal.").font(.ui(14)).foregroundStyle(Ink.dim)
                    Button("Remove TMDB key", role: .destructive) { save("") }.font(.ui(15, .semibold)).frame(minHeight: 44)
                        .disabled(working || !wall.link.isLive).accessibilityIdentifier("posters.confirmRemove")
                    Button("Keep connected") { removing = false }.font(.ui(15)).frame(minHeight: 44)
                } else {
                    Button("Remove key from this wall", role: .destructive) { removing = true }.font(.ui(14, .medium)).frame(minHeight: 44)
                        .disabled(working || !wall.link.isLive).accessibilityIdentifier("posters.remove")
                }
            }
        }
    }
    private var reporterLink: some View {
        NavigationLink { MacReporterPage(accent: accent, services: $services) } label: {
            HStack(spacing: 16) {
                Image(systemName: "laptopcomputer").font(.system(size: 23)).foregroundStyle(gold)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connect your Mac").font(.ui(16, .semibold))
                    Text("Its reporter sends the titles of films and series.").font(.ui(13)).foregroundStyle(Ink.dim)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(gold)
            }.padding(.vertical, 15)
        }.buttonStyle(.plain).accessibilityIdentifier("posters.mac")
    }
    private var attribution: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(gold.opacity(0.12))
            Image("TMDBMark").resizable().scaledToFit().frame(width: 148, height: 20).accessibilityLabel("The Movie Database")
            Text("Posters & film information by TMDB").font(.ui(12, .medium)).foregroundStyle(gold)
            Text("This product uses the TMDB API but is not endorsed or certified by TMDB. Your key stays on the wall. Titles are sent to TMDB for matching.")
                .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func reset(host: String) {
        sourceHost = host; revision = UUID(); key = ""; title = ""; busy = false; loading = true
        problem = nil; feedback = nil; readFailed = false; removing = false; services = nil
    }
    private func refresh() async {
        guard !busy else { return }
        let host = wall.host, id = revision
        let fresh = await WallServices.read(host: host)
        guard !Task.isCancelled, wall.host == host, revision == id else { return }
        loading = false; readFailed = fresh == nil
        if let fresh { services = fresh }
    }
    private func save(_ value: String) {
        guard wall.link.isLive, !working else { return }
        let host = wall.host, id = UUID(); revision = id; busy = true; problem = nil; feedback = nil
        Task {
            let (fresh, why) = await ServiceSave.send(["tmdb": ["api_key": value]], to: host)
            guard !Task.isCancelled, wall.host == host, revision == id else { return }
            revision = UUID(); busy = false
            if let fresh { services = fresh; readFailed = false }
            problem = why
            if why == nil { key = ""; removing = false; editing = !value.isEmpty; feedback = value.isEmpty ? "Key removed from this wall" : "Key saved. Check it when you're ready."; Taps.commit() }
        }
    }
    private func check(title: String? = nil) {
        guard wall.link.isLive, !working, ready else { return }
        let host = wall.host, id = UUID(); revision = id; busy = true; problem = nil; feedback = nil
        Task {
            let outcome = await WallServices.checkPosters(host: host, title: title ?? "")
            guard !Task.isCancelled, wall.host == host, revision == id else { return }
            revision = UUID(); busy = false
            if let fresh = outcome.services { services = fresh; readFailed = false; Taps.commit() }
            // The wall's own words when it refused (a 400 says what to type
            // instead). The generic line only when it said nothing usable.
            else { problem = outcome.error ?? "The check couldn't start. Wait a moment, then try again." }
        }
    }
}

private struct PosterAperture: View {
    let tint: Color
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(x: 0, y: 8, width: size.width, height: size.height - 16)
            context.fill(Path(roundedRect: rect, cornerRadius: 6), with: .color(tint.opacity(0.055)))
            for index in 0..<20 {
                let x = CGFloat(index) * size.width / 20 + 5
                for y in [CGFloat(13), size.height - 18] {
                    context.fill(Path(roundedRect: CGRect(x: x, y: y, width: 7, height: 5), cornerRadius: 1), with: .color(tint.opacity(0.36)))
                }
            }
            for index in 0..<5 {
                let width = (size.width - 36) / 5
                let frame = CGRect(x: 12 + CGFloat(index) * (width + 3), y: 26, width: width, height: size.height - 52)
                context.fill(Path(frame), with: .linearGradient(Gradient(colors: [tint.opacity(0.14 + Double(index) * 0.045), tint.opacity(0.025)]), startPoint: frame.origin, endPoint: CGPoint(x: frame.maxX, y: frame.maxY)))
            }
        }
    }
}

extension WallServices {
    struct Tmdb: Decodable {
        struct Last: Decodable {
            var title: String
            var kind: String?
            var year: Int?
            var at: Int?
            var poster: String?
            var id: Int?
            var overview: String?
        }
        var key_set: Bool
        var posters: Int?
        var known: Int?
        var last: Last?
        /// This page's own lookup. The wall keeps it apart from `last`, the
        /// poster the Mac's reporter found. Older walls leave it out.
        var checked: Last?
        var problem: String?
        var state: String?
        var checking: Bool?
        var verified: Bool?
        var checked_at: Double?
        var retry_after: Int?
    }
}
