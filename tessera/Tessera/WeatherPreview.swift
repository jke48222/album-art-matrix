#if DEBUG
import SwiftUI

/// Deterministic, network-free entry for simulator visual QA. Never used in release.
struct WeatherPreview: View {
    private let session = WallSession()
    private let reference = Date(timeIntervalSince1970: 1790116560) // 22 Sep 2026, 18:36 EDT
    private var sample: WallWeather {
        let args = ProcessInfo.processInfo.arguments
        let variant = args.firstIndex(of: "-weather-scene").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "golden"
        let now = reference.timeIntervalSince1970
        let code = ["rain": 63, "snow": 73, "fog": 45, "storm": 95, "night": 0, "overcast": 3, "parity": 3][variant] ?? 2
        let day = !["night", "storm", "parity"].contains(variant)
        let temp: Double = variant == "snow" ? -2 : variant == "parity" ? 22.8 : 22
        let hours = (1...6).map { index in
            WallWeather.Hour(t: floor(now / 3600) * 3600 + Double(index) * 3600, temp: temp - Double(index), code: [2, 1, 0, 0, 3, 61][index - 1], is_day: index < 2)
        }
        let parity = variant == "parity"
        let current = WallWeather.Now(temp: temp, feels: temp - 1, code: code, is_day: day, wind_kmh: parity ? 8 : 14, cloud: 38, precip_mm: code == 63 ? 2.4 : 0, high: parity ? 24.4 : temp + 3, low: parity ? 17.2 : temp - 7, sunrise: now - (11 * 3600 + 54 * 60), sunset: now + 42 * 60)
        let place = variant == "empty" ? "" : variant == "long" ? "Saint-Rémy-de-Provence, France" : parity ? "Douglasville, Georgia" : "Marietta, Georgia"
        return WallWeather(place: place, units: "f", utc_offset_s: -14400, age_s: variant == "stale" ? 7200 : 120, stale: variant == "stale", refreshing: variant == "loading", problem: variant == "offline" ? "The wall isn't answering. Pull to retry." : nil, now: ["empty", "loading", "offline"].contains(variant) ? nil : current, hours: hours)
    }
    var body: some View {
        NavigationStack {
            WeatherPage(accent: Ink.tile, preview: sample, referenceDate: reference)
                .environment(session)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Image(systemName: "chevron.left").foregroundStyle(Ink.ink)
                            .accessibilityLabel("Preview navigation")
                    }
                }
        }
        .environment(\.dynamicTypeSize, CommandLine.arguments.contains("-weather-large") ? .accessibility3 : .large)
        .preferredColorScheme(.dark)
    }
}
#endif
