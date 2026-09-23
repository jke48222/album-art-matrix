import SwiftUI

extension ShelfList.Release: Identifiable { var id: Int { release_id } }

struct ShelfPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.dynamicTypeSize) private var typeSize
    let accent: Color
    @State private var shelf: ShelfList?
    @State private var loading = true
    @State private var failed = false
    @State private var query = ""
    @State private var selected: ShelfList.Release?
    @State private var requestID = UUID()
    @State private var sourceHost = ""
    @State private var services: WallServices?
    private var releases: [ShelfList.Release] {
        (shelf?.releases ?? []).filter { query.isEmpty || ([$0.title] + $0.artists).joined(separator: " ").localizedStandardContains(query) }
            .sorted { $0.plays == $1.plays ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : $0.plays > $1.plays }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("YOUR DISCOGS COLLECTION", systemImage: "opticaldisc").font(.machine(8)).tracking(1).foregroundStyle(accent.toned(forDark: true))
                    Text("The record shelf").font(.display(typeSize.isAccessibilitySize ? 20 : 35)).foregroundStyle(Ink.ink)
                    Text("The pressings you own, down to the catalogue number.").font(.ui(14)).foregroundStyle(Ink.dim)
                }
                if loading && shelf == nil { ProgressView("Reading your collection").tint(accent).frame(maxWidth: .infinity, minHeight: 160) }
                else if failed {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("The collection couldn’t be loaded.", systemImage: "wifi.slash").font(.ui(15)).foregroundStyle(Ink.ink)
                        Button("Try again") { Task { await load() } }.font(.ui(14, .semibold)).frame(minHeight: 44)
                    }
                }
                if let shelf, shelf.releases.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Image(systemName: "square.stack").font(.system(size: 44, weight: .ultraLight)).foregroundStyle(accent)
                        Text("A place for every pressing.").font(.displayMid(25)).foregroundStyle(Ink.ink)
                        Text("Connect Discogs in Settings → Services to bring your collection here. Owned albums get a small record mark on the wall.").font(.ui(14)).foregroundStyle(Ink.dim)
                        NavigationLink { DiscogsPage(accent: accent, services: $services) } label: {
                            Label("Open Discogs", systemImage: "arrow.right").font(.ui(15, .semibold)).frame(minHeight: 44)
                        }
                    }.padding(.vertical, 24)
                } else if shelf != nil {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(Ink.dim)
                        TextField("Album or artist", text: $query).font(.ui(15)).autocorrectionDisabled()
                        if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }.accessibilityLabel("Clear collection search") }
                    }.padding(.horizontal, 14).frame(minHeight: 50).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 14))
                    if releases.isEmpty { ContentUnavailableView.search(text: query) }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: typeSize.isAccessibilitySize ? 1 : 2), alignment: .leading, spacing: 24) {
                        ForEach(releases) { release in
                            Button { selected = release } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    ReleaseCover(url: release.cover)
                                    Text(release.title).font(.ui(15, .semibold)).foregroundStyle(Ink.ink).lineLimit(2)
                                    Text(release.artists.joined(separator: ", ")).font(.ui(12)).foregroundStyle(Ink.dim).lineLimit(2)
                                    Text([release.year.map(String.init), release.formats?.first].compactMap { $0 }.joined(separator: " · "))
                                        .font(.machine(9)).foregroundStyle(Ink.dim)
                                    if release.plays > 0 { Label("\(release.plays) on the wall", systemImage: "waveform").font(.ui(11)).foregroundStyle(accent.toned(forDark: true)) }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(PressStyle(scale: 0.98)).accessibilityLabel("\(release.title), \(release.artists.joined(separator: ", ")), view pressing")
                        }
                    }
                }
            }.padding(24)
        }.background(Ink.ground).foregroundStyle(Ink.ink).navigationBarTitleDisplayMode(.inline)
            .task(id: wall.host) {
                await load()
                let host = wall.host
                let result = await WallServices.read(host: host)
                if !Task.isCancelled, wall.host == host { services = result }
            }.refreshable { await load() }
            .sheet(item: $selected) { release in ReleaseDetail(release: release, accent: accent) }
    }
    private func load() async {
        let host = wall.host
        let id = UUID()
        requestID = id
        if sourceHost != host { shelf = nil; sourceHost = host }
        loading = true
        defer { if requestID == id { loading = false } }
        let result = await ShelfList.read(host: host)
        guard !Task.isCancelled, wall.host == host, requestID == id else { return }
        failed = result == nil
        if let result { shelf = result }
    }
}

private struct ReleaseCover: View {
    let url: String?
    var body: some View {
        GeometryReader { geometry in
            AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
                else {
                    Rectangle().fill(Ink.plaster).overlay(Image(systemName: "opticaldisc").font(.system(size: 34, weight: .light)).foregroundStyle(Ink.dim))
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
    }
}

private struct ReleaseDetail: View {
    @Environment(\.dismiss) private var dismiss
    let release: ShelfList.Release
    let accent: Color
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ReleaseCover(url: release.cover)
                    VStack(alignment: .leading, spacing: 8) {
                        Label("IN YOUR COLLECTION", systemImage: "checkmark.seal").font(.machine(9)).foregroundStyle(accent.toned(forDark: true))
                        Text(release.title).font(.display(30)).foregroundStyle(Ink.ink)
                        Text(release.artists.joined(separator: ", ")).font(.ui(17)).foregroundStyle(Ink.dim)
                    }
                    VStack(spacing: 14) {
                        detail("Year", release.year.map(String.init))
                        detail("Label", release.label)
                        detail("Catalogue", release.catno)
                        detail("Country", release.country)
                        detail("Format", release.formats?.joined(separator: ", "))
                    }.padding(18).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 18))
                    if let url = URL(string: release.url), ["https", "http"].contains(url.scheme ?? "") {
                        Link(destination: url) { Label("View pressing on Discogs", systemImage: "arrow.up.right").font(.ui(15, .semibold)).frame(maxWidth: .infinity, minHeight: 52) }
                            .foregroundStyle(Ink.ground).background(accent.toned(forDark: true), in: RoundedRectangle(cornerRadius: 16))
                    }
                }.padding(24)
            }.background(Ink.ground).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.frame(minHeight: 44) } }
        }.preferredColorScheme(.dark).tint(accent.toned(forDark: true))
    }
    @ViewBuilder private func detail(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text(label).font(.ui(13)).foregroundStyle(Ink.dim)
                Spacer(minLength: 0)
                Text(value).font(.ui(14, .medium)).foregroundStyle(Ink.ink).multilineTextAlignment(.trailing)
            }.accessibilityElement(children: .combine)
        }
    }
}
