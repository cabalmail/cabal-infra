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
/// The last spelling, as #2040 first shipped it (a `Text` squeezed with
/// `.frame(width: 0)`), took its room back in a grouped `Form`, where every
/// `RowSwitch` lives. A switch toggle lays its label and switch out
/// through `LabeledContent`, which a grouped form stretches across the row:
/// the toggle took half the rule row from the summary, so the summary's
/// chevron landed mid-row, and the zero-width "Enabled" wrapped a letter
/// to a line, which made the row seven lines tall with the switch at its
/// top. `.fixedSize()` does not rescue it, because the form gives the toggle
/// a wide ideal width too. An `.accessibilityRepresentation` over a
/// `.labelsHidden()` switch draws right and speaks as a switch, but
/// VoiceOver's element comes out at the regular switch's 54×24 whatever
/// control size it is given, so its cursor overhangs the 36×16 mini switch
/// drawn.
///
/// So the macOS switch keeps its label and lays itself out through
/// `SwitchOnlyLabeledContentStyle`, which gives the label a box of no size
/// and puts the switch at once after it. It draws exactly what
/// `.labelsHidden()` drew, in a form or out of one, and still reads as a
/// named `AXSwitch`; `RowSwitchAccessibilityTests` holds both halves in a
/// grouped form. iOS and visionOS keep `.labelsHidden()`: their default
/// switch reads correctly already.
struct RowSwitch: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        #if os(macOS)
        Toggle(label, isOn: $isOn)
            .labeledContentStyle(SwitchOnlyLabeledContentStyle())
            .accessibilityLabel(label)
            .miniSwitchStyleOnMac()
        #else
        Toggle(label, isOn: $isOn)
            .labelsHidden()
        #endif
    }
}

/// `RowSwitch`'s layout on macOS: the switch alone, with the label kept in
/// the view at no size so the toggle still counts as labelled. Not
/// `.hidden()` on the label: that reads as a hidden label again, a toggle
/// button (#2040).
private struct SwitchOnlyLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 0) {
            configuration.label
                .frame(width: 0, height: 0)
                .clipped()
            configuration.content
        }
    }
}
