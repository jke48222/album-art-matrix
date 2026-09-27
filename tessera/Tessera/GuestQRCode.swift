import Foundation
import CoreImage.CIFilterBuiltins
import CoreGraphics

/// A guest QR laid out for the wall's real side. The phone shows this same
/// frame, so the wall and the phone carry identical modules.
///
/// A camera reading a dotted LED matrix needs at least two LEDs per module,
/// the line the shipped version held, so a code that would need one-LED
/// modules is refused. The whole field is lit, which makes one module of lit
/// margin a workable quiet zone, and the rest of the space goes to larger
/// modules instead of a four-module border.
struct GuestQRCode: Equatable {
    static let minimumModule = 2
    static let margin = 1
    let modules: [[Bool]]
    let side: Int
    let moduleScale: Int
    var offset: Int { (side - modules.count * moduleScale) / 2 }

    init?(payload: String, side: Int) {
        guard (16...512).contains(side), !payload.isEmpty, payload.utf8.count <= 4096 else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "L"
        guard let output = filter.outputImage,
              let image = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(output, from: output.extent)
        else { return nil }
        let raster = image.width
        guard raster == image.height, raster >= 21, raster <= 179 else { return nil }
        var raw = [UInt8](repeating: 0, count: raster * raster * 4)
        let drawn = raw.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: raster, height: raster,
                                          bitsPerComponent: 8, bytesPerRow: raster * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.setShouldAntialias(false)
            context.draw(image, in: CGRect(x: 0, y: 0, width: raster, height: raster))
            return true
        }
        guard drawn else { return nil }
        // Core Image includes its own white border. Strip it so the margin
        // and the module size are measured on the code itself.
        var minX = raster, minY = raster, maxX = -1, maxY = -1
        for y in 0..<raster { for x in 0..<raster where raw[(y * raster + x) * 4] < 128 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        } }
        let count = maxX - minX + 1
        guard count >= 21, count == maxY - minY + 1, (count - 21) % 4 == 0 else { return nil }
        let scale = side / (count + 2 * Self.margin)
        guard scale >= Self.minimumModule else { return nil }
        self.side = side
        moduleScale = scale
        modules = (0..<count).map { y in
            (0..<count).map { x in raw[((minY + y) * raster + minX + x) * 4] < 128 }
        }
    }

    /// RGB888 at `side`: a lit white field with the modules as unlit LEDs.
    func frame() -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: side * side * 3)
        let origin = offset
        for (my, row) in modules.enumerated() { for (mx, dark) in row.enumerated() where dark {
            for dy in 0..<moduleScale {
                let start = ((origin + my * moduleScale + dy) * side + origin + mx * moduleScale) * 3
                for index in start..<(start + moduleScale * 3) { pixels[index] = 0 }
            }
        } }
        return pixels
    }

    /// The wall frame, one image pixel per LED, for the phone to scale up.
    func image() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(frame()) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 24,
                       bytesPerRow: side * 3, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

enum GuestCodeInput {
    enum Security: String, CaseIterable { case password, open }

    static func wifiProblem(ssid: String, password: String, security: Security) -> String? {
        guard !ssid.isEmpty else { return "Enter the network name exactly as it appears in Wi-Fi settings." }
        guard !ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !ssid.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              ssid.utf8.count <= 32 else { return "Use a network name of 1 to 32 bytes, without line breaks." }
        guard security == .password else { return nil }
        let isHexKey = password.utf8.count == 64 && password.allSatisfy { $0.isASCII && $0.isHexDigit }
        guard isHexKey || (8...63).contains(password.utf8.count),
              !password.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return "Personal WPA networks use a password of 8 to 63 bytes, or a 64-character hexadecimal key."
        }
        return nil
    }

    static func wifi(ssid: String, password: String, security: Security, hidden: Bool) -> String {
        func escaped(_ value: String) -> String {
            value.reduce(into: "") { result, character in
                if "\\;,\":".contains(character) { result.append("\\") }
                result.append(character)
            }
        }
        // Quoting a hexadecimal-looking name stops readers treating a literal
        // ASCII SSID as raw hexadecimal network bytes. Passwords stay bare.
        // WPA readers take a password as raw hex only at 64 characters, which
        // is what a raw key is, so quoting a shorter one such as 12345678
        // protects nothing and risks a reader keeping the quotes.
        let name = escaped(ssid)
        let hexadecimalName = !ssid.isEmpty && ssid.allSatisfy { $0.isASCII && $0.isHexDigit }
        var value = "WIFI:T:\(security == .open ? "nopass" : "WPA");S:\(hexadecimalName ? "\"\(name)\"" : name);"
        if security == .password { value += "P:\(escaped(password));" }
        if hidden { value += "H:true;" }
        return value + ";"
    }

    static func url(_ text: String) -> URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 4096,
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let parts = URLComponents(string: value),
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil,
              let host = parts.host, !host.isEmpty, !host.contains("\\"),
              parts.port == nil || (1...65535).contains(parts.port!),
              let url = parts.url else { return nil }
        return url
    }
}
