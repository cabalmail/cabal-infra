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
/// too small at the handoff sizes). Decorative — it stands in for the
/// sidebar's "Folders" title, so it carries that accessibility label
/// rather than being hidden.
struct CabalmailMark: View {
    let size: CGFloat

    var body: some View {
        Image("CabalmailMark")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(ColorTokens.brandForest)
            .accessibilityLabel("Folders")
    }
}
