import SwiftUI

// Outside `WideMail.swift`'s iOS/macOS guard: the readers that declare
// `TrailingAddressInspectorItem` share their Mac branch with visionOS,
// where no shell sets the toggle and the item draws nothing.

/// The addresses inspector's open state and its toggle, handed down to the
/// readers by the Mac shell so each can draw the `@` toggle as its own last
/// toolbar item (`TrailingAddressInspectorItem`). Nil everywhere else,
/// including a message opened in a window of its own.
struct AddressInspectorToggle {
    let presented: Bool
    let toggle: () -> Void
}

extension EnvironmentValues {
    @Entry var addressInspectorToggle: AddressInspectorToggle?
}

/// The `@` toggle as a reader toolbar's last item, after a flexible space, so
/// it sits at the window toolbar's trailing edge beside the inspector it
/// opens. A reader declares it after its own items because a toolbar section
/// draws items in declaration order, and anything declared on a view outside
/// the reader comes *before* the reader's items whatever its placement.
/// Draws nothing unless the shell set `\.addressInspectorToggle`.
struct TrailingAddressInspectorItem: ToolbarContent {
    @Environment(\.addressInspectorToggle) private var inspector

    var body: some ToolbarContent {
        if let inspector {
            // visionOS has no `ToolbarSpacer`; no shell there sets the
            // toggle, so the item never draws on it anyway.
            #if os(iOS) || os(macOS)
            if #available(iOS 26.0, macOS 26.0, *) {
                ToolbarSpacer(.flexible)
            }
            #endif
            AddressInspectorToolbarItem(
                addressInspectorPresented: inspector.presented,
                placement: .automatic,
                toggle: inspector.toggle
            )
        }
    }
}

/// The addresses inspector's `@` toggle, ranked for the bar it sits in.
///
/// While the inspector is open this is the one item the bar must keep: on an
/// iPhone Duo the column beside it is narrow enough that Compose and `@` both
/// fold into the system overflow, which is inert on the 27.1 beta, and the
/// inspector then cannot be closed (#1670).
///
/// Closed, it still ranks with Compose rather than below it: this button is
/// the *only* entry point to addresses on the wide shells (`SettingsSheet`'s
/// own doc records the move out of the sheet), so folding it away takes the
/// feature with it (#1626). What the overflow may take is the More menu,
/// whose Mark All as Read is also on the folder list's context menu and on
/// ⌥⌘T.
struct AddressInspectorToolbarItem: ToolbarContent {
    let addressInspectorPresented: Bool
    /// Where the item sits when it isn't led by book pose.
    var placement: ToolbarItemPlacement = .primaryAction
    let toggle: () -> Void
    /// At the bar's leading end in book pose (`\.listBarItemsLead`).
    @Environment(\.listBarItemsLead) private var itemsLead

    var body: some ToolbarContent {
        if addressInspectorPresented {
            ToolbarItem(placement: .listBar(placement, leads: itemsLead)) { addressInspectorToggle }
                .keepsInBarFirst()
        } else {
            ToolbarItem(placement: .listBar(placement, leads: itemsLead)) { addressInspectorToggle }
                .keepsInBar()
        }
    }

    private var addressInspectorToggle: some View {
        Button(action: toggle) {
            // Titled, so the button survives folding: the system overflow
            // draws a menu row, and a row with only an image and an
            // `accessibilityLabel` has nothing to draw (#1787). The bar
            // itself still shows the icon alone.
            Label("Addresses", systemImage: "at")
        }
        // Kept as `at`, the identifier the icon-only button derived from its
        // SF Symbol; a titled button derives none.
        .accessibilityIdentifier("at")
    }
}
