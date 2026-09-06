// Share to Tessera: the wall plays what you shared.
//
// From the YouTube app, Safari, Photos, Files, or anything AirDropped to
// this phone: Share, then Tessera. The wall plays it.
//
// This sheet talks to the wall itself rather than opening the app, because
// iOS does not let a share extension open its app: `extensionContext.open`
// is refused for a share extension (tried on iOS 27, both it and the old
// responder-chain trick, and the app never came up). So a link is handed
// to the wall from here, and a video from the library is made small here
// and sent up here.
//
// The address is the app's own default for a wall, `album-matrix.local`
// (WallLink.host). An extension cannot read what the app has saved without
// an App Group, and that needs an App ID capability the command line
// cannot register while no Apple ID is signed into Xcode. If the wall ever
// moves, this sheet says it cannot reach it and the app's Video page still
// works.

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Where the wall lives, as far as this sheet knows. The same default, and
/// the same simulator rule, as the app's own (see WallLink.host): a build
/// running beside a brain on the Mac must never reach for the real wall.
#if targetEnvironment(simulator)
private let wallHost = "localhost:8788"
#else
private let wallHost = "album-matrix.local:8788"
#endif

@MainActor
@Observable
final class ShareModel {
    enum Phase: Equatable {
        case reading                 // pulling the item out of the share sheet
        case working(String, Double) // words, and how far along
        case onWall(String?)         // playing; the title once the wall knows it
        case failed(String)
    }
    var phase: Phase = .reading

    func begin(with context: NSExtensionContext?) {
        let providers = (context?.inputItems as? [NSExtensionItem])?
            .flatMap { $0.attachments ?? [] } ?? []
        if let movie = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.movie.identifier) }) {
            take(movie: movie)
        } else if let link = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            link.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] item, _ in
                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                Task { @MainActor in self?.take(link: url?.absoluteString) }
            }
        } else if let text = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            text.loadItem(forTypeIdentifier: UTType.plainText.identifier) { [weak self] item, _ in
                let s = (item as? String) ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let link = s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                    .first { $0.lowercased().hasPrefix("http") }
                Task { @MainActor in self?.take(link: link) }
            }
        } else {
            phase = .failed("Nothing here the wall can play.")
        }
    }

    // MARK: A link

    private func take(link: String?) {
        guard let link, link.lowercased().hasPrefix("http") else {
            phase = .failed("That is not a link the wall can play.")
            return
        }
        phase = .working("Handing it to the wall", 0)
        Task {
            do {
                _ = try await post("/video", body: ["url": link, "sound": true])
                phase = .onWall(nil)
                await watch()
            } catch {
                phase = .failed(words(for: error))
            }
        }
    }

    // MARK: A video from the library

    /// The wall decodes in software on a small computer, so it never sees
    /// the original: the picture is made square and small here first.
    private func take(movie: NSItemProvider) {
        phase = .working("Reading the video", 0)
        movie.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, _ in
            guard let url else {
                Task { @MainActor in self?.phase = .failed("That video could not be read.") }
                return
            }
            // the file is gone when this callback returns, so it is copied first
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("share-\(UUID().uuidString)." + (url.pathExtension.isEmpty ? "mov" : url.pathExtension))
            do {
                try FileManager.default.copyItem(at: url, to: copy)
            } catch {
                Task { @MainActor in self?.phase = .failed("That video could not be read.") }
                return
            }
            let name = url.deletingPathExtension().lastPathComponent
            Task { @MainActor in await self?.send(file: copy, title: name) }
        }
    }

    private func send(file: URL, title: String) async {
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            phase = .working("Making the picture", 0)
            let small = try await VideoPicture.make(from: file) { p in
                Task { @MainActor in self.phase = .working("Making the picture", p) }
            }
            defer { try? FileManager.default.removeItem(at: small) }
            phase = .working("Sending it to the wall", 0)
            var c = URLComponents(string: "http://\(wallHost)/video/upload")!
            // no sound: this sheet cannot stay open to play it, so the wall
            // keeps its own time. The app's Video page does it with sound.
            c.queryItems = [.init(name: "title", value: title),
                            .init(name: "clock", value: "wall")]
            var req = URLRequest(url: c.url!)
            req.httpMethod = "POST"
            req.timeoutInterval = 180
            req.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
            let (data, resp) = try await URLSession.shared.upload(for: req, fromFile: small)
            try check(data, resp)
            phase = .onWall(title)
            await watch()
        } catch {
            phase = .failed(words(for: error))
        }
    }

    // MARK: The wall

    private func post(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "http://\(wallHost)\(path)")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        return try check(data, resp)
    }

    @discardableResult
    private func check(_ data: Data, _ resp: URLResponse) throws -> [String: Any] {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw Trouble.wall(json["error"] as? String
                ?? "the wall said \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return json
    }

    /// Watch the wall for a few seconds, so the card can say what it is
    /// playing, or that it could not get it.
    private func watch() async {
        guard let url = URL(string: "http://\(wallHost)/video") else { return }
        for _ in 0..<14 {
            try? await Task.sleep(for: .milliseconds(700))
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let v = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            let status = v["status"] as? String ?? ""
            if status == "error" || status == "idle", let why = v["error"] as? String {
                phase = .failed(why)
                return
            }
            if let title = v["title"] as? String, case .onWall = phase {
                phase = .onWall(title)
            }
            if status == "playing" { return }
        }
    }

    private enum Trouble: LocalizedError {
        case wall(String)
        var errorDescription: String? {
            switch self { case .wall(let s): return s }
        }
    }

    private func words(for error: Error) -> String {
        if let t = error as? Trouble { return t.errorDescription ?? "The wall refused it." }
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return "The wall is not answering at \(wallHost)."
        }
        return ns.localizedDescription
    }
}

final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.043, green: 0.039, blue: 0.035, alpha: 1)
        if let sheet = sheetPresentationController {
            sheet.detents = [.custom { _ in 260 }]
            sheet.prefersGrabberVisible = false
        }
        let card = ShareCard(model: model) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        let host = UIHostingController(rootView: card)
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.didMove(toParent: self)
        model.begin(with: extensionContext)
    }
}

/// The card: what was shared, and what the wall did with it.
struct ShareCard: View {
    @Bindable var model: ShareModel
    var done: () -> Void

    private let ink = Color(red: 0.918, green: 0.894, blue: 0.847)
    private let dim = Color(red: 0.588, green: 0.565, blue: 0.498)
    private let accent = Color(red: 0.910, green: 0.690, blue: 0.294)
    private let signal = Color(red: 0.878, green: 0.286, blue: 0.122)
    private let moss = Color(red: 0.498, green: 0.659, blue: 0.478)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("Tessera").font(.system(size: 22, weight: .semibold)).foregroundStyle(ink)
                Spacer()
                if case .onWall = model.phase {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                        .foregroundStyle(moss)
                }
            }
            Text(words).font(.system(size: 15)).foregroundStyle(failed ? signal : dim)
                .fixedSize(horizontal: false, vertical: true)
            if case .working(_, let p) = model.phase {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(ink.opacity(0.12)).frame(height: 6)
                        Capsule().fill(accent)
                            .frame(width: max(6, geo.size.width * (p > 0 ? p : 0.08)), height: 6)
                    }
                }
                .frame(height: 6)
            }
            Spacer(minLength: 0)
            Button(action: done) {
                Text(dismissable ? "Done" : "Cancel")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(dismissable ? Color.black : ink)
                    .padding(.horizontal, 20).frame(height: 44)
                    .background { if dismissable { Capsule().fill(accent) } }
                    .overlay { if !dismissable { Capsule().strokeBorder(ink.opacity(0.2), lineWidth: 1) } }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var failed: Bool {
        if case .failed = model.phase { return true }
        return false
    }

    private var dismissable: Bool {
        switch model.phase {
        case .onWall, .failed: return true
        default: return false
        }
    }

    private var words: String {
        switch model.phase {
        case .reading: return "Reading what you shared."
        case .working(let w, _): return w + "."
        case .onWall(let title):
            let what = title.map { "\"\($0)\"" } ?? "It"
            return "\(what) is on the wall. Open Tessera to hear it."
        case .failed(let why): return why
        }
    }
}
