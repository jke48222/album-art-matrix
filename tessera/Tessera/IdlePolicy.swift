import Foundation

/// Settings describe an automatic policy. They never select a wall face.
enum IdlePolicy: String, CaseIterable, Identifiable {
    case black, hold, dim, ambient, weather
    var id: String { rawValue }
    var title: String {
        switch self {
        case .black: "Go dark"
        case .hold: "Hold the cover"
        case .dim: "A softer glow"
        case .ambient: "Let colour drift"
        case .weather: "Watch the weather"
        }
    }
    var shortTitle: String {
        switch self {
        case .black: "Go dark"
        case .hold: "Hold cover"
        case .dim: "Dim to 30%"
        case .ambient: "Lamp"
        case .weather: "Weather"
        }
    }
    var detail: String {
        switch self {
        case .black: "Rest in darkness until the next song."
        case .hold: "Keep the last cover at your chosen brightness."
        case .dim: "Keep the cover at 30% of your chosen brightness."
        case .ambient: "Your current Lamp effect, colours and pace."
        case .weather: "Live conditions at the wall’s saved location."
        }
    }
    var symbol: String {
        switch self {
        case .black: "moon"
        case .hold: "photo"
        case .dim: "sun.min"
        case .ambient: "sparkles"
        case .weather: "cloud.sun"
        }
    }
    static func current(_ raw: String) -> IdlePolicy { Self(rawValue: raw) ?? .black }
}
