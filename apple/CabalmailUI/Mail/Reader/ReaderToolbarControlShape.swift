import SwiftUI

/// The kind of control a reader toolbar slot draws on macOS.
///
/// AppKit gives each kind a different width — a chevron segment costs real
/// points — so a disabled stand-in built from the wrong kind is narrower
/// than the live control it reserves the slot for, and every button after
/// it slides sideways when a message opens (#2016). The stand-ins read the
/// shape from the same policy the live controls are built to, so the two
/// can't drift apart by eye.
enum ReaderToolbarControlShape {
    /// A plain push button: `Button { … } label: { … }`.
    case button
    /// A pull-down menu with no primary action: `Menu { … } label: { … }`,
    /// which macOS draws with a chevron and no separate press target.
    case menu
    /// A split button: `Menu { … } label: { … } primaryAction: { … }` with a
    /// visible menu indicator — a press target plus a chevron segment.
    case splitButton
}

#if os(macOS)
/// One disabled stand-in for a reader toolbar slot, drawn as the kind of
/// control that will replace it (`EmptyDetailToolbar`,
/// `EmptyFeedDetailToolbar`).
///
/// The menu shapes carry a single inert row rather than no rows at all:
/// AppKit draws a `Menu` with an empty content block as a plain button,
/// which is the very footprint these stand-ins exist to avoid. Nothing can
/// open them — the whole control is disabled — so the row is never seen.
struct ToolbarStandIn: View {
    let title: String
    let symbol: String
    let shape: ReaderToolbarControlShape

    var body: some View {
        switch shape {
        case .button:
            Button {} label: { face }
                .disabled(true)
        case .menu:
            Menu { placeholderRow } label: { face }
                .disabled(true)
        case .splitButton:
            Menu { placeholderRow } label: { face } primaryAction: {}
                .menuIndicator(.visible)
                .disabled(true)
        }
    }

    private var face: some View {
        Label(title, systemImage: symbol)
    }

    private var placeholderRow: some View {
        Button {} label: { face }
    }
}
#endif
