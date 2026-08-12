import CabalmailKit
import SwiftUI

/// What the Contacts button at the trailing edge of a recipient field can do,
/// given the Contacts authorization state and whether the address-book
/// snapshot came back with anything in it.
///
/// A plain value rather than a scatter of `candidates.isEmpty` checks, so the
/// two invariants the compose surface owes the user are stated once and
/// testable without driving the UI: a control that looks live is live, and a
/// control that can't open the picker still leads somewhere.
enum ContactsPickerAffordance: Equatable, CaseIterable {
    /// Contacts is readable and has candidates — open the picker.
    case pick
    /// Access has never been asked for on this device — ask, then the next
    /// tap picks.
    case requestAccess
    /// Access was refused or is restricted. Only the system can grant it, so
    /// the tap opens the privacy pane.
    case openSystemSettings
    /// Access is limited to a shared subset that has nothing we can address
    /// mail to. The address book itself may be full — widening the selection
    /// is a system affordance, so the tap opens the privacy pane.
    case shareMoreContacts
    /// Contacts is readable in full and genuinely has nothing to offer. The
    /// one state where an inert button is the honest answer.
    case noCandidates

    init(authorization: ContactsAuthorizationStatus, hasCandidates: Bool) {
        switch authorization {
        case .authorized:
            self = hasCandidates ? .pick : .noCandidates
        case .limited:
            // Not `.noCandidates`: under a limited grant an empty snapshot
            // says nothing about the device's address book, only about what
            // was shared with us, and the user can change that.
            self = hasCandidates ? .pick : .shareMoreContacts
        case .notDetermined:
            self = .requestAccess
        case .denied, .restricted:
            self = .openSystemSettings
        }
    }

    /// False only when the tap has nothing to do. Drives `.disabled(...)`.
    var isEnabled: Bool { self != .noCandidates }

    /// Opacity for the button's accent tint. A disabled control has to read
    /// as unavailable: the explicit `foregroundStyle` the button needs to
    /// stay accent-tinted when live also overrides SwiftUI's own disabled
    /// rendering, so the dimming is applied here instead.
    var tintOpacity: Double { isEnabled ? 1 : 0.35 }

    /// Tooltip / accessibility hint. `label` is the field's own name, so the
    /// three buttons in a compose window don't all read alike.
    func hint(for label: String) -> String {
        switch self {
        case .pick:
            return "Pick \(label) recipients from Contacts"
        case .requestAccess:
            return "Allow access to Contacts to pick \(label) recipients"
        case .openSystemSettings:
            return "Contacts access is off. Open Privacy settings to turn it on."
        case .shareMoreContacts:
            return "Only the contacts you shared are visible, and none have an email address. "
                + "Open Privacy settings to share more."
        case .noCandidates:
            return "No contacts with email addresses to pick from"
        }
    }
}

/// Opens the system privacy pane where Contacts access is granted. Split
/// from the view so the platform fork stays in one place.
enum ContactsPrivacySettings {
    static func open() {
        #if os(macOS)
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")
        if let url {
            NSWorkspace.shared.open(url)
        }
        #else
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }
}
