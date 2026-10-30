import SwiftUI
import Observation

/// iPhone Duo's laptop pose in the split (#1649, the spec's laptop layout):
/// the message takes the window's full width above the fold with the
/// navigation bar hidden, and a panel below the fold holds the list and its
/// bar (`LaptopListPanel`). The reader's own action bar stays at the
/// window's bottom edge, under the panel, so it is the panel's bottom
/// toolbar without moving out of the reader.
///
/// The arrangement changes only values on modifiers that are always
/// present, which the Session 1 prototype measured as reflowing the
/// message's web view without rebuilding or reloading it: the reader keeps
/// its column and ends its content above the crease
/// (`keepsAboveLaptopFold()`), and the split hides the list column. Pure, so
/// the geometry is tested on the Mac host.
enum LaptopPanelPolicy {
    /// Whether the split arranges itself for laptop pose: a crease running
    /// side to side through a window taller than wide, in Mail and Feeds
    /// alike. Each reader keeps its actions in its own bar there, at the
    /// window's bottom edge.
    static func isArranged(fold: FoldState, windowIsTall: Bool) -> Bool {
        guard case .horizontal = fold else { return false }
        return windowIsTall
    }

    /// How far a reader's content region, at `frame` in the window, runs past
    /// the crease's top edge: what it reserves at its bottom so its content
    /// ends above the fold. 0 with no crease, and for a region that already
    /// ends above it.
    static func reserve(below frame: CGRect, crease: CGRect?) -> CGFloat {
        guard let crease else { return 0 }
        return max(0, frame.maxY - crease.minY)
    }

    /// The panel's frame in the split's own coordinates: the split's width,
    /// from the crease's bottom edge to where the reader's content region
    /// ends, which is the top of the reader's own bar, or the split's bottom
    /// before the reader has reported. Empty when nothing is left between.
    static func panelFrame(split: CGRect, crease: CGRect, readerBottom: CGFloat?) -> CGRect {
        let top = crease.maxY - split.minY
        let bottom = min(readerBottom ?? split.maxY, split.maxY) - split.minY
        return CGRect(x: 0, y: top, width: split.width, height: max(0, bottom - top))
    }
}

/// Addresses in laptop pose (#1649, the spec's "Addresses puts its list
/// there"): the panel's `@` turns the panel into the address list and covers
/// the message above the fold, rather than opening the inspector, which
/// would run up the upright half beside it. The reader stays mounted under
/// the cover, so the list coming back shows it without rebuilding its web
/// view.
///
/// Addresses carry across a fold both ways: an inspector open as the split
/// arranges becomes the panel's address list, and the panel's address list
/// as the split leaves laptop pose becomes the inspector. A message opened,
/// or a folder or feed list opened, ends them, so the list it opens shows.
/// Pure, so the rules are tested on the Mac host.
enum LaptopAddressesPolicy {
    struct State: Equatable {
        var inspector: InspectorPresentationPolicy.State
        /// Whether the laptop panel shows the address list.
        var inPanel: Bool
    }

    /// The panel's `@`: the address list or the list it covered, in turn.
    static func toggled(_ state: State) -> State {
        var next = state
        next.inPanel.toggle()
        return next
    }

    /// The split arranged itself for laptop pose (`arranged`), or left it.
    static func split(arranged: Bool, _ state: State) -> State {
        if arranged, state.inspector.presented {
            return State(inspector: .init(presented: false, requested: false), inPanel: true)
        }
        if !arranged, state.inPanel {
            // Asked for, so the framework's own write-back keeps it open.
            return State(inspector: .init(presented: true, requested: true), inPanel: false)
        }
        return state
    }

    /// A message or a list opened: the panel shows the list again.
    static func ended(_ state: State) -> State {
        var next = state
        next.inPanel = false
        return next
    }

    /// Where the panel ends: at the reader's bar, or, while the address
    /// list covers the reader, at the split's bottom, over the bar as well
    /// (`LaptopPanelPolicy.panelFrame`).
    static func panelReaderBottom(_ readerBottom: CGFloat?, covered: Bool) -> CGFloat? {
        covered ? nil : readerBottom
    }

    /// What the menus hear of the reader: nothing selected and nothing open
    /// while the address list covers it, so no command or chord acts on a
    /// message the user can't see.
    static func reported(selectionCount: Int, isOpen: Bool, covered: Bool) -> (selectionCount: Int, isOpen: Bool) {
        covered ? (0, false) : (selectionCount, isOpen)
    }
}

/// Where the laptop panel meets the reader, one per split: the crease the
/// reader keeps above while the split is arranged for laptop pose, and where
/// the reader's content region ends, which is the panel's bottom edge.
/// `SplitShell` holds it and publishes it as `\.laptopReader`; everywhere
/// else it is nil and the reader keeps its whole column.
@Observable
@MainActor
final class LaptopReaderSlot {
    /// The crease, while the split is arranged for laptop pose; nil
    /// otherwise.
    var crease: CGRect?
    /// Where the reader's content region ends in the window: above its own
    /// action bar for a message, the column's bottom for a placeholder.
    private(set) var readerBottom: CGFloat?

    func readerEnds(at bottom: CGFloat) {
        if readerBottom != bottom { readerBottom = bottom }
    }
}

extension EnvironmentValues {
    /// The split's laptop slot (`LaptopReaderSlot`); nil outside the split.
    @Entry var laptopReader: LaptopReaderSlot?
}

/// Ends a reader's content above a laptop fold: a reserve at its bottom,
/// inside any bar the reader pins under its content, and a report of where
/// that region ends, for the panel to stop at. Always present, at 0 unless
/// the split is arranged for laptop pose, so arranging it reflows the
/// content and never rebuilds it. The frame is read outside the reserve, so
/// the reserve never moves what it is measured from.
///
/// Padding, not safe-area padding: behind a safe-area inset of that size
/// the message's web view drew nothing (Duo simulator, 2026-10-29).
struct LaptopFoldClearance: ViewModifier {
    @Environment(\.laptopReader) private var slot
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .padding(.bottom, LaptopPanelPolicy.reserve(below: frame, crease: slot?.crease))
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { newFrame in
                frame = newFrame
                slot?.readerEnds(at: newFrame.maxY)
            }
    }
}

extension View {
    /// Ends this reader's content above a laptop fold (`LaptopFoldClearance`).
    func keepsAboveLaptopFold() -> some View {
        modifier(LaptopFoldClearance())
    }
}
