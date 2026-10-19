import Foundation

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
