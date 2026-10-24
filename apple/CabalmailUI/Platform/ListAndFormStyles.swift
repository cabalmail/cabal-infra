import SwiftUI

// List, form and toggle styles that one platform asks for and the others
// leave at their default. Named for where they apply, since the style
// itself is the same call everywhere; the point is that a feature view
// doesn't write the platform conditional (`docs/apple.md`, "Platform
// conditionals").

extension View {
    /// `.formStyle(.grouped)` on macOS, whose default form is a column of
    /// right-aligned labels. iOS and visionOS forms are grouped already.
    func groupedFormStyleOnMac() -> some View {
        #if os(macOS)
        formStyle(.grouped)
        #else
        self
        #endif
    }

    /// `.listStyle(.inset)` on macOS, for a list inside a sheet. iOS and
    /// visionOS keep their default.
    func insetListStyleOnMac() -> some View {
        #if os(macOS)
        listStyle(.inset)
        #else
        self
        #endif
    }

    /// `.listStyle(.plain)` on iOS and visionOS, for a picker's list that
    /// should run edge to edge instead of in inset groups. macOS keeps its
    /// default.
    func plainListStyleOffMac() -> some View {
        #if os(macOS)
        self
        #else
        listStyle(.plain)
        #endif
    }

    /// The mini switch a grouped form draws for a toggle, on macOS, for a
    /// toggle that shares its row with other views (a rule's enable switch
    /// beside its summary and menu). Left automatic, a Mac toggle outside a
    /// form row of its own can draw as a checkbox (the rules list's did),
    /// and a bare `.switch` is the regular size, a step larger than the
    /// form's. iOS and visionOS toggles are this switch already.
    ///
    /// Applied by `RowSwitch`, which is where the label belongs too; a
    /// call site that writes the style itself has to hide the label
    /// itself, and that is what #2040 was.
    func miniSwitchStyleOnMac() -> some View {
        #if os(macOS)
        toggleStyle(.switch)
            .controlSize(.mini)
        #else
        self
        #endif
    }
}

/// A switch that shares its row with other views, so it shows no label of
/// its own but still answers to one.
///
/// `.labelsHidden()` is the obvious way to drop the text, and on macOS it
/// is also what makes the control speak as a **toggle button** instead of
/// a **switch**: every other pane's switch reads `AXSwitch`, and the rules
/// list's read `AXCheckBox`/`AXToggle`, role description "toggle button"
/// (#2040). Measured on macOS 27 over thirteen spellings of the same
/// switch (`~/Code/cabal/fixer/probe-2040-switch-ax.swift`):
///
/// - `.labelsHidden()`, any toggle style — `AXToggle`, "toggle button".
/// - `.labelsHidden()` **plus `.accessibilityLabel`** — still `AXToggle`.
///   The obvious remedy does not touch the role.
/// - `.labelsVisibility(.hidden)`, the modern spelling of the same ask —
///   still `AXToggle`, and nameless as well.
/// - a label kept in the toggle and squeezed to no width — `AXSwitch`,
///   "switch", and `.accessibilityLabel` then names it, which the
///   Notifications switches it now matches do not even do.
///
/// So macOS keeps the label and takes its width away. iOS and visionOS
/// keep `.labelsHidden()`: their default switch reads correctly already,
/// and a zero-width label there leaves the toggle's own `Spacer` free to
/// push the switch across the row it shares.
struct RowSwitch: View {
    /// The gap a toggle leaves between its label and its control, which a
    /// zero-width label does not remove.
    static let labelGap: CGFloat = 8

    let label: String
    @Binding var isOn: Bool

    var body: some View {
        #if os(macOS)
        Toggle(isOn: $isOn) {
            // Not `.labelsHidden()`: see the type's doc. `.clipped()` so
            // the text cannot draw outside the width it was given.
            Text(label)
                .frame(width: 0)
                .clipped()
        }
        .accessibilityLabel(label)
        .miniSwitchStyleOnMac()
        // A zero-width label still gets the toggle's label-to-control gap,
        // which would move the switch 8 pt along the row it shares — 20 pt
        // from the leading edge before, 28 after (measured, macOS 27).
        // Taking the gap back keeps the row's footprint exactly where
        // `.labelsHidden()` drew it; `RowSwitchAccessibilityTests` pins it.
        .padding(.leading, -Self.labelGap)
        #else
        Toggle(label, isOn: $isOn)
            .labelsHidden()
        #endif
    }
}
