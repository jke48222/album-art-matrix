import SwiftUI

struct ClaudePage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    let accent: Color
    @Binding var services: WallServices?
    @State private var key = ""
    @State private var workspace = ""
    @State private var editing = false
    @State private var workspaceOpen = false
    @State private var removing = false
    @State private var busy = false
    @State private var loading = true
    @State private var readFailed = false
    @State private var problem: String?
    @State private var feedback: String?
    @State private var revision = UUID()
    @State private var sourceHost = ""
    private let clay = Color(hex: 0xDBA38B)
    private var claude: WallServices.Claude? { services?.claude }
    private var ready: Bool { claude?.isReady == true }
    private var typedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var typedWorkspace: String { workspace.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Keyed on the wall's code: a 403 also mentions a workspace, but only
    /// this problem is fixed by the workspace field.
    private var needsWorkspace: Bool { claude?.problem_code == "needs_workspace" }
    /// Nothing read yet from this wall: its saved status is unknown, so the
    /// page must not ask a connected person to connect.
    private var unknown: Bool { services == nil && (!wall.link.isLive || readFailed) }
    private var off: Bool { claude?.isOff == true }
    private var statusTitle: String {
        if !wall.link.isLive { return "Wall offline" }
        if loading && claude == nil { return "Checking the wall" }
        if readFailed { return "Status unavailable" }
        if off { return "Turned off on this wall" }
        if claude?.pending == true { return "Answering" }
        if claude?.problem != nil { return "Needs attention" }
        return ready ? "Key saved on the wall" : "Not connected"
    }
    private var canSave: Bool {
        guard wall.link.isLive, services != nil, !busy, !off else { return false }
        let validKey = typedKey.range(of: "^sk-ant-[A-Za-z0-9_-]{20,200}$", options: .regularExpression) != nil
        let validWorkspace = typedWorkspace.range(of: "^wrkspc_[A-Za-z0-9_-]{4,80}$", options: .regularExpression) != nil
        return (typedKey.isEmpty || validKey) && (typedWorkspace.isEmpty || validWorkspace)
            && (validKey || (ready && validWorkspace))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                hero
                if !wall.link.isLive {
                    CreativeConnectionNotice(title: "Your wall is offline", detail: unknown ? "Reconnect to read the key status on your wall." : "Reconnect to manage the key. Any saved status below is from the last read.", symbol: "wifi.slash", tint: clay)
                    if unknown { Button("Try again") { Task { await refresh() } }.font(.ui(16, .semibold)).foregroundStyle(clay).frame(minHeight: 44) }
                } else if readFailed {
                    CreativeConnectionNotice(title: "Couldn't read this connection", detail: "The key on your wall hasn't changed.", symbol: "exclamationmark.circle", tint: clay)
                    Button("Try again") { Task { await refresh() } }.font(.ui(16, .semibold)).foregroundStyle(clay).frame(minHeight: 44)
                }
                if loading && claude == nil {
                    ProgressView("Reading Claude status").font(.ui(15)).tint(clay).frame(maxWidth: .infinity, minHeight: 90)
                } else if unknown {
                    // Status unknown: the notice above carries the retry.
                } else if off {
                    // A key saved here would not be used, so there is no editor.
                    CreativeConnectionNotice(title: "Turned off on this wall", detail: "Asking Claude is switched off in this wall's features. Turn it on there before adding a key.", symbol: "power", tint: clay)
                        .accessibilityIdentifier("claude.off")
                } else {
                    if let issue = problem ?? claude?.problem {
                        CreativeConnectionNotice(title: "Needs attention", detail: issue, symbol: "exclamationmark.circle", tint: clay)
                    }
                    if ready {
                        askLink
                        if typeSize.isAccessibilitySize { keyManagement }
                        if let last = claude?.last { recentQuestion(last) }
                        connectionFacts
                        if !typeSize.isAccessibilitySize { keyManagement }
                    } else { credentials }
                    if let feedback {
                        Label(feedback, systemImage: "checkmark.circle").font(.ui(14)).foregroundStyle(clay).fixedSize(horizontal: false, vertical: true)
                    }
                }
                privacy
            }.padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 40)
        }
        .scrollIndicators(.hidden).background(Color(hex: 0x171513)).foregroundStyle(Ink.ink)
        .navigationTitle("Claude").navigationBarTitleDisplayMode(.inline).tint(clay)
        .refreshable { await refresh() }
        .task(id: "\(wall.host)|\(scenePhase)") {
            guard scenePhase == .active else { return }
            if sourceHost.isEmpty { sourceHost = wall.host }
            else if sourceHost != wall.host { reset(host: wall.host) }
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(claude?.pending == true ? 2 : 8))
            }
        }
        .onChange(of: wall.host) { _, host in reset(host: host) }
        .onChange(of: needsWorkspace) { _, needed in if needed { editing = true; workspaceOpen = true } }
        .onDisappear { key = ""; workspace = ""; revision = UUID(); busy = false }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: typeSize.isAccessibilitySize ? 12 : 19) {
            HStack(spacing: 10) {
                Image(systemName: "text.bubble").font(.system(size: 21, weight: .medium))
                Text("CLAUDE").font(.machine(typeSize.isAccessibilitySize ? 10 : 12)).tracking(2)
                Spacer(minLength: 0)
            }.foregroundStyle(clay)
            if !typeSize.isAccessibilitySize {
                Text("Questions and answers").font(.display(38)).tracking(-1).fixedSize(horizontal: false, vertical: true)
                ClaudeSignal(tint: clay).frame(height: 76).accessibilityHidden(true)
            }
            Group {
                if typeSize.isAccessibilitySize { Text(statusTitle).font(.ui(12, .medium)) }
                else { Label(statusTitle, systemImage: !wall.link.isLive ? "wifi.slash" : ready && claude?.problem == nil ? "checkmark.circle" : "circle.dotted").font(.ui(14, .medium)) }
            }.foregroundStyle(clay).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("claude.status")
            if !ready && !unknown && !off {
                Text("Ask questions about your music and the wall. Add your Claude API key to begin.")
                    .font(.ui(16)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var askLink: some View {
        NavigationLink { AskPage(accent: accent) } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ask the wall").font(.ui(typeSize.isAccessibilitySize ? 17 : 22, .semibold)).fixedSize(horizontal: false, vertical: true)
                    if !typeSize.isAccessibilitySize { Text("Write a question, read the answer.").font(.ui(14)).foregroundStyle(Color(hex: 0x4B3630)) }
                }
                Spacer(minLength: 0)
                if !typeSize.isAccessibilitySize { Image(systemName: "arrow.up.right").font(.system(size: 22, weight: .medium)) }
            }.foregroundStyle(Color(hex: 0x211C18)).padding(22).frame(maxWidth: .infinity, alignment: .leading)
                .background(clay, in: RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(.plain).accessibilityIdentifier("claude.openAsk")
    }
    private func recentQuestion(_ last: WallServices.Claude.Last) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
            layout {
                Text("Last conversation").font(.ui(13, .medium)).foregroundStyle(clay).fixedSize(horizontal: false, vertical: true)
                if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                if let ts = last.ts { Text(Date(timeIntervalSince1970: Double(ts)), style: .date).font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true) }
            }
            Text(last.q).font(.ui(20, .medium)).fixedSize(horizontal: false, vertical: true)
            Text(last.a).font(.ui(15)).foregroundStyle(Ink.dim).lineLimit(4)
            if last.a.count > 180 { Text("Read the full answer in Ask the wall").font(.ui(12)).foregroundStyle(clay) }
        }.padding(.vertical, 6).accessibilityElement(children: .combine)
    }
    private var connectionFacts: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider().overlay(clay.opacity(0.16))
            CreativeConnectionFact(title: "Model", value: claude?.model ?? "Not reported")
            CreativeConnectionFact(title: "Answers this session", value: claude?.answers.map(String.init) ?? "Not reported")
            Divider().overlay(clay.opacity(0.16))
        }
    }
    private var keyManagement: some View {
        DisclosureGroup(isExpanded: $editing) {
            credentials.padding(.top, 20)
        } label: {
            Text("Manage API key").font(.ui(17, .semibold)).foregroundStyle(Ink.ink)
                .fixedSize(horizontal: false, vertical: true).frame(minHeight: 48)
                .accessibilityIdentifier("claude.manage")
        }.tint(clay)
    }
    private var credentials: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(ready ? "Replace your key" : "Your API key").font(.ui(22, .semibold))
            CreativeCredentialField(title: "Claude API key", hint: ready ? "Paste a replacement key" : "sk-ant-…", text: $key, secure: true)
                .accessibilityIdentifier("claude.key")
            DisclosureGroup(isExpanded: $workspaceOpen) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Only add this for a key that can access multiple workspaces. Find the ID in Claude Console, then Settings, then Workspaces.").font(.ui(14)).foregroundStyle(Ink.dim)
                    CreativeCredentialField(title: "Workspace ID", hint: claude?.workspace_set == true ? "Replace saved workspace ID" : "wrkspc_…", text: $workspace, secure: true)
                        .accessibilityIdentifier("claude.workspace")
                    if claude?.workspace_set == true {
                        Button("Remove workspace ID") { save(["workspace": ""], receipt: "Workspace ID removed") }
                            .font(.ui(14, .medium)).frame(minHeight: 44).disabled(busy || !wall.link.isLive)
                    }
                }.padding(.top, 12)
            } label: { Text(needsWorkspace ? "Workspace needed" : "Workspace, if needed").font(.ui(15, .medium)).foregroundStyle(clay).frame(minHeight: 44) }
            CreativeConnectionAction(title: busy ? "Saving…" : ready ? "Save changes" : "Save API key", tint: clay, busy: busy, enabled: canSave) {
                var patch: [String: String] = [:]
                if !typedKey.isEmpty { patch["api_key"] = typedKey }
                if !typedWorkspace.isEmpty { patch["workspace"] = typedWorkspace }
                save(patch, receipt: "Key saved on your wall. Open Ask the wall to try it.")
            }.accessibilityIdentifier("claude.save")
            Button { openURL(URL(string: "https://platform.claude.com/settings/keys")!) } label: {
                Label("Create a key in Claude Console", systemImage: "arrow.up.right").font(.ui(14, .medium)).frame(minHeight: 44, alignment: .leading)
            }.foregroundStyle(clay)
            Text("API usage is billed by Anthropic, separately from a Claude subscription. Your actual model and token usage determine the cost.")
                .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            if ready {
                Divider().overlay(clay.opacity(0.16))
                if removing {
                    Text("Remove the key from this wall? Questions and AI features will stop until a key is added. Your API key remains active in Claude Console.")
                        .font(.ui(14)).foregroundStyle(Ink.dim)
                    Button("Remove API key", role: .destructive) { save(["api_key": "", "workspace": ""], receipt: "API key removed from this wall") }
                        .font(.ui(15, .semibold)).frame(minHeight: 44).disabled(busy || !wall.link.isLive).accessibilityIdentifier("claude.confirmRemove")
                    Button("Keep connected") { removing = false }.font(.ui(15)).frame(minHeight: 44)
                } else {
                    Button("Remove key from this wall", role: .destructive) { removing = true }
                        .font(.ui(14, .medium)).frame(minHeight: 44).disabled(busy || !wall.link.isLive).accessibilityIdentifier("claude.remove")
                }
            }
        }
    }
    private var privacy: some View {
        Label {
            Text("Your key stays on your wall. Questions and the wall context needed to answer them are sent to Anthropic.")
                .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        } icon: { Image(systemName: "lock").font(.system(size: 14)).foregroundStyle(clay) }
            .padding(.top, 6)
    }
    private func reset(host: String) {
        sourceHost = host; revision = UUID(); key = ""; workspace = ""; busy = false
        problem = nil; feedback = nil; readFailed = false; loading = true; removing = false
        if !host.isEmpty { services = nil }
    }
    private func refresh() async {
        guard !busy else { return }
        let host = wall.host, id = revision
        let fresh = await WallServices.read(host: host)
        guard !Task.isCancelled, wall.host == host, id == revision else { return }
        loading = false; readFailed = fresh == nil
        if let fresh { services = fresh; if needsWorkspace { editing = true; workspaceOpen = true } }
    }
    static func took(_ patch: [String: String], _ claude: WallServices.Claude?) -> Bool {
        guard let claude, !claude.isOff else { return false }
        if let key = patch["api_key"], claude.isReady == key.isEmpty { return false }
        if let space = patch["workspace"], let set = claude.workspace_set, set == space.isEmpty { return false }
        return true
    }
    private func save(_ patch: [String: String], receipt: String) {
        guard wall.link.isLive, !busy else { return }
        let host = wall.host, id = UUID(); revision = id; busy = true; problem = nil; feedback = nil
        Task {
            let (fresh, why) = await ServiceSave.send(["claude": patch], to: host)
            guard !Task.isCancelled, wall.host == host, revision == id else { return }
            revision = UUID(); busy = false
            if let fresh { services = fresh; readFailed = false }
            // A receipt only when the saved value is now in use on the wall.
            if why == nil, !Self.took(patch, fresh?.claude) {
                problem = fresh?.claude?.isOff == true ? "Asking Claude is turned off on this wall, so the key is not in use." : "The wall has not confirmed this change. Check again in a moment."
                return
            }
            problem = why
            if why == nil { key = ""; workspace = ""; removing = false; editing = false; feedback = receipt; Taps.commit() }
        }
    }
}

private struct ClaudeSignal: View {
    let tint: Color
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
            for index in 0..<25 {
                let x = CGFloat(index) * size.width / 24
                let distance = abs(x - center.x) / max(1, center.x)
                let height = 7 + (1 - pow(distance, 0.7)) * 52
                let rect = CGRect(x: x, y: center.y - height / 2, width: 2, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(tint.opacity(0.3 + (1 - distance) * 0.65)))
            }
            context.stroke(Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 0.5)), with: .color(tint.opacity(0.12)))
        }
    }
}

struct CreativeConnectionNotice: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.ui(16, .semibold)).foregroundStyle(tint)
            Text(detail).font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 14)).accessibilityElement(children: .combine)
    }
}
struct CreativeCredentialField: View {
    let title: String
    let hint: String
    @Binding var text: String
    var secure = false
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.ui(13, .medium)).foregroundStyle(Ink.dim)
            Group {
                if secure { SecureField(hint, text: $text).privacySensitive() }
                else { TextField(hint, text: $text) }
            }.font(.ui(16)).foregroundStyle(Ink.ink).textInputAutocapitalization(.never)
                .autocorrectionDisabled().keyboardType(.asciiCapable).submitLabel(.done)
                .padding(16).frame(minHeight: 56).background(Ink.ink.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.ink.opacity(0.1)))
                .accessibilityLabel(title)
        }
    }
}
struct CreativeConnectionAction: View {
    let title: String
    let tint: Color
    var busy = false
    var enabled = true
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if busy { ProgressView().tint(Color(hex: 0x211C18)) }
                Text(title).font(.ui(16, .semibold)).fixedSize(horizontal: false, vertical: true)
            }.foregroundStyle(Color(hex: 0x211C18)).frame(maxWidth: .infinity, minHeight: 52)
                .padding(.horizontal, 16).padding(.vertical, 4).background(tint, in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain).disabled(!enabled || busy).opacity(enabled || busy ? 1 : 0.42)
    }
}
struct CreativeConnectionFact: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    let value: String
    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 7)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 16))
        layout {
            Text(title).font(.ui(13)).foregroundStyle(Ink.dim)
            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            Text(value).font(.ui(14, .medium)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }
}

extension WallServices {
    struct Claude: Decodable {
        struct Last: Decodable { var q: String; var a: String; var s: Double?; var usd: Double?; var ts: Int? }
        var ready: Bool?
        var key_set: Bool?
        var workspace_set: Bool?
        var pending: Bool?
        var history: [Last]?
        var isReady: Bool { ready ?? key_set ?? false }
        var model: String?
        var answers: Int?
        var cost_usd: Double?
        var last: Last?
        var problem: String?
        var problem_code: String?       // "needs_workspace" and others, see brain/ask.py
        var state: String?              // "off" when asking is switched off on the wall
        /// Off: the wall has no Asker. An Asker always reports its model and
        /// workspace; the wall's stand-in for a switched-off feature does not.
        var isOff: Bool { state == "off" || (ready != true && model == nil && workspace_set == nil) }
    }
}
