import Foundation

/// A discovery attempt owns its completion. Leaving the page or retrying
/// invalidates that ownership, so a delayed network result cannot skip a step.
enum OnboardingStep: String, CaseIterable {
    case welcome, find, found, glow, noWall, services, light, done

    var section: Int {
        switch self {
        case .welcome, .find, .found, .glow, .noWall: 0
        case .services: 1
        case .light, .done: 2
        }
    }

    /// Found and Glow go back to Welcome: the no-wall screen would be false
    /// there, because the wall they showed is still answering.
    func back(wallLive: Bool) -> OnboardingStep? {
        switch self {
        case .welcome: nil
        case .find, .noWall, .found, .glow: .welcome
        case .services: wallLive ? .found : .noWall
        case .light: .services
        case .done: .light
        }
    }
}

struct OnboardingJourney {
    private(set) var step: OnboardingStep
    private(set) var searchID: UUID?
    private(set) var searchBegan: Date?
    static let searchLimit: TimeInterval = 18

    init(step: OnboardingStep = .welcome) { self.step = step }

    mutating func move(to next: OnboardingStep) {
        searchID = nil
        searchBegan = nil
        step = next
    }

    @discardableResult mutating func beginSearch(at date: Date = Date()) -> UUID {
        move(to: .find)
        let id = UUID()
        searchID = id
        searchBegan = date
        return id
    }

    @discardableResult mutating func foundWall(for id: UUID) -> Bool {
        guard step == .find, searchID == id else { return false }
        move(to: .found)
        return true
    }

    @discardableResult mutating func expireSearch(for id: UUID, at date: Date = Date()) -> Bool {
        guard step == .find, searchID == id, let searchBegan,
              date.timeIntervalSince(searchBegan) >= Self.searchLimit else { return false }
        move(to: .noWall)
        return true
    }
}
