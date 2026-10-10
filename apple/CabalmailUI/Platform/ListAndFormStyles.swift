import SwiftUI

// List and form styles that one platform asks for and the others leave at
// their default. Named for where they apply, since the style itself is the
// same call everywhere; the point is that a feature view doesn't write the
// platform conditional (`docs/apple.md`, "Platform conditionals").

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
}
