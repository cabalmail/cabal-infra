import SwiftUI

// Sidebar branding: the swatch color wash and the Cabalmail mark.
//
// Both come from the sidebar-branding design handoff. The wash and the
// mark are decorative only — fixed values, no state, no interactions —
// and sit behind / above the native sidebar chrome without replacing
// any system control.

// MARK: - Color wash

/// The four admin-app address swatches as soft radial blobs behind the
/// sidebar material, at a fixed 20% opacity. Scope differs per platform
/// (`MailRootView` applies it): the whole folder screen on iPhone,
/// the sidebar column only on iPad and macOS. The native list above it
/// hides its scroll background (`.scrollContentBackground(.hidden)`) so
/// the wash reads as color seen through the system material.
struct SidebarWash: View {
    @Environment(\.colorScheme) private var colorScheme

    /// One swatch from `react/admin/src/utils/addressSwatch.js`, as the
    /// sRGB approximations pinned in the design handoff.
    private struct Swatch {
        let light: Color
        let dark: Color

        init(light: UInt32, dark: UInt32) {
            self.light = Color(rgb: light)
            self.dark = Color(rgb: dark)
        }
    }

    /// One wash blob: a swatch plus its center and extent as fractions of
    /// the wash container.
    private struct Blob {
        let swatch: Swatch
        let center: UnitPoint
        let extent: CGSize
    }

    // Blob geometry from the handoff: each gradient fades to transparent
    // at 70% of its radius. Extents overshoot the container on purpose
    // (the blobs bleed past the edges), so the body clips to bounds.
    private static let blobs: [Blob] = [
        Blob(
            swatch: Swatch(light: 0x286CAB, dark: 0x79BDFF), // azure
            center: UnitPoint(x: 0.12, y: 0.04),
            extent: CGSize(width: 0.90, height: 0.55)
        ),
        Blob(
            swatch: Swatch(light: 0xA16100, dark: 0xFAB45F), // amber
            center: UnitPoint(x: 0.92, y: 0.22),
            extent: CGSize(width: 0.75, height: 0.45)
        ),
        Blob(
            swatch: Swatch(light: 0x2B633A, dark: 0x79C289), // forest
            center: UnitPoint(x: 0.10, y: 0.62),
            extent: CGSize(width: 0.85, height: 0.50)
        ),
        Blob(
            swatch: Swatch(light: 0x793974, dark: 0xE39BDC), // plum
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
        let color = colorScheme == .dark ? blob.swatch.dark : blob.swatch.light
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

private extension Color {
    /// sRGB color from a 24-bit `0xRRGGBB` literal.
    init(rgb: UInt32) {
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
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
            .foregroundStyle(Color("LogoTint"))
            .accessibilityLabel("Folders")
    }
}
