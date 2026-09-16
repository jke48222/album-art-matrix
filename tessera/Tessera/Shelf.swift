// The collection is a catalogue of physical objects: covers, names and
// pressing facts. The wall owns the data; this page holds only its draft.
import SwiftUI

struct ShelfRelease: Decodable, Identifiable {
    struct Label: Decodable { var name: String; var catno: String? }
    struct Price: Decodable {
        struct Amount: Decodable { var currency: String; var value: Double }
        var lowest_price: Amount?
        var num_for_sale: Int?
    }
    var id: Int
    var title: String
    var artists: [String]
    var year: Int?
    var labels: [Label]
    var country: String
    var cover: String
    var rating: Int
    var played: Int
    var url: String
    var marketplace: Price?

    var facts: String {
        [year.flatMap { $0 > 0 ? String($0) : nil }, labels.first?.name,
         country.isEmpty ? nil : country, labels.first?.catno]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    var price: String {
        guard let amount = marketplace?.lowest_price else {
            return marketplace == nil ? "Price not checked yet" : "No copies listed"
        }
        return "From \(amount.value.formatted(.currency(code: amount.currency))) on Discogs"
    }
}

struct ShelfSnapshot: Decodable {
    var enabled: Bool
    var user: String
    var token_set: Bool
    var busy: Bool
    var synced: Double?
    var page: Int?
    var count: Int
    var problem: String?
    var rows: [ShelfRelease]
    var current: [ShelfRelease]
}

struct ShelfPage: View {
    @Environment(WallSession.self) private var wall
    let accent: Color
    @State private var snapshot: ShelfSnapshot?
    @State private var username = ""
    @State private var token = ""
    @State private var query = ""
    @State private var problem: String?
    @State private var saving = false
    @State private var loadedUser = false

    private var shown: [ShelfRelease] {
        (snapshot?.rows ?? []).filter {
            query.isEmpty || "\($0.title) \($0.artists.joined(separator: " "))".localizedCaseInsensitiveContains(query)
        }.sorted { ($0.artists.first ?? "", $0.title) < ($1.artists.first ?? "", $1.title) }
    }

    var body: some View {
        SetupPage("The shelf", blurb: "The records you can reach for. Your Discogs collection, kept by the wall.") {
            HStack(alignment: .firstTextBaseline) {
                Text("\(snapshot?.count ?? 0)").font(.displayMid(64)).foregroundStyle(Ink.ink)
                VStack(alignment: .leading, spacing: 5) {
                    Text("RECORDS").font(.machine(10)).kerning(1.4).foregroundStyle(Ink.dim)
                    Text(snapshot?.busy == true ? "Syncing page \(snapshot?.page ?? 1)" : snapshot?.synced.map {
                        "Updated \(Date(timeIntervalSince1970: $0).formatted(.relative(presentation: .named)))"
                    } ?? "Connect your collection below")
                        .font(.ui(12)).foregroundStyle(Ink.dim)
                }
                Spacer()
            }.padding(.vertical, 6)

            if let current = snapshot?.current, !current.isEmpty {
                SetupGroup(current.count > 1 ? "Matching pressings" : "On the wall", note: current.count > 1 ? "You own more than one pressing of this album." : nil) {
                    ForEach(current) { row in
                        ShelfReleaseRow(row: row, detailed: true)
                    }
                }
            }

            SetupGroup("Discogs", note: "A personal token reads your collection. It stays on the wall. A second phone sees the same shelf.") {
                TextField("Discogs username", text: $username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().padding(16)
                Rule()
                SecureField(snapshot?.token_set == true ? "Token is saved" : "Personal access token", text: $token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().padding(16)
                Rule()
                Link(destination: URL(string: "https://www.discogs.com/settings/developers")!) {
                    SetupRow(title: "Get a token", subtitle: "Discogs developer settings") {
                        Image(systemName: "arrow.up.right").foregroundStyle(Ink.dim)
                    }
                }
                SaveLine(title: "Save to the wall", enabled: !username.isEmpty, busy: saving,
                         done: snapshot?.token_set == true ? "Connected" : nil, accent: accent) { save(clear: false) }
                if snapshot?.token_set == true {
                    SetupRow(title: "Remove token", subtitle: "The cached collection remains available.") {
                        ActionPill(title: "Remove", filled: false) { save(clear: true) }
                    }
                }
            }
            Problem(text: problem ?? snapshot?.problem)

            SetupGroup("Collection", note: snapshot?.enabled == false ? "This build's shelf feature is off." : nil) {
                TextField("Find a record or artist", text: $query)
                    .font(.ui(16)).padding(16)
                Rule()
                if snapshot == nil {
                    HStack { ProgressView(); Text("Reading the shelf").font(.ui(14)) }.padding(16)
                } else if shown.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(query.isEmpty ? "A place for your records." : "No matching record.").font(.displayMid(22))
                        Text(query.isEmpty ? "Connect Discogs above. Covers will appear here after the first sync." : "Try another title or artist.")
                            .font(.ui(14)).foregroundStyle(Ink.dim)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(shown) { row in
                            ShelfReleaseRow(row: row, detailed: false)
                            Rule()
                        }
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    private func refresh() async {
        guard let url = URL(string: "http://\(wall.host)/shelf") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let fresh = try JSONDecoder().decode(ShelfSnapshot.self, from: data)
            snapshot = fresh
            if !loadedUser { username = fresh.user; loadedUser = true }
            problem = nil
        } catch { problem = "The shelf is offline. Showing the last collection received." }
    }

    private func save(clear: Bool) {
        guard !saving else { return }
        saving = true
        var fields = ["user": username]
        if clear { fields["token"] = "" }
        else if !token.isEmpty { fields["token"] = token }
        Task {
            let (_, why) = await ServiceSave.send(["discogs": fields], to: wall.host)
            problem = why
            if why == nil { token = ""; await refresh(); Taps.commit() }
            saving = false
        }
    }
}

private struct ShelfReleaseRow: View {
    let row: ShelfRelease
    let detailed: Bool
    var body: some View {
        Link(destination: URL(string: row.url) ?? URL(string: "https://www.discogs.com")!) {
            HStack(alignment: .top, spacing: 16) {
                AsyncImage(url: URL(string: row.cover)) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(Ink.plaster)
                        .overlay(Image(systemName: "opticaldisc").foregroundStyle(Ink.faint))
                }
                .frame(width: detailed ? 80 : 56, height: detailed ? 80 : 56).clipped()
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.title).font(.ui(16, .semibold)).foregroundStyle(Ink.ink)
                    Text(row.artists.joined(separator: ", ")).font(.ui(13)).foregroundStyle(Ink.dim)
                    if detailed {
                        Text(row.facts).font(.machine(10)).foregroundStyle(Ink.dim)
                        Text(row.price).font(.ui(12)).foregroundStyle(Ink.dim)
                    } else {
                        Text("\(row.played) plays · \(row.rating)/5").font(.machine(10)).foregroundStyle(Ink.faint)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.right").font(.system(size: 11)).foregroundStyle(Ink.faint)
            }.padding(16).contentShape(Rectangle())
        }
    }
}

struct ShelfPressingBadge: View {
    @Environment(WallSession.self) private var wall
    @State private var matches: [ShelfRelease] = []
    var body: some View {
        Group {
            if let row = matches.first {
                Link(destination: URL(string: row.url) ?? URL(string: "https://www.discogs.com")!) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(matches.count > 1 ? "\(matches.count) PRESSINGS ON YOUR SHELF" : "ON YOUR SHELF")
                            .font(.machine(9)).kerning(1.1)
                        Text(row.facts).font(.ui(11))
                        Text(row.price).font(.ui(11))
                    }
                    .foregroundStyle(Ink.dim)
                    .padding(.vertical, 8)
                }
            }
        }.task {
            while !Task.isCancelled {
                if let url = URL(string: "http://\(wall.host)/shelf/current") {
                    var request = URLRequest(url: url); request.timeoutInterval = 4
                    if let (data, response) = try? await URLSession.shared.data(for: request),
                       (response as? HTTPURLResponse)?.statusCode == 200,
                       let fresh = try? JSONDecoder().decode([ShelfRelease].self, from: data) { matches = fresh }
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }
}
