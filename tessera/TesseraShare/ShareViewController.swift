// Share to Tessera: the wall plays what you shared.
//
// From YouTube, Safari, Photos, or anything AirDropped to this phone, the
// share sheet has a Tessera in it. A link goes straight to the wall from
// here. A video from the library is handed to the app, which makes a small
// picture of it for the wall and plays its sound itself, so the app is
// opened for it; a link with sound on opens the app too, since the phone is
// the speaker and an extension cannot stay to play.

import SwiftUI
import UIKit
import UniformTypeIdentifiers

private let group = "group.com.jalenedusei.tessera"

@MainActor
@Observable
final class ShareModel {
    enum Phase: Equatable {
        case reading, sending, onWall, handed, noWall, failed(String)
    }
    var phase: Phase = .reading
    var title: String?
    var sound = true
    var isMovie = false

    private var defaults: UserDefaults? { UserDefaults(suiteName: group) }
    private var host: String { defaults?.string(forKey: "wall.host") ?? "" }

    func begin(with context: NSExtensionContext?) {
        sound = (defaults?.object(forKey: "video.sound") as? Bool) ?? true
        let providers = (context?.inputItems as? [NSExtensionItem])?
            .flatMap { $0.attachments ?? [] } ?? []
        if let movie = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.movie.identifier) }) {
            isMovie = true
            take(movie: movie)
        } else if let link = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            link.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] item, _ in
                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                Task { @MainActor in self?.send(link: url?.absoluteString) }
            }
        } else if let text = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            text.loadItem(forTypeIdentifier: UTType.plainText.identifier) { [weak self] item, _ in
                let s = (item as? String) ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let link = s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                    .first { $0.lowercased().hasPrefix("http") }
                Task { @MainActor in self?.send(link: link) }
            }
        } else {
            phase = .failed("Nothing here the wall can play.")
        }
    }

    /// A link: the wall fetches it. Sound on means the app has to open.
    private func send(link: String?) {
        guard let link, link.lowercased().hasPrefix("http") else {
            phase = .failed("That is not a link the wall can play.")
            return
        }
        guard !host.isEmpty, let url = URL(string: "http://\(host)/video") else {
            phase = .noWall
            return
        }
        phase = .sending
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["url": link, "sound": sound])
        Task {
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  let http = resp as? HTTPURLResponse else {
                phase = .failed("The wall is not answering.")
                return
            }
            if http.statusCode != 200 {
                let why = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
                phase = .failed(why ?? "The wall said \(http.statusCode).")
                return
            }
            if sound {
                // the app plays the sound; leave it a note in case the
                // hand-off to it does not go through
                write(["kind": "link", "url": link, "sound": true, "at": Date().timeIntervalSince1970])
            }
            phase = .onWall
        }
    }

    /// A video from the library: copied where the app can reach it, and
    /// the app does the rest (it has no size limit and can show progress).
    private func take(movie: NSItemProvider) {
        phase = .sending
        movie.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, _ in
            guard let url else {
                Task { @MainActor in self?.phase = .failed("Could not read that video.") }
                return
            }
            let name = url.lastPathComponent
            do {
                guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let dir = base.appendingPathComponent("video", isDirectory: true)
                try? FileManager.default.removeItem(at: dir)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let dst = dir.appendingPathComponent("incoming." + (url.pathExtension.isEmpty ? "mov" : url.pathExtension))
                try FileManager.default.copyItem(at: url, to: dst)
                Task { @MainActor in
                    guard let self else { return }
                    self.title = name
                    self.write(["kind": "file", "path": dst.path, "title": name,
                                "sound": true, "at": Date().timeIntervalSince1970])
                    self.phase = .handed
                }
            } catch {
                Task { @MainActor in self?.phase = .failed("Could not keep that video: \(error.localizedDescription)") }
            }
        }
    }

    private func write(_ pending: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: pending) {
            defaults?.set(data, forKey: "video.pending")
        }
    }
}

final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.043, green: 0.039, blue: 0.035, alpha: 1)
        if let sheet = sheetPresentationController {
            sheet.detents = [.custom { _ in 300 }]
            sheet.prefersGrabberVisible = false
        }
        let card = ShareCard(model: model,
                             done: { [weak self] in self?.finish() },
                             openApp: { [weak self] in self?.openApp() })
        let host = UIHostingController(rootView: card)
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.didMove(toParent: self)
        model.begin(with: extensionContext)
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// Hand over to the app. Share extensions are not promised open(_:),
    /// so the responder chain is walked as well; the app also looks for the
    /// note on its own the next time it comes up.
    private func openApp() {
        guard let url = URL(string: "tessera://video") else { return }
        extensionContext?.open(url) { [weak self] ok in
            Task { @MainActor in
                if !ok { self?.openThroughResponders(url) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.finish() }
            }
        }
    }

    private func openThroughResponders(_ url: URL) {
        let sel = Selector(("openURL:"))
        var responder: UIResponder? = self
        while let r = responder {
            if r.responds(to: sel) {
                r.perform(sel, with: url)
                return
            }
            responder = r.next
        }
    }
}

/// The card: what was shared, what happened to it, and the one thing to do next.
struct ShareCard: View {
    @Bindable var model: ShareModel
    var done: () -> Void
    var openApp: () -> Void

    private let ink = Color(red: 0.918, green: 0.894, blue: 0.847)
    private let dim = Color(red: 0.588, green: 0.565, blue: 0.498)
    private let accent = Color(red: 0.910, green: 0.690, blue: 0.294)
    private let signal = Color(red: 0.878, green: 0.286, blue: 0.122)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Tessera").font(.system(size: 22, weight: .semibold)).foregroundStyle(ink)
            Text(words).font(.system(size: 15)).foregroundStyle(problem ? signal : dim)
                .fixedSize(horizontal: false, vertical: true)
            if case .sending = model.phase {
                ProgressView().tint(accent)
            }
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                if needsApp {
                    Button(action: openApp) {
                        Text(model.isMovie ? "Open Tessera" : "Open Tessera for the sound")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.black)
                            .padding(.horizontal, 18).frame(height: 44)
                            .background(Capsule().fill(accent))
                    }
                }
                Button(action: done) {
                    Text(needsApp ? "Later" : "Done")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(ink)
                        .padding(.horizontal, 18).frame(height: 44)
                        .overlay(Capsule().strokeBorder(ink.opacity(0.2), lineWidth: 1))
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var needsApp: Bool {
        switch model.phase {
        case .handed: return true
        case .onWall: return model.sound
        default: return false
        }
    }

    private var problem: Bool {
        if case .failed = model.phase { return true }
        return model.phase == .noWall
    }

    private var words: String {
        switch model.phase {
        case .reading: return "Reading what you shared."
        case .sending: return model.isMovie ? "Keeping the video for the app." : "Handing the link to the wall."
        case .onWall: return model.sound ? "The wall is fetching it. The sound plays from this phone, so Tessera has to be open."
                                          : "The wall is fetching it."
        case .handed: return "Tessera makes a small picture of it for the wall and plays the sound from here."
        case .noWall: return "Open Tessera once so it finds the wall, then share again."
        case .failed(let why): return why
        }
    }
}
