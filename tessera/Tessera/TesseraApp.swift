// Tessera. One tile of a mosaic; the wall is 4,096 of them.

import SwiftUI

@main
struct TesseraApp: App {
    @State private var wall: WallSession

    init() {
        #if DEBUG
        Self.seedDefaults()
        #endif
        Face.registerAll()
        Taps.prepareAll()
        // Created here, not as a property default, so the DEBUG seeds above
        // are in place before the session reads its address and history.
        let session = WallSession()
        #if DEBUG
        // Connection tests and captures start clean: the outbox and the
        // history persist across launches, so one test's leftovers would
        // otherwise show up in the next.
        if CommandLine.arguments.contains("-connection-reset") {
            session.outbox.clear()
            session.debugClearHistory()
        }
        // -widget-snapshot <fixture> and -widget-now pin the widget's store
        // to a fixture and freeze it, so this session cannot overwrite it.
        // A launch without them releases a pin left by an earlier run.
        WidgetFixture.applyLaunchArguments(CommandLine.arguments)
        #endif
        _wall = State(initialValue: session)
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if CommandLine.arguments.contains("-weather-preview") {
                WeatherPreview()
            } else if let only = Self.argument(after: "-widget-render") {
                // "all", or a comma list of fixture names
                WidgetRenderHarness(only: only)
            } else {
                RootView().environment(wall)
            }
            #else
            RootView().environment(wall)
            #endif
        }
    }

    #if DEBUG
    /// `-seed-wall-host` and `-seed-wall-name` write real defaults, unlike
    /// `-wall.host`, which lands in the argument domain and then outranks
    /// every write the app makes: a test that changes the address could
    /// never see its own change.
    private static func seedDefaults() {
        if let host = argument(after: "-seed-wall-host") {
            UserDefaults.standard.set(host, forKey: "wall.host")
            UserDefaults(suiteName: "group.com.jalenedusei.tessera")?.set(host, forKey: "wall.host")
        }
        if let name = argument(after: "-seed-wall-name") {
            UserDefaults.standard.set(name, forKey: "wall.name")
        }
    }

    private static func argument(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    #endif
}
