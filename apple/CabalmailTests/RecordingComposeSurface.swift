import Foundation
import CabalmailKit
@testable import CabalmailUI

/// A main window's compose surface as `ComposeCoordinator` sees it, for the
/// suites that pin where a compose request goes: it records each seed it
/// was shown, in order, and takes none while `isBusy`. A sheet (an iPhone,
/// a closed Duo) is busy from the seed it shows until it is freed; a
/// surface that opens compose windows never is.
@MainActor
final class RecordingComposeSurface {
    let window: UUID?
    let isSheet: Bool
    private(set) var shown: [Draft] = []
    var isBusy = false
    /// How many offers to refuse before taking any, whatever `isBusy` says:
    /// a surface that frees up between two offers of one pass.
    var refusals = 0
    /// Run as a seed is offered, before the surface answers.
    var whileOffered: ((Draft) -> Void)?
    /// Run as a seed is shown, for a surface that asks for another composer
    /// while showing one.
    var whileShowing: ((Draft) -> Void)?
    private var presenter: ComposeCoordinator.Presenter?

    init(window: UUID?, isSheet: Bool = false) {
        self.window = window
        self.isSheet = isSheet
    }

    /// Registers the surface, as a signed-in main window's router does. The
    /// coordinator keeps it alive from then on, through its presenter, as
    /// SwiftUI keeps a mounted router's state, so a test need not hold it.
    @discardableResult
    func register(with coordinator: ComposeCoordinator) -> RecordingComposeSurface {
        let presenter = ComposeCoordinator.Presenter(window: window) { [self] seed in
            whileOffered?(seed)
            if refusals > 0 {
                refusals -= 1
                return false
            }
            guard !isBusy else { return false }
            shown.append(seed)
            isBusy = isSheet
            whileShowing?(seed)
            return true
        }
        self.presenter = presenter
        coordinator.register(presenter)
        return self
    }

    /// Unregisters it, as the router does when its window signs out.
    func unregister(from coordinator: ComposeCoordinator) {
        if let presenter { coordinator.unregister(presenter) }
        presenter = nil
    }

    /// The sheet closed: the surface can take a seed again.
    func free(in coordinator: ComposeCoordinator) {
        isBusy = false
        coordinator.presenterIsFree()
    }
}
