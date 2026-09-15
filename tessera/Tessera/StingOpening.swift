// The opening, two more ways: the Record sting.
//
// "sting": the film on black, then the app.
// "sting-room": the same film keyed to transparency over the room's own
// light, the colours of the record on the wall, so the sting happens in the
// room rather than in front of it. When it ends the film fades and the app
// glitches in from coarse pixels, the move the room's second opening makes.
//
// The film is the 4K render in tessera/Design/Logos/record/final, encoded
// twice for the bundle: HEVC on black, and HEVC with alpha where alpha is
// the picture's own luma (white light on black is already premultiplied).

import AVFoundation
import SwiftUI
import UIKit

enum StingFilm {
    static let onBlack = Bundle.main.url(forResource: "record-sting", withExtension: "mp4")
    static let keyed = Bundle.main.url(forResource: "record-sting-alpha", withExtension: "mov")

    /// The opening styles this film provides.
    static let styles: Set<String> = ["sting", "sting-room"]
    static func plays(_ style: String) -> Bool {
        styles.contains(style) && (style == "sting" ? onBlack : keyed) != nil
            && !CommandLine.arguments.contains("-nointro")
    }
}

/// The film, muted like the other openings, ending with a callback.
struct StingPlayer: UIViewRepresentable {
    let url: URL
    var keyed: Bool
    var onEnd: () -> Void

    func makeUIView(context: Context) -> IntroFlip.PlayerView {
        let v = IntroFlip.PlayerView()
        v.backgroundColor = .clear
        v.isOpaque = false
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        if keyed {
            v.playerLayer.pixelBufferAttributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        }
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in onEnd() }
        context.coordinator.player = player
        player.play()
        return v
    }

    func updateUIView(_ uiView: IntroFlip.PlayerView, context: Context) {}
    func makeCoordinator() -> IntroFlip.Coordinator { IntroFlip.Coordinator() }
}

/// Where the opening is. The root view keeps one of these and lays the film
/// over the app until it is done.
enum StingPhase: Equatable {
    case film, fading, glitch(Date), done
}

/// The room's picture arriving from coarse pixels. Animatable, so the root
/// sets progress to 0 and animates it to 1; at 1 the effect is off.
///
/// Only ever put this on pure SwiftUI content. A layer effect turns any
/// UIKit-backed view inside it (a page view, a scroll view, a film, a photo
/// picker) into SwiftUI's yellow no-entry placeholder, even while the effect
/// is disabled; on whole app pages it did exactly that to the pressing panel
/// and the opening films.
struct GlitchIn: ViewModifier, Animatable {
    /// 0: coarse and invisible. 1: the app as it is.
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let s = progress * progress * (3 - 2 * progress)
        let cell: Float = Float((1 - s) * (1 - s) * 56) + (s < 1 ? 1.5 : 0)
        content
            .layerEffect(ShaderLibrary.pixelate(.float(cell), .float2(0, 0)),
                         maxSampleOffset: CGSize(width: 60, height: 60), isEnabled: s < 1)
            .opacity(min(1, s * 1.6))
    }
}

/// The glitch-in's progress, handed down from the root to the one view that
/// takes it, the room's picture. 1 whenever no opening is running.
private struct GlitchInKey: EnvironmentKey { static let defaultValue: Double = 1 }
extension EnvironmentValues {
    var glitchIn: Double {
        get { self[GlitchInKey.self] }
        set { self[GlitchInKey.self] = newValue }
    }
}

/// The film over the app: on black, or keyed over the room's light.
struct StingOpening: View {
    let style: String
    let light: Lighting
    let surge: Double
    @Binding var phase: StingPhase
    @AppStorage("design") private var design = Design.room.rawValue

    var body: some View {
        let keyed = style == "sting-room"
        ZStack {
            if keyed {
                Room(palette: light.isOff ? [] : light.palette, px: light.isOff ? nil : light.reading.px,
                     light: light.room, surge: surge)
            } else {
                Color.black
            }
            if let url = keyed ? StingFilm.keyed : StingFilm.onBlack, phase == .film || phase == .fading {
                StingPlayer(url: url, keyed: keyed) { end() }
                    .opacity(phase == .fading ? 0 : 1)
                    .animation(.easeOut(duration: 0.55), value: phase)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        // on black, the whole thing fades to the app; in the room, the
        // film alone fades, and the cover is dropped in one go for the
        // glitch, the room under it being the same room
        .opacity(!keyed && phase == .fading ? 0 : 1)
        .animation(.easeInOut(duration: 0.55), value: phase)
        .opacity({ if case .glitch = phase { return 0 } else { return 1 } }())
        // the room's picture pixelates in under a cover dropped at once; the
        // other designs have no such picture, so the cover fades off them
        .animation(design == Design.room.rawValue ? nil : .easeOut(duration: 0.9), value: phase)
    }

    private func end() {
        phase = .fading
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if style == "sting-room" {
                phase = .glitch(Date())
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { phase = .done }
            } else {
                phase = .done
            }
        }
    }
}
