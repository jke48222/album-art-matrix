import Foundation

@main struct OnboardingStateChecks {
    static func main() {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }
        let start = Date(timeIntervalSince1970: 1_000)
        var flow = OnboardingJourney()
        expect(flow.step == .welcome, "First run starts at welcome")
        let first = flow.beginSearch(at: start)
        expect(flow.step == .find, "Discovery starts explicitly")
        expect(!flow.expireSearch(for: first, at: start.addingTimeInterval(17.9)), "Do not end a healthy discovery attempt early")
        expect(flow.expireSearch(for: first, at: start.addingTimeInterval(18)), "Discovery has a bounded timeout")
        expect(flow.step == .noWall, "Timeout offers recovery")
        expect(!flow.foundWall(for: first), "Late result cannot leave recovery")
        let second = flow.beginSearch(at: start)
        let third = flow.beginSearch(at: start)
        expect(second != third, "Retry has separate ownership")
        expect(!flow.foundWall(for: second), "Previous attempt cannot complete retry")
        expect(!flow.expireSearch(for: second, at: start.addingTimeInterval(30)), "Previous timeout cannot stop retry")
        expect(flow.foundWall(for: third), "Current attempt can find wall")
        expect(flow.step == .found && flow.searchID == nil, "Successful discovery cancels timer")
        let fourth = flow.beginSearch(at: start)
        flow.move(to: .services)
        expect(!flow.foundWall(for: fourth), "Skipping cancels discovery completion")
        expect(flow.searchID == nil && flow.searchBegan == nil, "No discovery survives navigation")
        let fixture = OnboardingJourney(step: .find)
        expect(fixture.searchID == nil, "A captured discovery screen does not start hardware work")
        expect(OnboardingStep.welcome.back(wallLive: true) == nil, "Welcome has nothing behind it")
        expect(OnboardingStep.found.back(wallLive: true) == .welcome, "Back from a found wall does not claim it is missing")
        expect(OnboardingStep.glow.back(wallLive: true) == .welcome, "Back from the glow does not claim the wall is missing")
        expect(OnboardingStep.services.back(wallLive: true) == .found, "Music goes back to the connected wall")
        expect(OnboardingStep.services.back(wallLive: false) == .noWall, "Music goes back to the no-wall choice")
        print("{\"checks\":\(checks),\"passed\":\(checks)}")
    }
}
