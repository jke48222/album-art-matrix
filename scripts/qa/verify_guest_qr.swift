import Foundation
import Vision
import ImageIO
import UniformTypeIdentifiers

/// Compile with GuestQRCode.swift. All network names and passwords in these
/// fixtures are authored test data. This tool never reads system credentials.
@main
struct VerifyGuestQR {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/tessera-guest-qr")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var assertions = 0
        func check(_ valid: @autoclosure () -> Bool, _ name: String) {
            assertions += 1
            guard valid() else { fputs("Guest QR check failed: \(name)\n", stderr); exit(1) }
        }
        check(GuestCodeInput.wifiProblem(ssid: "", password: "12345678", security: .password) != nil, "empty SSID")
        check(GuestCodeInput.wifiProblem(ssid: "   ", password: "12345678", security: .password) != nil, "blank SSID")
        check(GuestCodeInput.wifiProblem(ssid: String(repeating: "é", count: 16), password: "12345678", security: .password) == nil, "32-byte UTF-8 SSID")
        check(GuestCodeInput.wifiProblem(ssid: String(repeating: "é", count: 17), password: "12345678", security: .password) != nil, "SSID byte limit")
        check(GuestCodeInput.wifiProblem(ssid: "Tessera", password: "", security: .open) == nil, "explicit open network")
        check(GuestCodeInput.wifiProblem(ssid: "Tessera", password: "", security: .password) != nil, "missing WPA password")
        check(GuestCodeInput.wifiProblem(ssid: "Tessera", password: "short", security: .password) != nil, "short WPA password")
        check(GuestCodeInput.wifiProblem(ssid: "Tessera", password: String(repeating: "a", count: 64), security: .password) == nil, "hex WPA key")
        check(GuestCodeInput.wifiProblem(ssid: "Tessera", password: String(repeating: "x", count: 64), security: .password) != nil, "invalid WPA key")
        check(GuestCodeInput.wifiProblem(ssid: "Tessera\nGuest", password: "12345678", security: .password) != nil, "control characters")
        let escaped = GuestCodeInput.wifi(ssid: "One;Two:Three\\Four,\"Five", password: "a;b:c\\d,e\"f", security: .password, hidden: true)
        check(escaped == "WIFI:T:WPA;S:One\\;Two\\:Three\\\\Four\\,\\\"Five;P:a\\;b\\:c\\\\d\\,e\\\"f;H:true;;", "MECARD escaping")
        check(GuestCodeInput.wifi(ssid: "Tessera", password: "ignored", security: .open, hidden: false) == "WIFI:T:nopass;S:Tessera;;", "open payload omits password")
        check(GuestCodeInput.wifi(ssid: "ABCD", password: "12345678", security: .password, hidden: false) == "WIFI:T:WPA;S:\"ABCD\";P:12345678;;", "quote a hexadecimal-looking name, never a password")
        let rawKey = String(repeating: "a", count: 64)
        check(GuestCodeInput.wifi(ssid: "Tessera", password: rawKey, security: .password, hidden: false) == "WIFI:T:WPA;S:Tessera;P:\(rawKey);;", "raw 64-character key stays bare")
        for input in ["javascript:alert(1)", "file:///tmp/a", "https://name:password@example.com", "https://", "https://bad host/", "https://example.com:70000", "https://example.com/line\nbreak"] {
            check(GuestCodeInput.url(input) == nil, "reject malformed or unsafe URL")
        }
        check(GuestCodeInput.url("https://example.com/hello?q=guest#hi") != nil, "valid HTTPS link")
        check(GuestCodeInput.url("http://room.local:8788") != nil, "local HTTP link")

        // The wall rule: two LEDs a module at least, one lit module of margin.
        check(GuestQRCode(payload: "", side: 64) == nil, "empty QR payload")
        check(GuestQRCode(payload: "https://example.com/" + String(repeating: "long", count: 200), side: 64) == nil, "oversized payload")
        check(GuestQRCode(payload: "Tessera", side: 32) == nil, "a 32 wall cannot give two LEDs a module")
        let dense = GuestCodeInput.wifi(ssid: "Tessera guest room upstairs", password: "A good evening with friends", security: .password, hidden: false)
        check(GuestQRCode(payload: dense, side: 64) == nil, "a code that needs one-LED modules is refused on the 64 wall")
        check(GuestQRCode(payload: dense, side: 192) != nil, "the same code fits the 192 wall")
        // The network the setup UI tests type must still be showable on the 64 test wall.
        check(GuestQRCode(payload: GuestCodeInput.wifi(ssid: "Tessera authored guest", password: "A good evening", security: .password, hidden: false), side: 64) != nil, "UI test network fits the 64 wall")

        let fixtures: [(name: String, payload: String, fits64: Bool)] = [
            ("wifi", GuestCodeInput.wifi(ssid: "Tessera guest", password: "A good evening", security: .password, hidden: false), true),
            ("hidden", GuestCodeInput.wifi(ssid: "Tessera guest", password: "A good evening", security: .password, hidden: true), true),
            ("open", GuestCodeInput.wifi(ssid: "Tessera guest", password: "", security: .open, hidden: false), true),
            ("link", "https://example.com/hello", true),
            ("escaped", escaped, false),
            ("dense", dense, false)
        ]
        var results = [[String: Any]]()
        for fixture in fixtures {
            for side in [64, 192] {
                guard let code = GuestQRCode(payload: fixture.payload, side: side) else {
                    check(side == 64 && !fixture.fits64, "\(fixture.name) fits at \(side)")
                    results.append(["fixture": fixture.name, "side": side, "refused": true, "modules": NSNull()])
                    continue
                }
                check(side != 64 || fixture.fits64, "\(fixture.name) is refused at 64")
                let count = code.modules.count, scale = code.moduleScale, offset = code.offset
                let far = side - offset - count * scale
                check(code.side == side, "laid out at the wall's side")
                check(scale >= GuestQRCode.minimumModule, "at least two LEDs per module")
                check(min(offset, far) >= scale, "one lit module of margin on every edge")
                check((scale + 1) * (count + 2 * GuestQRCode.margin) > side, "largest whole-LED module that fits")
                let pixels = code.frame()
                check(pixels.count == side * side * 3, "frame is the wall's size")
                check(pixels.allSatisfy { $0 == 0 || $0 == 255 }, "crisp black and white LEDs")
                var modulesMatch = true
                for y in 0..<side { for x in 0..<side {
                    let mx = (x - offset), my = (y - offset)
                    let inside = mx >= 0 && my >= 0 && mx < count * scale && my < count * scale
                    let dark = inside && code.modules[my / scale][mx / scale]
                    if pixels[(y * side + x) * 3] != (dark ? 0 : 255) { modulesMatch = false }
                } }
                check(modulesMatch, "every module is a solid block of LEDs")
                guard let image = code.image() else { fatalError("Missing phone image") }
                check(readBack(image) == pixels, "phone image is the wall frame")
                let wallFile = directory.appendingPathComponent("\(fixture.name)-\(side).png")
                try save(image, to: wallFile)
                // The phone draws this frame at 192 points, which is 576 pixels on a 3x screen.
                let phoneScale = 576 / side
                guard let phone = upscaled(pixels, side: side, by: phoneScale) else { fatalError("Missing phone render") }
                let phoneFile = directory.appendingPathComponent("\(fixture.name)-\(side)-phone.png")
                try save(phone, to: phoneFile)
                let wallDecoded = try decodes(image, fixture.payload)
                let phoneDecoded = try decodes(phone, fixture.payload)
                // Both views must decode: the true wall pixels and the phone's.
                check(wallDecoded, "Vision decode \(fixture.name)-\(side) at wall pixels")
                check(phoneDecoded, "Vision decode \(fixture.name)-\(side) as the phone shows it")
                results.append(["fixture": fixture.name, "side": side, "refused": false, "modules": count,
                                "leds_per_module": scale, "margin_leds": min(offset, far),
                                "margin_modules": Double(min(offset, far)) / Double(scale),
                                "wall_file": wallFile.lastPathComponent, "phone_file": phoneFile.lastPathComponent,
                                "decoded_at_wall_pixels": wallDecoded, "decoded_as_phone": phoneDecoded])
            }
        }
        let report: [String: Any] = ["assertions": assertions, "authored_fixtures_only": true,
                                     "rule": "At least \(GuestQRCode.minimumModule) LEDs per module and \(GuestQRCode.margin) lit module of margin, laid out at the wall's side.",
                                     "physical_scan": "Not performed. Software decoding does not certify reading the LEDs with a camera.",
                                     "results": results]
        let reportData = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try reportData.write(to: directory.appendingPathComponent("validation.json"))
        let shown = results.filter { $0["refused"] as? Bool == false }.count
        print("Guest QR: \(assertions) assertions passed. \(shown) layouts decoded at wall pixels and as the phone shows them, \(results.count - shown) refused as expected.")
    }

    static func readBack(_ image: CGImage) -> [UInt8] {
        let side = image.width
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        rgba.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        var rgb = [UInt8](); rgb.reserveCapacity(side * side * 3)
        for index in stride(from: 0, to: rgba.count, by: 4) { rgb += rgba[index..<(index + 3)] }
        return rgb
    }

    static func upscaled(_ pixels: [UInt8], side: Int, by factor: Int) -> CGImage? {
        let out = side * factor
        var scaled = [UInt8](repeating: 0, count: out * out * 3)
        for y in 0..<out { for x in 0..<out {
            let source = ((y / factor) * side + x / factor) * 3, target = (y * out + x) * 3
            scaled[target] = pixels[source]; scaled[target + 1] = pixels[source + 1]; scaled[target + 2] = pixels[source + 2]
        } }
        guard let provider = CGDataProvider(data: Data(scaled) as CFData) else { return nil }
        return CGImage(width: out, height: out, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: out * 3,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func save(_ image: CGImage, to file: URL) throws {
        guard let output = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { fatalError("PNG destination unavailable") }
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output) else { fatalError("Could not save \(file.lastPathComponent)") }
    }

    static func decodes(_ image: CGImage, _ payload: String) throws -> Bool {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).contains { $0.payloadStringValue == payload }
    }
}
