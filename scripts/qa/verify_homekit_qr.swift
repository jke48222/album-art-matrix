import Foundation
import Vision

let expected = "X-HM://0023ISYWY7OSY"
for path in CommandLine.arguments.dropFirst() {
    let request = VNDetectBarcodesRequest()
    request.symbologies = [.qr]
    let handler = VNImageRequestHandler(url: URL(fileURLWithPath: path), options: [:])
    do {
        try handler.perform([request])
        let valid = (request.results ?? []).contains { $0.payloadStringValue == expected }
        print("\(URL(fileURLWithPath: path).lastPathComponent): \(valid ? "authored QR decoded" : "not detected")")
        if !valid { exit(1) }
    } catch {
        fputs("QR verification failed: \(error.localizedDescription)\n", stderr)
        exit(2)
    }
}
