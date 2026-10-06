import Foundation

/// Holds a `ComposeViewModel` factory and builds the model on first use.
///
/// `@State`'s initializer is eager. SwiftUI re-creates the enclosing view
/// struct on every body evaluation of its parent, so passing the model
/// itself — `ComposeView(model: ComposeViewModel(…))` — built a whole
/// second model, and with it a second `RichTextEditorController` and its
/// `WKWebView`, before SwiftUI discarded all but the first (#1102). Handing
/// `ComposeView` the factory instead keeps that cost off the copies SwiftUI
/// throws away: only the holder it actually keeps is ever asked for a model.
///
/// Deliberately not `@Observable` — the model it vends is, and observation
/// tracking follows the properties `ComposeView` reads off the model, not
/// the box around it.
@MainActor
final class DeferredComposeModel {
    private let make: () -> ComposeViewModel
    private var resolved: ComposeViewModel?

    init(_ make: @escaping () -> ComposeViewModel) {
        self.make = make
    }

    /// The one model this holder will ever vend, built on first access.
    var model: ComposeViewModel {
        if let resolved {
            return resolved
        }
        let model = make()
        resolved = model
        return model
    }
}
