// The three finishes, alive (the room design; Components.FinishRow is the
// classic screen's own, drawn from the frame it already holds).
//
// The wall renders them on whatever the face it is showing would put a
// finish on: the sleeve, the turning record, the words, the grid of nine, a
// clip, a design. So this asks the wall rather than guessing, and keeps
// asking, because most of those move.
//
// It fetches for itself instead of holding the answer on the session: a
// value on the session is watched by the whole control centre, and a new
// picture four times a second redrew every board and every tile with it.

import SwiftUI
import UIKit

struct LiveFinishRow: View {
    let host: String
    /// What the wall is showing; a change means new pictures.
    let mode: String
    let current: String
    let accent: Color
    let ink: GlassInk
    /// Drawn until the wall answers.
    var sleeve: UIImage? = nil
    var pick: (String) -> Void

    private static let names = [("clean", "Clean"), ("dither", "Dither"), ("poster", "Poster")]

    @State private var shots: [String: UIImage] = [:]
    @State private var busy = false
    /// The polling, as a task the view holds. A Timer publisher made inside
    /// the body is remade on every re-render, and a face that redraws ten
    /// times a second (the record, as frames arrive) remade it faster than
    /// it could fire, so the previews never moved past their first fetch.
    @State private var polling: Task<Void, Never>? = nil

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Self.names, id: \.0) { f in
                let on = current == f.0
                Button { pick(f.0); Taps.detent(intensity: 0.4) } label: {
                    VStack(spacing: 8) {
                        Group {
                            if let img = shots[f.0] {
                                Image(uiImage: img).resizable().interpolation(.none)
                            } else if let local = FinishSwatch.render(px: nil, sleeve: sleeve, finish: f.0) {
                                Image(uiImage: local).resizable().interpolation(.none)
                            } else {
                                Rectangle().fill(ink.fill)
                            }
                        }
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(on ? accent : ink.ink.opacity(0.14), lineWidth: on ? 2 : 1))
                        Text(f.1).font(.ui(13, .medium)).foregroundStyle(on ? accent : ink.ink)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(on ? accent.opacity(0.14) : Color.clear))
                }
                .buttonStyle(PressStyle(scale: 0.96))
                .accessibilityLabel(f.1)
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        // a new face shows its own picture at once, not the last one's
        .onChange(of: mode) { _, _ in shots = [:]; fetch() }
        .onAppear {
            fetch()
            polling?.cancel()
            polling = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(350))
                    fetch()
                }
            }
        }
        .onDisappear { polling?.cancel(); polling = nil }
    }

    private func fetch() {
        guard !busy, !host.isEmpty, let url = URL(string: "http://\(host)/finishes") else { return }
        busy = true
        Task {
            defer { Task { @MainActor in busy = false } }
            var req = URLRequest(url: url)
            req.timeoutInterval = 4
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
            else { return }
            var out: [String: UIImage] = [:]
            for (k, v) in obj {
                if let d = Data(base64Encoded: v), d.count == 64 * 64 * 3,
                   let img = FinishSwatch.bitmap([UInt8](d)) { out[k] = img }
            }
            let ready = out
            await MainActor.run { if !ready.isEmpty { shots = ready } }
        }
    }
}
