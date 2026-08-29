// What Siri offers. The intents themselves live in Shared/Intents.swift,
// because the widget's keys fire them too; the shortcuts phrasebook belongs
// to the app alone, so it stays here.

import AppIntents

struct TesseraShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SetWallModeIntent(),
            phrases: ["Set the wall in \(.applicationName)",
                      "\(.applicationName) the wall"],
            shortTitle: "Set the wall",
            systemImageName: "square.grid.2x2"
        )
        AppShortcut(
            intent: SleepWallIntent(),
            phrases: ["Fade the wall out in \(.applicationName)",
                      "Goodnight \(.applicationName)"],
            shortTitle: "Fade out",
            systemImageName: "moon"
        )
        AppShortcut(
            intent: StartWallTimerIntent(),
            phrases: ["Start a wall timer in \(.applicationName)",
                      "\(.applicationName) timer"],
            shortTitle: "Wall timer",
            systemImageName: "timer"
        )
    }
}
