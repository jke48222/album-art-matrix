// Teaching the wall what white is.
//
// LED panels ship green-heavy, and the difference between a wall that looks
// like hardware and one that looks like a lamp is three gain numbers nobody
// wants to type. The phone has a camera, so the flow is: the wall lights a
// plain white field, you photograph it, you put the aiming square over the
// wall in the shot, and the app reads the cast and writes the correction.
//
// Honesty about the instrument: this locks the camera's own white balance
// to daylight for the shot, but a phone camera is still a phone camera and
// will absorb some of the cast it is being asked to measure. So the flow is
// built to be run again: each pass multiplies onto the last, and two passes
// settle. The result toggle shows before and after on the actual wall,
// which is the only place the answer matters.
//
// The correction never brightens a channel past 1.0. LEDs have a ceiling,
// and a calibration that asks for more than hardware has is a lie with
// decimals; instead the other channels come down to meet it.

import AVFoundation
import PhotosUI
import SwiftUI

struct CalibrateScreen: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.dismiss) private var dismiss

    let accent: Color

    private enum Step { case card, aim, result }

    @State private var step: Step = .card
    @State private var shot: CGImage? = nil
    @State private var pick: PhotosPickerItem? = nil
    @State private var showCamera = false
    /// Everything the wall was before, restored on any way out.
    @State private var prior: (mode: String, brightness: Double,
                               r: Double, g: Double, b: Double)? = nil
    @State private var computed: (r: Double, g: Double, b: Double)? = nil
    @State private var showingBefore = false

    var body: some View {
        VStack(spacing: 0) {
            switch step {
            case .card: card
            case .aim: aim
            case .result: result
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.ground)
        .preferredColorScheme(.dark)
        .onAppear {
            let s = wall.state
            prior = (s.mode, s.brightness, s.wbR, s.wbG, s.wbB)
            // The card: full white, full light. Measuring a dim wall measures
            // the dimming, not the panel.
            wall.send(["brightness": 1.0])
            wall.pushFlat(r: 255, g: 255, b: 255)
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraShot { image in
                showCamera = false
                if let cg = image.flatMap({ Clip.upright($0) }) {
                    shot = cg
                    step = .aim
                }
            }
            .ignoresSafeArea()
        }
        .onChange(of: pick) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data), let cg = Clip.upright(img) {
                    shot = cg
                    step = .aim
                }
                pick = nil
            }
        }
    }

    // MARK: - Step one: the card

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            head("TRUE COLOUR",
                 "The wall is now showing plain white at full light. Stand back far enough to see the whole panel, and photograph it.")

            Spacer()

            // What the wall is doing right now, in miniature, so the step
            // is checkable from here.
            PanelCanvas(px: [UInt8](repeating: 235, count: 64 * 64 * 3), duty: 1)
                .frame(width: 120, height: 120)
                .padding(.horizontal, 20)

            Spacer()

            VStack(spacing: 14) {
                bigKey("Open the camera") { showCamera = true }
                PhotosPicker(selection: $pick, matching: .images) {
                    Text("From my photos")
                        .font(.ui(15))
                        .foregroundStyle(Ink.dim)
                }
            }
            .frame(maxWidth: .infinity)

            foot("Cancel") { restoreAndClose(keep: false) }
        }
        .padding(.top, Safe.top + 12)
        .padding(.bottom, Safe.bottom + 12)
    }

    // MARK: - Step two: aim

    @ViewBuilder private var aim: some View {
        if let shot {
            Framing(source: [shot], accent: accent) {
                step = .card
            } onUse: { frames in
                if let px = frames.first { solve(px) }
            }
        }
    }

    // MARK: - Step three: the answer, on the wall

    private var result: some View {
        VStack(alignment: .leading, spacing: 0) {
            head("WHAT IT FOUND",
                 "The wall is wearing the correction now. Flip between them and trust your eyes over the numbers. If a tint survives, run it again; each pass refines the last.")

            if let c = computed, let p = prior {
                VStack(alignment: .leading, spacing: 10) {
                    gainRow("red", p.r, c.r)
                    gainRow("green", p.g, c.g)
                    gainRow("blue", p.b, c.b)
                }
                .padding(.horizontal, 20)
                .padding(.top, 26)
            }

            Spacer()

            PillRow(
                label: "on the wall now",
                options: [("before", true), ("after", false)],
                selected: showingBefore,
                accent: accent
            ) { before in
                showingBefore = before
                guard let c = computed, let p = prior else { return }
                wall.send(before
                    ? ["wb_r": p.r, "wb_g": p.g, "wb_b": p.b]
                    : ["wb_r": c.r, "wb_g": c.g, "wb_b": c.b])
            }
            .padding(.horizontal, 20)

            Spacer()

            VStack(spacing: 14) {
                bigKey("Keep it") { restoreAndClose(keep: true) }
                Button("Run it again") {
                    Taps.detent(intensity: 0.3)
                    // the new gains stay on: the next pass measures them
                    if let c = computed {
                        prior?.r = c.r; prior?.g = c.g; prior?.b = c.b
                    }
                    computed = nil
                    shot = nil
                    wall.pushFlat(r: 255, g: 255, b: 255)
                    step = .card
                }
                .font(.ui(15))
                .foregroundStyle(Ink.dim)
            }
            .frame(maxWidth: .infinity)

            foot("Throw it away") { restoreAndClose(keep: false) }
        }
        .padding(.top, Safe.top + 12)
        .padding(.bottom, Safe.bottom + 12)
    }

    private func gainRow(_ name: String, _ old: Double, _ new: Double) -> some View {
        HStack {
            Text(name).font(.ui(13)).foregroundStyle(Ink.dim)
                .frame(width: 52, alignment: .leading)
            Text(String(format: "%.2f", old)).font(.machine(13)).foregroundStyle(Ink.faint)
            Text("to").font(.ui(12)).foregroundStyle(Ink.faint)
            Text(String(format: "%.2f", new)).font(.machine(13)).foregroundStyle(accent)
        }
    }

    // MARK: - The arithmetic

    /// From the aimed 64x64 of the photographed card: the average cast of the
    /// middle of it, turned into multipliers that pull every channel down to
    /// the weakest one's honest level.
    private func solve(_ px: [UInt8]) {
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        // centre only: the aiming square includes the panel's edge, and the
        // edge includes the room
        for y in 12..<52 {
            for x in 12..<52 {
                let o = (y * 64 + x) * 3
                r += Double(px[o]); g += Double(px[o + 1]); b += Double(px[o + 2])
                n += 1
            }
        }
        r /= n; g /= n; b /= n
        guard r > 8, g > 8, b > 8, let p = prior else {
            // a black or unreadable measurement corrects nothing
            step = .card
            return
        }

        // What the camera saw too much of gets turned down. Anchored to the
        // dimmest channel so nothing is ever asked to exceed 1.0.
        let lo = min(r, g, b)
        var nr = p.r * lo / r
        var ng = p.g * lo / g
        var nb = p.b * lo / b
        let peak = max(nr, ng, nb)
        nr = min(1, max(0.3, nr / peak))
        ng = min(1, max(0.3, ng / peak))
        nb = min(1, max(0.3, nb / peak))

        computed = (nr, ng, nb)
        showingBefore = false
        wall.send(["wb_r": nr, "wb_g": ng, "wb_b": nb])
        Taps.landed()
        step = .result
    }

    private func restoreAndClose(keep: Bool) {
        Taps.detent(intensity: 0.4)
        if let p = prior {
            var patch: [String: Any] = ["mode": p.mode == "frame" ? "art" : p.mode,
                                        "brightness": p.brightness]
            if !keep {
                patch["wb_r"] = p.r; patch["wb_g"] = p.g; patch["wb_b"] = p.b
            } else if let c = computed {
                patch["wb_r"] = c.r; patch["wb_g"] = c.g; patch["wb_b"] = c.b
            }
            wall.send(patch)
        }
        dismiss()
    }

    // MARK: - Furniture

    private func head(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.display(18)).kerning(3.0).foregroundStyle(Ink.ink)
            Text(sub).font(.ui(13)).foregroundStyle(Ink.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }

    private func bigKey(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button {
            Taps.commit()
            action()
        } label: {
            Text(label)
                .font(.ui(16, .semibold))
                .foregroundStyle(Ink.ground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(accent, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(PressStyle(scale: 0.97))
        .padding(.horizontal, 20)
    }

    private func foot(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .buttonStyle(PressStyle(scale: 0.96))
            .font(.ui(14))
            .foregroundStyle(Ink.faint)
            .frame(maxWidth: .infinity)
            .padding(.top, 16)
    }
}

// MARK: - The camera, white balance pinned

/// One photo, with the camera's own white balance locked to daylight so it
/// cannot quietly correct the very cast being measured. UIImagePickerController
/// would auto-balance the evidence away.
private struct CameraShot: UIViewControllerRepresentable {
    var onDone: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> CameraShotController {
        let vc = CameraShotController()
        vc.onDone = onDone
        return vc
    }

    func updateUIViewController(_ vc: CameraShotController, context: Context) {}
}

final class CameraShotController: UIViewController, AVCapturePhotoCaptureDelegate {
    var onDone: ((UIImage?) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var preview: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            // No camera (simulator, or denied): hand back nothing and let the
            // flow fall to the photo picker.
            DispatchQueue.main.async { self.onDone?(nil) }
            return
        }
        session.beginConfiguration()
        session.sessionPreset = .photo
        session.addInput(input)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()

        // Pin the white balance to daylight. If the device refuses, continue
        // anyway: an auto-balanced measurement converges over two passes, it
        // is just slower to get there.
        if device.isWhiteBalanceModeSupported(.locked) {
            try? device.lockForConfiguration()
            let temp = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                temperature: 5200, tint: 0)
            var gains = device.deviceWhiteBalanceGains(for: temp)
            let cap = device.maxWhiteBalanceGain
            gains.redGain = max(1, min(cap, gains.redGain))
            gains.greenGain = max(1, min(cap, gains.greenGain))
            gains.blueGain = max(1, min(cap, gains.blueGain))
            device.setWhiteBalanceModeLocked(with: gains)
            device.unlockForConfiguration()
        }

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer

        let shutter = UIButton(type: .system)
        shutter.backgroundColor = .white
        shutter.layer.cornerRadius = 33
        shutter.translatesAutoresizingMaskIntoConstraints = false
        shutter.addTarget(self, action: #selector(fire), for: .touchUpInside)
        view.addSubview(shutter)

        let cancel = UIButton(type: .system)
        cancel.setTitle("Back", for: .normal)
        cancel.setTitleColor(.white, for: .normal)
        cancel.translatesAutoresizingMaskIntoConstraints = false
        cancel.addTarget(self, action: #selector(bail), for: .touchUpInside)
        view.addSubview(cancel)

        NSLayoutConstraint.activate([
            shutter.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            shutter.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -26),
            shutter.widthAnchor.constraint(equalToConstant: 66),
            shutter.heightAnchor.constraint(equalToConstant: 66),
            cancel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            cancel.centerYAnchor.constraint(equalTo: shutter.centerYAnchor),
        ])

        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.startRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    @objc private func fire() {
        let settings = AVCapturePhotoSettings()
        output.capturePhoto(with: settings, delegate: self)
    }

    @objc private func bail() { onDone?(nil) }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        let image = photo.fileDataRepresentation().flatMap { UIImage(data: $0) }
        DispatchQueue.main.async { self.onDone?(image) }
    }
}
