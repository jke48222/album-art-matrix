// Tessera. One tile of a mosaic; the wall is 4,096 of them.

import SwiftUI

@main
struct TesseraApp: App {
    @State private var wall = WallSession()

    init() {
        Face.registerAll()
        Taps.prepareAll()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(wall)
        }
    }
}
