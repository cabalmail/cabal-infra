import XCTest
import SwiftUI
import AppKit
import CabalmailKit
@testable import CabalmailUI

// On the Mac the From list's filter field has focus as the list opens, so
// typing narrows it at once (`HostPlatform.focusesPickerFilterOnOpen`). The
// view sets that focus one turn after its first pass: set on the first pass,
// SwiftUI drops it and the window keeps first responder. Measured in this
// harness before the fix, `.task`, `.onAppear` and `.defaultFocus` each left
// the window as first responder; a yield first, or a `DispatchQueue.main`
// hop, put the field editor there. Measured in an `_NSPopoverWindow` too,
// which is what the field opens the list in.
@MainActor
final class FromAddressListFocusTests: XCTestCase {

    func testTheFilterFieldHasFocusOnceTheListIsUp() async throws {
        let list = FromAddressList(
            addresses: [Address(address: "daily@qa0722.cabal-mail.com", subdomain: "qa0722", tld: "cabal-mail.com")],
            selected: nil,
            onPick: { _ in },
            onCreateAddress: {}
        )
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -8000, y: -8000), size: NSSize(width: 380, height: 440)),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.orderOut(nil)
            window.close()
        }
        window.contentView = NSHostingView(rootView: list.frame(width: 380, height: 440))
        window.makeKeyAndOrderFront(nil)

        // The field editor AppKit lends a focused text field.
        try await waitUntilOnMainActor { window.firstResponder is NSTextView }
    }
}
