// Album Wall companion — pushes iPhone now-playing to the Mac reporter
// (tier 0, beats the laggy account API) and remote-controls the wall's
// brain on the Pi. See ios-companion/README.md for project setup.
import CoreText
import SwiftUI

@main
struct AlbumWallApp: App {
    @StateObject private var pusher = Pusher()
    @StateObject private var wall = WallAPI()
    @StateObject private var creations = CreationStore()

    init() {
        // The two voices (Archivo + IBM Plex Mono) ship as loose TTFs in
        // Fonts/ and register at launch — no Info.plist keys needed, which
        // keeps the hand-rolled pbxproj untouched. Failure is harmless:
        // Font.custom falls back to the system face.
        for name in ["Archivo-Variable", "IBMPlexMono-Regular",
                     "IBMPlexMono-Medium"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(pusher)
                .environmentObject(wall)
                .environmentObject(creations)
        }
    }
}
