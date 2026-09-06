// Share to Tessera: a link from YouTube, Safari, or anything AirDropped to
// this phone goes to the app, and the app puts it on the wall. The phone is
// the speaker, so the app has to be open anyway; the sheet's whole job is
// to carry the link across and open the app.
//
// (Videos from the library reach the app as documents, "Open in Tessera",
// which needs no extension at all. The app group that would let this sheet
// hand files over is a provisioning step the command line cannot do
// without an Apple ID signed into Xcode; see VIDEO.md.)

import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
@Observable
final class ShareModel {
    enum Phase: Equatable { case reading, ready(String), opening, failed(String) }
    var phase: Phase = .reading

    func begin(with context: NSExtensionContext?) {
        let providers = (context?.inputItems as? [NSExtensionItem])?
            .flatMap { $0.attachments ?? [] } ?? []
        if let link = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            link.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] item, _ in
                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                Task { @MainActor in self?.take(url?.absoluteString) }
            }
        } else if let text = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            text.loadItem(forTypeIdentifier: UTType.plainText.identifier) { [weak self] item, _ in
                let s = (item as? String) ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let link = s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                    .first { $0.lowercased().hasPrefix("http") }
                Task { @MainActor in self?.take(link) }
            }
        } else {
            phase = .failed("Nothing here the wall can play.")
        }
    }

    private func take(_ link: String?) {
        guard let link, link.lowercased().hasPrefix("http") else {
            phase = .failed("That is not a link the wall can play.")
            return
        }
        phase = .ready(link)
    }

    /// Where the app is told to go: its own scheme, the link inside.
    var appURL: URL? {
        guard case .ready(let link) = phase else { return nil }
        var c = URLComponents()
        c.scheme = "tessera"
        c.host = "video"
        c.queryItems = [URLQueryItem(name: "url", value: link)]
        return c.url
    }
}

final class ShareViewController: UIViewController {
    private let model = ShareModel()
    private var opened = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.043, green: 0.039, blue: 0.035, alpha: 1)
        if let sheet = sheetPresentationController {
            sheet.detents = [.custom { _ in 250 }]
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
        // as soon as the link is read, go: one tap is the share itself
        withObservationTracking({ _ = model.phase }) { [weak self] in
            Task { @MainActor in
                guard let self, !self.opened, self.model.appURL != nil else { return }
                self.openApp()
            }
        }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// Hand over to the app. Share extensions are not promised open(_:),
    /// so the responder chain is walked as well.
    private func openApp() {
        guard let url = model.appURL else { return }
        opened = true
        model.phase = .opening
        extensionContext?.open(url) { [weak self] ok in
            Task { @MainActor in
                if !ok { self?.openThroughResponders(url) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.finish() }
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

/// The card: what was shared and what is happening to it.
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
            Text(words).font(.system(size: 15)).foregroundStyle(failed ? signal : dim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                if model.appURL != nil {
                    Button(action: openApp) {
                        Text("Open Tessera")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.black)
                            .padding(.horizontal, 18).frame(height: 44)
                            .background(Capsule().fill(accent))
                    }
                }
                Button(action: done) {
                    Text("Cancel")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(ink)
                        .padding(.horizontal, 18).frame(height: 44)
                        .overlay(Capsule().strokeBorder(ink.opacity(0.2), lineWidth: 1))
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var failed: Bool {
        if case .failed = model.phase { return true }
        return false
    }

    private var words: String {
        switch model.phase {
        case .reading: return "Reading what you shared."
        case .ready: return "Tessera puts it on the wall and plays the sound from this phone."
        case .opening: return "Opening Tessera."
        case .failed(let why): return why
        }
    }
}
