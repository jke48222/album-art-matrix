// The wall handing out the wifi.
//
// Sixty-four pixels is enough for a scannable QR code, which turns the wall
// into the answer to the one question every guest asks. The phone generates
// the code (CoreImage has an encoder built in; the Pi does not), and it goes
// up as a pushed frame, so it stays until someone picks a mode, exactly like
// a drawing.
//
// Polarity matters more than it looks: scanners want dark modules on a light
// ground, so the frame is a lit white field with the code as UNLIT emitters.
// A wall of light with holes in it scans; the inverse mostly does not.
//
// Size is the honest limit. Version 3 (29 modules) at 2 pixels a module plus
// a quiet zone fits exactly; anything denser drops below 2px modules and
// stops scanning. Long network names or passwords simply do not fit, and the
// screen says so instead of shipping a code that fails at the door.

import CoreImage.CIFilterBuiltins
import SwiftUI

enum QRForge {
    /// The payload as 64x64 RGB, or nil when it cannot be made scannable.
    static func frame(_ payload: String) -> [UInt8]? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        // L keeps the module count down; the wall is high-contrast and
        // emissive, which is the easy end of what correction exists for.
        filter.correctionLevel = "L"
        guard let out = filter.outputImage else { return nil }

        let modules = Int(out.extent.width)
        let scale = (64 - 4) / modules          // insist on a 2px quiet zone
        guard scale >= 2 else { return nil }    // under 2px a module, it fails

        let ctx = CIContext(options: [.useSoftwareRenderer: true])
        guard let cg = ctx.createCGImage(out, from: out.extent) else { return nil }

        // Read the modules straight off the unscaled bitmap.
        let count = modules * modules * 4
        let raw = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        raw.initialize(repeating: 0, count: count)
        defer { raw.deallocate() }
        guard let bctx = CGContext(
            data: raw, width: modules, height: modules, bitsPerComponent: 8,
            bytesPerRow: modules * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        bctx.interpolationQuality = .none
        bctx.draw(cg, in: CGRect(x: 0, y: 0, width: modules, height: modules))

        var px = [UInt8](repeating: 245, count: 64 * 64 * 3)   // the lit field
        let side = modules * scale
        let off = (64 - side) / 2
        for my in 0..<modules {
            for mx in 0..<modules {
                // CIQRCodeGenerator draws dark modules dark; anything below
                // half brightness is a module.
                guard raw[(my * modules + mx) * 4] < 128 else { continue }
                for sy in 0..<scale {
                    for sx in 0..<scale {
                        let o = ((off + my * scale + sy) * 64 + off + mx * scale + sx) * 3
                        px[o] = 0; px[o + 1] = 0; px[o + 2] = 0
                    }
                }
            }
        }
        return px
    }

    /// The standard wifi payload, special characters escaped the way the
    /// spec wants rather than the way that usually works.
    static func wifi(ssid: String, password: String) -> String {
        func esc(_ s: String) -> String {
            var out = ""
            for ch in s {
                if "\\;,\":".contains(ch) { out.append("\\") }
                out.append(ch)
            }
            return out
        }
        return password.isEmpty
            ? "WIFI:T:nopass;S:\(esc(ssid));;"
            : "WIFI:T:WPA;S:\(esc(ssid));P:\(esc(password));;"
    }
}

/// The Setup section. Two fields, one button, and an honest refusal when the
/// code will not fit at a scannable size.
struct GuestsSection: View {
    @Environment(WallSession.self) private var wall
    let accent: Color

    @AppStorage("guests.ssid") private var ssid = ""
    @State private var password = ""
    @State private var kind = "wifi"
    @State private var link = ""
    @State private var preview: [UInt8]? = nil
    @State private var tooLong = false

    var body: some View {
        Section("guests",
                note: "Puts a QR on the wall. Point a phone at it and it joins the wifi, or opens the link. It stays up until you pick a mode, and the password never leaves this phone as text; only pixels go to the wall.") {
            PillRow(
                label: "",
                options: [("wifi", "wifi"), ("a link", "link")],
                selected: kind,
                accent: accent
            ) { kind = $0; refresh() }

            VStack(spacing: 10) {
                if kind == "wifi" {
                    field("network name", text: $ssid)
                    field("password", text: $password)
                } else {
                    field("https://…", text: $link)
                }
            }
            .padding(.top, 12)

            HStack(spacing: 16) {
                Button("Put it on the wall") {
                    refresh()
                    if let px = preview { wall.pushFrame(px) }
                }
                .buttonStyle(PressStyle(scale: 0.97))
                .font(.ui(15, .medium))
                .foregroundStyle(ready ? accent : Ink.faint)
                .disabled(!ready)

                Spacer()

                if let px = preview {
                    // proof at thumbnail size: if the phone can read this
                    // from the screen, the wall version is easier
                    Image(uiImage: EmitterTile.render(px, cell: 2) ?? UIImage())
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 56, height: 56)
                }
            }
            .padding(.top, 12)

            if tooLong {
                Text("Too long to draw at a size a camera can read. Shorter names and passwords fit; a link this long wants a short link.")
                    .font(.ui(12))
                    .foregroundStyle(Ink.signal)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
        }
        .onChange(of: ssid) { refresh() }
        .onChange(of: password) { refresh() }
        .onChange(of: link) { refresh() }
    }

    private var ready: Bool { preview != nil }

    private func refresh() {
        let payload = kind == "wifi"
            ? (ssid.isEmpty ? nil : QRForge.wifi(ssid: ssid, password: password))
            : (link.isEmpty ? nil : link)
        guard let payload else { preview = nil; tooLong = false; return }
        preview = QRForge.frame(payload)
        tooLong = preview == nil
    }

    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .font(.machine(13))
            .foregroundStyle(Ink.ink)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.vertical, 12).padding(.horizontal, 14)
            .background(Ink.sunk)
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.hairline, lineWidth: 1) }
    }
}
