#if os(iOS) || os(visionOS)
import SwiftUI
import Contacts
import ContactsUI
import CabalmailKit

/// Which address-book action a header address menu asked for.
enum ContactEditorMode {
    /// Create a brand-new contact, pre-filled with the address (and parsed
    /// name when unambiguous).
    case new
    /// Add the address to an existing contact — the system "unknown contact"
    /// card offers "Add to Existing Contact".
    case addExisting
}

/// Identifiable payload that drives the contact-editor sheet from
/// `MessageDetailView`.
struct ContactEditorRequest: Identifiable {
    let id = UUID()
    let mode: ContactEditorMode
    let email: String
    let name: String?
}

/// Wraps the system `CNContactViewController` so the header address menu's
/// "New Contact" / "Add to Contact" actions present the native editor. The
/// user reviews the pre-filled details and taps Done to save (or Cancel),
/// which keeps authorship of any address-book write with the user rather
/// than writing silently — see the privacy contract in
/// `docs/0.9.x/apple-contacts-integration-plan.md`.
///
/// iOS / iPadOS / visionOS only. macOS has no equivalent modal editor and
/// omits the two Contacts menu items entirely.
struct ContactEditorView: UIViewControllerRepresentable {
    let request: ContactEditorRequest
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onClose: onClose) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let contact = Self.makeContact(for: request)
        let controller: CNContactViewController
        switch request.mode {
        case .new:
            controller = CNContactViewController(forNewContact: contact)
        case .addExisting:
            controller = CNContactViewController(forUnknownContact: contact)
            controller.allowsActions = true
            controller.allowsEditing = true
            // `forUnknownContact` is built to be pushed onto an existing
            // navigation stack (it relies on a back button); presented in
            // our own modal nav controller it has no way out, so add an
            // explicit Cancel.
            controller.navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .cancel,
                target: context.coordinator,
                action: #selector(Coordinator.cancel)
            )
        }
        controller.delegate = context.coordinator
        controller.contactStore = CNContactStore()
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    /// Builds the seed contact: the address always, plus given / middle /
    /// family names when `ContactNameComponents.parse` is confident enough
    /// to split the display phrase.
    private static func makeContact(for request: ContactEditorRequest) -> CNMutableContact {
        let contact = CNMutableContact()
        contact.emailAddresses = [
            CNLabeledValue(label: CNLabelOther, value: request.email as NSString)
        ]
        if let comps = ContactNameComponents.parse(request.name) {
            if let given = comps.given { contact.givenName = given }
            if let middle = comps.middle { contact.middleName = middle }
            if let family = comps.family { contact.familyName = family }
        }
        return contact
    }

    final class Coordinator: NSObject, CNContactViewControllerDelegate {
        let onClose: () -> Void
        init(onClose: @escaping () -> Void) { self.onClose = onClose }

        @objc func cancel() { onClose() }

        func contactViewController(
            _ viewController: CNContactViewController,
            didCompleteWith contact: CNContact?
        ) {
            onClose()
        }
    }
}
#endif
