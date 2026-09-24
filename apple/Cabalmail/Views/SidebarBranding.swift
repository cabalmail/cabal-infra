import SwiftUI
import CabalmailKit

// Sidebar branding: the swatch color wash and the Cabalmail mark.
//
// Both come from the sidebar-branding design handoff. The wash and the
// mark are decorative only — fixed values, no state, no interactions —
// and sit behind / above the native sidebar chrome without replacing
// any system control.

// MARK: - Color wash

/// The four accent tokens the web app's address swatches use, as soft
/// radial blobs behind the
/// sidebar material, at a fixed 20% opacity. Scope differs per platform
/// (`MailRootView` applies it): the whole folder screen on iPhone,
/// the sidebar column only on iPad and macOS. The native list above it
/// hides its scroll background (`.scrollContentBackground(.hidden)`) so
/// the wash reads as color seen through the system material.
struct SidebarWash: View {
    /// One wash blob: an accent token (the catalog resolves its light and
    /// dark values) plus its center and extent as fractions of the wash
    /// container.
    private struct Blob {
        let color: Color
        let center: UnitPoint
        let extent: CGSize
    }

    // Blob geometry from the handoff: each gradient fades to transparent
    // at 70% of its radius. Extents overshoot the container on purpose
    // (the blobs bleed past the edges), so the body clips to bounds.
    private static let blobs: [Blob] = [
        Blob(
            color: ColorTokens.accentAzureFg,
            center: UnitPoint(x: 0.12, y: 0.04),
            extent: CGSize(width: 0.90, height: 0.55)
        ),
        Blob(
            color: ColorTokens.accentAmberFg,
            center: UnitPoint(x: 0.92, y: 0.22),
            extent: CGSize(width: 0.75, height: 0.45)
        ),
        Blob(
            color: ColorTokens.accentForestFg,
            center: UnitPoint(x: 0.10, y: 0.62),
            extent: CGSize(width: 0.85, height: 0.50)
        ),
        Blob(
            color: ColorTokens.accentPlumFg,
            center: UnitPoint(x: 0.88, y: 0.98),
            extent: CGSize(width: 0.90, height: 0.55)
        ),
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(Self.blobs.indices, id: \.self) { index in
                    gradient(for: Self.blobs[index], in: geo.size)
                }
            }
        }
        .opacity(0.20)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func gradient(for blob: Blob, in size: CGSize) -> some View {
        let color = blob.color
        return EllipticalGradient(
            stops: [
                .init(color: color, location: 0),
                .init(color: color.opacity(0), location: 0.7),
            ],
            center: .center,
            startRadiusFraction: 0,
            endRadiusFraction: 0.5
        )
        // The gradient ellipse matches its frame's aspect, so a frame of
        // twice the extent centered on the blob's anchor reproduces the
        // handoff's `radial-gradient(w h at x y)` geometry exactly.
        .frame(
            width: blob.extent.width * 2 * size.width,
            height: blob.extent.height * 2 * size.height
        )
        .position(
            x: blob.center.x * size.width,
            y: blob.center.y * size.height
        )
    }
}

// MARK: - Cabalmail mark

/// The Cabalmail mark (mark only, never the wordmark), tinted per theme
/// via the `LogoTint` colorset. The size is the mark's square bounding
/// box — 132 pt iPhone / 102 pt iPad / 90 pt macOS, three times the
/// handoff's original values (the asset's built-in padding left the ink
/// too small at the handoff sizes). Decorative — it stands in for a
/// screen's navigation title (the sidebar's "Folders", or each compact
/// tab's own), so it carries that accessibility label rather than being
/// hidden.
struct CabalmailMark: View {
    let size: CGFloat
    /// The title the mark stands in for. Defaults to the Mail sidebar's
    /// "Folders"; the other compact tabs pass their own so VoiceOver still
    /// hears which screen it is on.
    var accessibilityTitle: String = "Folders"

    var body: some View {
        Image("CabalmailMark")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(ColorTokens.brandForest)
            .accessibilityLabel(accessibilityTitle)
    }
}

#if !os(macOS)
// MARK: - Mark as navigation title

/// The mark size the compact iPhone tabs and the iPad floating folder panel
/// use; `MailRootView` passes 102 for the wide iPad sidebar.
let compactBrandMarkSize: CGFloat = 132

/// Puts the Cabalmail mark where a screen's navigation title would go
/// (iOS / iPadOS / visionOS; macOS hosts the mark in its sidebar directly).
///
/// Inline display mode suppresses the large title, the clear principal item
/// suppresses the inline text, and the screen's own `.navigationTitle` string
/// stays for VoiceOver and the back button. The mark rides the leading
/// toolbar slot — the system sidebar toggle and the compact New / Reload
/// buttons keep their own slots.
private struct BrandMarkTitle: ViewModifier {
    let size: CGFloat
    let accessibilityTitle: String

    func body(content: Content) -> some View {
        content
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Color.clear.frame(width: 1, height: 1)
                }
                // On OS 26's liquid glass, a bare toolbar item gets wrapped
                // in a glass capsule, which makes the decorative mark read as
                // a button. Detach it from the shared glass background where
                // the API exists; earlier systems render toolbar images plain
                // anyway. The SDK marks `sharedBackgroundVisibility`
                // explicitly unavailable on visionOS (a runtime `#available`
                // check can't gate a symbol the compiler rejects), so the
                // visionOS build takes the plain path.
                #if os(visionOS)
                ToolbarItem(placement: .topBarLeading) {
                    CabalmailMark(size: size, accessibilityTitle: accessibilityTitle)
                }
                #else
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .topBarLeading) {
                        CabalmailMark(size: size, accessibilityTitle: accessibilityTitle)
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .topBarLeading) {
                        CabalmailMark(size: size, accessibilityTitle: accessibilityTitle)
                    }
                }
                #endif
            }
    }
}

/// True inside the compact iPhone section tab bar (see
/// `CompactSectionTabs`), where every tab's root screen heads itself with the
/// Cabalmail mark instead of a text title. False everywhere else, so the
/// same `SettingsView` / `AddressListView` bodies keep their text titles in
/// the iPad settings sheet and the wide sidebar's inspector, where the mark
/// would crowd a Done button or repeat the one already in the sidebar.
///
/// An environment flag rather than a size-class check, for the same reason
/// as `inSettingsSheet`: sheet content reports a compact size class too.
private struct ShowsCompactBrandMarkKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var showsCompactBrandMark: Bool {
        get { self[ShowsCompactBrandMarkKey.self] }
        set { self[ShowsCompactBrandMarkKey.self] = newValue }
    }
}

/// `brandMarkTitle` gated on `showsCompactBrandMark`, for the tab roots
/// that also render outside the compact tab bar.
private struct CompactBrandMarkTitle: ViewModifier {
    let accessibilityTitle: String
    @Environment(\.showsCompactBrandMark) private var showsCompactBrandMark

    func body(content: Content) -> some View {
        if showsCompactBrandMark {
            content.brandMarkTitle(size: compactBrandMarkSize, accessibilityTitle: accessibilityTitle)
        } else {
            content
        }
    }
}

extension View {
    /// Replaces this screen's visible navigation title with the Cabalmail
    /// mark, unconditionally. `accessibilityTitle` is what VoiceOver reads in
    /// its place — pass the same string as the `.navigationTitle`.
    func brandMarkTitle(size: CGFloat, accessibilityTitle: String = "Folders") -> some View {
        modifier(BrandMarkTitle(size: size, accessibilityTitle: accessibilityTitle))
    }

    /// Replaces this screen's visible navigation title with the Cabalmail
    /// mark when hosted in the compact iPhone tab bar; a no-op elsewhere.
    func compactBrandMarkTitle(accessibilityTitle: String) -> some View {
        modifier(CompactBrandMarkTitle(accessibilityTitle: accessibilityTitle))
    }
}
#endif
