import SwiftUI

struct LiveFinishRow: View {
    let host: String
    let mode: String
    let current: String
    let accent: Color
    let ink: GlassInk
    var sleeve: UIImage? = nil
    var pick: (String) -> Void
    @State private var images = WallImages()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                ForEach(["clean", "dither", "poster"], id: \.self) { finish in
                    Button { pick(finish); Taps.detent(intensity: 0.4) } label: {
                        VStack(spacing: 9) {
                            ZStack {
                                ink.fill
                                if let image = images.shots[finish] { Image(uiImage: image).resizable().interpolation(.none).scaledToFit() }
                                else if images.loading { ProgressView().tint(accent) }
                                else { Image(systemName: "photo").foregroundStyle(ink.dim) }
                            }.aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(current == finish ? accent : ink.ink.opacity(0.1), lineWidth: current == finish ? 2 : 1))
                            Label(finish.capitalized, systemImage: current == finish ? "checkmark.circle.fill" : "circle")
                                .font(.ui(12, .medium)).foregroundStyle(current == finish ? accent : ink.ink)
                        }.frame(maxWidth: .infinity).padding(.vertical, 7)
                    }.buttonStyle(PressStyle()).accessibilityAddTraits(current == finish ? .isSelected : [])
                }
            }
            Text(images.problem ?? "Rendered by your wall").font(.ui(11)).foregroundStyle(ink.dim)
        }.task(id: "\(host)|\(mode)|\(scenePhase)") {
            if scenePhase == .active { await images.watch(host: host, path: "/finishes", interval: 0.6) }
        }
    }
}
