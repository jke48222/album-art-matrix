import Foundation
import Observation

enum HomeDestination: Equatable { case settings, studio, video, onboarding }
enum HomeSheet: String, Identifiable { case settings; var id: String { rawValue } }
enum HomeCover: String, Identifiable { case studio, video, onboarding; var id: String { rawValue } }

/// Appeared destinations finish dismissing before the next presentation.
/// Requests SwiftUI has not presented yet can be replaced immediately.
@Observable
final class HomeRouter {
    var sheet: HomeSheet?
    var cover: HomeCover?
    private(set) var visible: HomeDestination?
    private(set) var pending: HomeDestination?
    private(set) var presented: HomeDestination?

    func present(_ destination: HomeDestination) {
        guard visible != destination || (sheet == nil && cover == nil) else { return }
        if presented != nil {
            pending = destination
            sheet = nil
            cover = nil
        } else {
            activate(destination)
        }
    }

    func dismiss() {
        pending = nil
        sheet = nil
        cover = nil
        // There is no dismissal callback to await if no content appeared.
        if presented == nil { visible = nil }
    }

    func didPresent(_ destination: HomeDestination) {
        // A superseded content view must not claim the newer request.
        guard visible == destination, sheet != nil || cover != nil else { return }
        presented = destination
    }

    func didDismiss() {
        guard presented != nil else { return }
        presented = nil
        visible = nil
        sheet = nil
        cover = nil
        if let next = pending {
            pending = nil
            activate(next)
        }
    }

    private func activate(_ destination: HomeDestination) {
        visible = destination
        pending = nil
        presented = nil
        sheet = nil
        cover = nil
        switch destination {
        case .settings: sheet = .settings
        case .studio: cover = .studio
        case .video: cover = .video
        case .onboarding: cover = .onboarding
        }
    }
}
