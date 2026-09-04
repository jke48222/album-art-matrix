// The opening.
//
// The iPod arrives back first. The Tessera mark on its steel back lights
// tile by tile, breathes once, and the body turns over to the screen. It is
// a rendered sequence (Blender, orthographic, transparent film) played over
// the room at exactly the iPod's own size, so the last frame of the film
// and the first frame of the live iPod are the same picture. The film ends,
// the live iPod is already there.

import AVFoundation
import SwiftUI
import UIKit

struct IntroFlip: UIViewRepresentable {
    var resource: String = "ipod-intro"
    var onDone: () -> Void

    static var available: Bool { available(named: "ipod-intro") }
    static func available(named name: String) -> Bool {
        Bundle.main.url(forResource: name, withExtension: "mov") != nil
    }

    func makeUIView(context: Context) -> PlayerView {
        let v = PlayerView()
        v.backgroundColor = .clear
        v.isOpaque = false
        if let url = Bundle.main.url(forResource: resource, withExtension: "mov") {
            let item = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            v.playerLayer.player = player
            v.playerLayer.videoGravity = .resizeAspect
            v.playerLayer.pixelBufferAttributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            context.coordinator.observer = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
                onDone()
            }
            context.coordinator.player = player
            player.play()
        } else {
            DispatchQueue.main.async { onDone() }
        }
        return v
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var observer: NSObjectProtocol?
        var player: AVPlayer?
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
