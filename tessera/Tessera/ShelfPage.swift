import SwiftUI

struct ShelfPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let accent: Color
    @AppStorage("shelfOrder") private var savedOrder = ShelfOrder.recent.rawValue
    @State private var shelf: ShelfList?
    @State private var loading = true
    @State private var readFailed = false
    @State private var query = ""
    @State private var services: WallServices?
    @State private var sourceHost = ""
    @State private var readID = UUID()
    @State private var actionID = UUID()
    @State private var submitting = false
    @State private var awaitedSync: String?
    @State private var feedback: String?
    @State private var problem: String?
    private let tint = Color(hex: 0xDABD8B)
    private var order: ShelfOrder { ShelfOrder(rawValue: savedOrder) ?? .recent }
    private var records: [ShelfList.Release] { shelf?.visible(query: query, order: order) ?? [] }
    private var syncing: Bool { submitting || shelf?.syncing == true || awaitedSync != nil }
    private var ownedID: Int? {
        wall.link.isLive && ["art", "cd"].contains(wall.state.displayedMode) ? wall.state.owned?.releaseId : nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                masthead
                if !wall.link.isLive { notice("Your wall is offline", detail: shelf == nil ? "Reconnect to see your collection." : "Showing the last collection read from this wall.", symbol: "wifi.slash") }
                else if readFailed { notice("Couldn't refresh the shelf", detail: "Your collection stays here. Pull to refresh or try again below.", symbol: "arrow.clockwise") }
                if loading && shelf == nil { loadingShelf }
                else if let shelf {
                    if !shelf.available { shelfOff }
                    else if !shelf.uniqueReleases.isEmpty {
                        collectionPortrait(shelf)
                        syncReceipt(shelf)
                        if let playing = shelf.uniqueReleases.first(where: { $0.id == ownedID }) { ownedReceipt(playing) }
                        collectionTools
                        if records.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Nothing on this shelf matches.").font(.ui(20, .medium))
                                Text("Try an artist, title, label or catalogue number.").font(.ui(14)).foregroundStyle(Ink.dim)
                                Button("Clear search") { query = "" }.font(.ui(15, .semibold)).foregroundStyle(tint).frame(minHeight: 44)
                            }.padding(.vertical, 18)
                        } else {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: typeSize.isAccessibilitySize ? 1 : 2), alignment: .leading, spacing: 28) {
                                ForEach(records) { release in
                                    NavigationLink { ShelfReleasePage(release: release, tint: tint) } label: { recordTile(release) }
                                        .buttonStyle(PressStyle(scale: 0.98))
                                        .accessibilityLabel("\(release.title), \(release.artistLine), \(release.copyCount) \(release.copyCount == 1 ? "copy" : "copies")")
                                        .accessibilityHint("Open pressing details")
                                }
                            }
                        }
                        ownershipNote
                    } else { emptyShelf(shelf) }
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Collection unavailable").font(.ui(25, .semibold))
                        Text("The wall couldn’t send its collection. Your Discogs account hasn’t changed.").font(.ui(15)).foregroundStyle(Ink.dim)
                        Button { Task { await load(host: wall.host) } } label: {
                            Label("Try again", systemImage: "arrow.clockwise").font(.ui(16, .semibold)).frame(minHeight: 48)
                        }.foregroundStyle(tint)
                    }.padding(.vertical, 30)
                }
                if let problem { notice("The read couldn't finish", detail: problem, symbol: "exclamationmark.circle") }
            }.padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 40)
        }
        .background(Ink.ground).foregroundStyle(Ink.ink)
        .navigationTitle("The shelf").navigationBarTitleDisplayMode(.inline).tint(tint)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { DiscogsPage(accent: accent, services: $services) } label: {
                    Image(systemName: "person.crop.circle").frame(width: 44, height: 44)
                }.accessibilityLabel("Discogs account")
            }
        }
        .refreshable { await load(host: wall.host) }
        .task(id: "\(wall.host)|\(scenePhase)") {
            guard scenePhase == .active else { return }
            let host = wall.host
            if sourceHost != host { reset(host: host) }
            await load(host: host)
            let result = await WallServices.read(host: host)
            if !Task.isCancelled, wall.host == host { services = result }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(syncing ? 2 : 15))
                guard !Task.isCancelled else { return }
                await load(host: host)
            }
        }
        .onChange(of: wall.host) { _, host in reset(host: host) }
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("YOUR DISCOGS COLLECTION", systemImage: "opticaldisc")
                .font(.machine(9)).tracking(0.6).foregroundStyle(tint).accessibilityHidden(true)
            Text("The shelf").font(typeSize.isAccessibilitySize ? .ui(30, .semibold) : .display(48)).tracking(-1)
            Text("The records you own, from Discogs.").font(.ui(16)).foregroundStyle(Ink.dim)
        }
    }

    private func collectionPortrait(_ shelf: ShelfList) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            ShelfRecordStack(releases: Array(shelf.visible(query: "", order: .recent).prefix(3)), tint: tint)
                .frame(height: typeSize.isAccessibilitySize ? 200 : 228).accessibilityHidden(true)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 24) { collectionNumbers(shelf) }
                VStack(alignment: .leading, spacing: 18) { collectionNumbers(shelf) }
            }
        }
    }
    @ViewBuilder private func collectionNumbers(_ shelf: ShelfList) -> some View {
        collectionNumber(shelf.uniqueReleases.count, "pressings")
        collectionNumber(shelf.artistCount, "artists")
        if shelf.copyCount != shelf.uniqueReleases.count { collectionNumber(shelf.copyCount, "copies") }
    }
    private func collectionNumber(_ number: Int, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(number.formatted()).font(.displayMid(34)).monospacedDigit().foregroundStyle(Ink.ink)
            Text(label).font(.ui(13)).foregroundStyle(Ink.dim)
        }.accessibilityElement(children: .combine)
    }

    private func syncReceipt(_ shelf: ShelfList) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                if syncing { ProgressView().tint(tint).padding(.top, 3) }
                else { Image(systemName: shelf.problem == nil ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(shelf.problem == nil ? tint : Ink.tile).padding(.top, 2) }
                VStack(alignment: .leading, spacing: 5) {
                    Text(syncing ? "Reading your collection" : shelf.problem != nil ? "Showing your saved collection" : feedback ?? (shelf.isStale() ? "Ready for another read" : "Your shelf is up to date"))
                        .font(.ui(15, .semibold))
                    if syncing {
                        Text("The wall keeps reading if you leave this page.").font(.ui(13)).foregroundStyle(Ink.dim)
                    } else if let at = shelf.synced_at, at.isFinite, at > 0 {
                        Text("Last read \(Date(timeIntervalSince1970: at).formatted(date: .abbreviated, time: .shortened))")
                            .font(.ui(12)).foregroundStyle(Ink.dim)
                    } else { Text("Your collection hasn't been read yet.").font(.ui(13)).foregroundStyle(Ink.dim) }
                }
                Spacer(minLength: 0)
            }
            if let issue = shelf.problem { Text(issue).font(.ui(13)).foregroundStyle(Ink.tile) }
            HStack(spacing: 8) {
                if let user = shelf.user, !user.isEmpty { Text("@\(user)").font(.ui(12)).foregroundStyle(Ink.dim).lineLimit(1) }
                Spacer(minLength: 0)
                Button { sync() } label: {
                    Label(syncing ? "Reading…" : "Read again", systemImage: "arrow.clockwise")
                        .font(.ui(14, .semibold)).frame(minHeight: 44)
                }.buttonStyle(.plain).foregroundStyle(tint)
                    .disabled(!shelf.configured || syncing || !wall.link.isLive)
                    .opacity(!shelf.configured || !wall.link.isLive ? 0.45 : 1)
                    .accessibilityHint("Asks the wall to read the latest Discogs collection")
            }
        }.padding(18).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 18))
    }

    private func ownedReceipt(_ release: ShelfList.Release) -> some View {
        NavigationLink { ShelfReleasePage(release: release, tint: tint) } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { ownedContents(release) }
                VStack(alignment: .leading, spacing: 16) { ownedContents(release) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
        }.buttonStyle(.plain).accessibilityLabel("On your shelf and on the wall: \(release.title). View pressing")
    }
    @ViewBuilder private func ownedContents(_ release: ShelfList.Release) -> some View {
        WallThumb(frame: wall.frame, live: wall.link.isLive).accessibilityLabel("Actual live wall")
        VStack(alignment: .leading, spacing: 6) {
            Label("YOURS, ON THE WALL", systemImage: "opticaldisc").font(.machine(8)).foregroundStyle(tint)
            Text(release.title).font(.ui(18, .semibold)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
            Text(release.artistLine).font(.ui(13)).foregroundStyle(Ink.dim)
        }
    }

    private var collectionTools: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Ink.dim)
                TextField("Find a record", text: $query, prompt: Text("Find a record").foregroundStyle(Ink.dim))
                    .font(.ui(16)).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .accessibilityLabel("Search collection by artist, title, label or catalogue number")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }
                        .buttonStyle(.plain).foregroundStyle(Ink.dim).accessibilityLabel("Clear collection search")
                }
            }.padding(.horizontal, 14).frame(minHeight: 54).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 14))
            ViewThatFits(in: .horizontal) {
                HStack { resultCount; Spacer(minLength: 10); sortingMenu }
                VStack(alignment: .leading, spacing: 4) { resultCount; sortingMenu }
            }
        }
    }
    private var resultCount: some View {
        Text(query.isEmpty ? "All records" : "\(records.count) \(records.count == 1 ? "match" : "matches")")
            .font(.ui(17, .semibold)).foregroundStyle(Ink.ink)
    }
    private var sortingMenu: some View {
        Menu {
            Picker("Sort records", selection: $savedOrder) {
                ForEach(ShelfOrder.allCases) { item in Text(item.title).tag(item.rawValue) }
            }
        } label: { Label(order.title, systemImage: "arrow.up.arrow.down").font(.ui(13, .medium)).frame(minHeight: 44) }
            .foregroundStyle(tint).accessibilityLabel("Sort records: \(order.title)")
    }
    private func recordTile(_ release: ShelfList.Release) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ShelfReleaseCover(url: release.coverURL)
                .overlay(alignment: .bottomTrailing) {
                    if release.copyCount > 1 {
                        Text("x\(release.copyCount)").font(.machine(10)).foregroundStyle(Ink.ink).padding(8)
                            .background(Ink.ground.opacity(0.88), in: RoundedRectangle(cornerRadius: 8)).padding(8)
                    }
                }
            VStack(alignment: .leading, spacing: 5) {
                Text(release.title).font(.ui(16, .semibold)).foregroundStyle(Ink.ink).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                Text(release.artistLine).font(.ui(13)).foregroundStyle(Ink.dim).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                Text([release.year.flatMap { $0 > 0 ? String($0) : nil }, release.formats?.first].compactMap { $0 }.joined(separator: ", "))
                    .font(.ui(11)).foregroundStyle(Ink.dim)
            }
            if release.id == ownedID {
                Label("On the wall", systemImage: "opticaldisc").font(.ui(11, .medium)).foregroundStyle(tint)
            } else if release.plays > 0 {
                Text("\(release.plays) \(release.plays == 1 ? "appearance" : "appearances") on the wall").font(.ui(11)).foregroundStyle(Ink.dim)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var ownershipNote: some View {
        HStack(alignment: .top, spacing: 12) {
            ShelfOwnershipGlyph().stroke(tint, lineWidth: 1.6).frame(width: 24, height: 24).accessibilityHidden(true)
            Text("Your wall adds a small record to artwork from an album you own. The sleeve stays the same. A small mark shows you own it.")
                .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }.padding(.top, 10)
    }
    private func emptyShelf(_ shelf: ShelfList) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            ShelfRecordStack(releases: [], tint: tint).frame(height: 220).accessibilityHidden(true)
            Text(shelf.configured ? "No records yet" : "Connect Discogs to see your records")
                .font(typeSize.isAccessibilitySize ? .ui(25, .semibold) : .displayMid(32))
            Text(shelf.configured ? "Add the pressings you own to your Discogs collection, then read it here. Your wall will recognize the albums that belong to you." : "Connect your Discogs account once. Your collection, pressing details and ownership marks will follow.")
                .font(.ui(16)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            if shelf.configured { syncReceipt(shelf) }
            else {
                NavigationLink { DiscogsPage(accent: accent, services: $services) } label: {
                    HStack { Text("Connect Discogs"); Spacer(); Image(systemName: "arrow.right") }
                        .font(.ui(16, .semibold)).padding(.horizontal, 18).frame(minHeight: 54)
                        .foregroundStyle(Ink.ground).background(tint, in: RoundedRectangle(cornerRadius: 15))
                }.buttonStyle(PressStyle(scale: 0.98))
            }
            ownershipNote
        }
    }
    /// The shelf feature is off on this wall: it answers with only a problem
    /// and no account fields. Connecting Discogs would not help, so say so.
    private var shelfOff: some View {
        VStack(alignment: .leading, spacing: 16) {
            ShelfRecordStack(releases: [], tint: tint).frame(height: 220).accessibilityHidden(true)
            notice("The shelf is off on this wall", detail: "Your Discogs collection shows here when the shelf feature is switched on in the wall's settings.", symbol: "power")
        }
    }
    private var loadingShelf: some View {
        VStack(alignment: .leading, spacing: 22) {
            ShelfRecordStack(releases: [], tint: tint).frame(height: 220).accessibilityHidden(true)
            HStack(spacing: 12) { ProgressView().tint(tint); Text("Reading your record shelf").font(.ui(16)).foregroundStyle(Ink.dim) }
        }.padding(.vertical, 12)
    }
    private func notice(_ title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(tint).padding(.top, 3)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.ui(15, .semibold)); Text(detail).font(.ui(13)).foregroundStyle(Ink.dim)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Ink.plaster, in: RoundedRectangle(cornerRadius: 16))
    }

    private func reset(host: String) {
        readID = UUID(); actionID = UUID(); sourceHost = host; shelf = nil; services = nil
        loading = true; readFailed = false; submitting = false; awaitedSync = nil; feedback = nil; problem = nil
    }
    private func load(host: String) async {
        guard host == wall.host else { return }
        let id = UUID(); readID = id
        loading = true
        defer { if readID == id { loading = false } }
        do {
            let result = try await ShelfList.fetch(host: host)
            guard !Task.isCancelled, wall.host == host, readID == id else { return }
            readFailed = false
            if let awaitedSync {
                if result.completed_sync_id == awaitedSync {
                    self.awaitedSync = nil
                    feedback = result.problem == nil ? "Collection read by your wall" : nil
                    if result.problem == nil { Taps.commit() }
                } else if result.syncing != true && result.sync_id != awaitedSync {
                    self.awaitedSync = nil
                    problem = "The wall restarted before confirming this read. Read again to retry."
                }
            }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { shelf = result }
        } catch {
            guard !Task.isCancelled, wall.host == host, readID == id else { return }
            readFailed = true
        }
    }
    private func sync() {
        guard !syncing, shelf?.configured == true, wall.link.isLive else { return }
        let host = wall.host, id = UUID()
        actionID = id; readID = UUID(); submitting = true; problem = nil; feedback = nil
        Task {
            do {
                let receipt = try await ShelfList.requestSync(host: host)
                guard !Task.isCancelled, wall.host == host, actionID == id else { return }
                readID = UUID(); awaitedSync = receipt.sync_id; submitting = false
                await load(host: host)
            } catch {
                guard !Task.isCancelled, wall.host == host, actionID == id else { return }
                submitting = false
                problem = (error as? ShelfRequestError)?.localizedDescription ?? "The wall didn’t confirm the read. Reconnect and try again."
            }
        }
    }
}

private struct ShelfReleaseCover: View {
    let url: URL?
    var body: some View {
        GeometryReader { geometry in
            AsyncImage(url: url) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
                else {
                    Rectangle().fill(Ink.plaster)
                        .overlay(ShelfVinylDisc(tint: Color(hex: 0xDABD8B)).padding(geometry.size.width * 0.16))
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
    }
}

private struct ShelfRecordStack: View {
    let releases: [ShelfList.Release]
    let tint: Color
    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.height - 12, geometry.size.width * 0.63)
            ZStack {
                ShelfVinylDisc(tint: tint).frame(width: side * 0.94, height: side * 0.94).offset(x: side * 0.35)
                ForEach(Array(releases.prefix(3).enumerated().reversed()), id: \.element.id) { index, release in
                    ShelfReleaseCover(url: release.coverURL).frame(width: side, height: side)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.ink.opacity(0.12), lineWidth: 0.75))
                        .rotationEffect(.degrees(Double(index) * -5 - 3))
                        .offset(x: CGFloat(index) * -12 - side * 0.10, y: CGFloat(index) * 2)
                        .shadow(color: Ink.ground.opacity(0.5), radius: 10, x: 0, y: 8)
                }
                if releases.isEmpty {
                    RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x26221B))
                        .overlay {
                            VStack(alignment: .leading) {
                                Text("TESSERA").font(.machine(8)).tracking(2)
                                Spacer()
                                ShelfOwnershipGlyph().stroke(tint, lineWidth: 2).frame(width: 55, height: 55)
                                Spacer()
                                Text("THE RECORD SHELF").font(.machine(8)).tracking(0.5)
                            }.foregroundStyle(tint).padding(22).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(width: side, height: side).rotationEffect(.degrees(-5)).offset(x: -side * 0.13)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

private struct ShelfVinylDisc: View {
    let tint: Color
    var body: some View {
        Canvas { context, size in
            let square = CGRect(origin: .zero, size: size)
            context.fill(Path(ellipseIn: square), with: .color(Color(hex: 0x24231F)))
            for step in 0..<22 {
                let inset = min(size.width, size.height) * (0.035 + Double(step) * 0.011)
                context.stroke(Path(ellipseIn: square.insetBy(dx: inset, dy: inset)), with: .color(Ink.ink.opacity(step.isMultiple(of: 3) ? 0.09 : 0.045)), lineWidth: 0.6)
            }
            let center = square.insetBy(dx: size.width * 0.345, dy: size.height * 0.345)
            context.fill(Path(ellipseIn: center), with: .color(tint))
            context.fill(Path(ellipseIn: square.insetBy(dx: size.width * 0.48, dy: size.height * 0.48)), with: .color(Ink.ground))
        }
    }
}

private struct ShelfOwnershipGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(ellipseIn: rect.insetBy(dx: 1, dy: 1))
        path.addEllipse(in: rect.insetBy(dx: rect.width * 0.38, dy: rect.height * 0.38))
        return path
    }
}

private struct ShelfReleasePage: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let release: ShelfList.Release
    let tint: Color
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ShelfReleaseCover(url: release.coverURL)
                VStack(alignment: .leading, spacing: 10) {
                    Label("IN YOUR COLLECTION", systemImage: "opticaldisc").font(.machine(9)).foregroundStyle(tint)
                    Text(release.title).font(typeSize.isAccessibilitySize ? .ui(28, .semibold) : .display(38)).fixedSize(horizontal: false, vertical: true)
                    Text(release.artistLine).font(.ui(19)).foregroundStyle(Ink.dim)
                    if release.copyCount > 1 { Text("\(release.copyCount) copies in your collection").font(.ui(14)).foregroundStyle(tint) }
                }
                VStack(spacing: 0) {
                    detail("Year", release.year.flatMap { $0 > 0 ? String($0) : nil })
                    detail("Label", release.label)
                    detail("Catalogue", release.catno)
                    detail("Country", release.country)
                    detail("Format", release.formatLine)
                    detail("On the wall", release.plays == 1 ? "1 appearance" : "\(release.plays) appearances")
                }.padding(.horizontal, 18).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 18))
                if let url = release.discogsURL {
                    Link(destination: url) {
                        HStack { Text("Open this pressing"); Spacer(); Image(systemName: "arrow.up.right") }
                            .font(.ui(16, .semibold)).padding(.horizontal, 20).frame(minHeight: 56)
                            .foregroundStyle(Ink.ground).background(tint, in: RoundedRectangle(cornerRadius: 16))
                    }.accessibilityLabel("Open this pressing on Discogs")
                }
                Text("Discogs keeps the details of the exact release you own. Changes to your collection appear after its next read.")
                    .font(.ui(13)).foregroundStyle(Ink.dim)
            }.padding(24)
        }.background(Ink.ground).foregroundStyle(Ink.ink).navigationTitle("Your pressing").navigationBarTitleDisplayMode(.inline)
    }
    @ViewBuilder private func detail(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(label).font(.ui(12)).foregroundStyle(Ink.dim)
                Text(value).font(.ui(16, .medium)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 14)
                .accessibilityElement(children: .combine)
        }
    }
}
