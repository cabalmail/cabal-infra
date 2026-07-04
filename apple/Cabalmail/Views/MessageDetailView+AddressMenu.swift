import SwiftUI
import CabalmailKit

// Per-address context menu for the detail header (From / To / Cc) plus the
// wrapping recipient layout it attaches to. Lifted out of the main file so
// `MessageDetailView` stays under SwiftLint's type_body_length cap; the
// actions read the view's `appState` / `ownedAddresses` / Contacts state and
// route compose through the existing `presentCompose(seed:)`.

extension MessageDetailView {
    /// Lays out a recipient line ("To:" / "Cc:") as one wrapping element per
    /// address, each carrying its own context menu, replacing the former
    /// single joined `Text`.
    @ViewBuilder
    func recipientFlow(label: String, addresses: [EmailAddress]) -> some View {
        FlowLayout(horizontalSpacing: 4, verticalSpacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(addresses.indices, id: \.self) { index in
                let address = addresses[index]
                // Trailing comma on all but the last keeps the line reading
                // like the old comma-joined list; it's part of the tappable
                // element so the whole token shares one menu.
                Text(index < addresses.count - 1 ? "\(address.formatted)," : address.formatted)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contextMenu { addressMenu(for: address) }
            }
        }
    }

    /// "Name <addr@host>" formatter that prefers the envelope's RFC 5322
    /// phrase first, then the user's own name from Contacts. Mirrors
    /// `EmailAddress.formatted` but with the contacts fallback wedged
    /// in between.
    func headerFromLabel(for address: EmailAddress) -> String {
        let addrPart = "\(address.mailbox)@\(address.host)"
        if let name = address.displayName, !name.isEmpty {
            return "\(name) <\(addrPart)>"
        }
        if let name = senderContactName, !name.isEmpty {
            return "\(name) <\(addrPart)>"
        }
        return addrPart
    }

    func hydrateSenderContactName(for address: EmailAddress) async {
        senderContactName = nil
        if let name = address.displayName, !name.isEmpty { return }
        senderContactName = await appState.contactsStore.displayName(for: address)
    }

    /// Right-click / long-press menu for a single header address.
    @ViewBuilder
    func addressMenu(for address: EmailAddress) -> some View {
        let email = canonicalEmail(for: address)
        Button {
            copyToPasteboard(email)
            appState.showToast(.addressCopied(email))
        } label: {
            Label("Copy Address", systemImage: "doc.on.doc")
        }
        Button {
            copyName(for: address)
        } label: {
            Label("Copy Name", systemImage: "person.text.rectangle")
        }

        Divider()

        Button {
            composeTo(address)
        } label: {
            Label("Compose Message To", systemImage: "square.and.pencil")
        }
        if let owned = ownedMatch(for: address) {
            Button {
                composeFrom(owned.address)
            } label: {
                Label("Compose Message From", systemImage: "paperplane")
            }
            // Revoke is offered only for addresses we manage — the same gate as
            // "Compose Message From" — since those are the only ones the
            // `/revoke` API will accept.
            Button(role: .destructive) {
                pendingRevoke = owned
            } label: {
                Label("Revoke", systemImage: "xmark.bin")
            }
        }

        #if os(iOS) || os(visionOS)
        // Contacts items appear only when access is granted or still
        // grantable; a denied / restricted book hides them. macOS omits them
        // entirely (no native modal contact editor).
        if contactsAuth.isAccessible || contactsAuth == .notDetermined {
            Divider()
            Button {
                requestContactEditor(.addExisting, for: address)
            } label: {
                Label("Add to Contact", systemImage: "person.crop.circle.badge.plus")
            }
            Button {
                requestContactEditor(.new, for: address)
            } label: {
                Label("New Contact", systemImage: "person.badge.plus")
            }
        }
        #endif
    }

    /// Loads the Contacts authorization state and the user's owned addresses
    /// so the menu can gate the Contacts and "Compose From" items. Cheap and
    /// idempotent — driven from the view's `.task`.
    func loadAddressMenuContext() async {
        contactsAuth = await appState.contactsStore.authorizationStatus
        if let client = appState.client, let list = try? await client.addresses() {
            ownedAddresses = list
        }
    }

    private func canonicalEmail(for address: EmailAddress) -> String {
        "\(address.mailbox)@\(address.host)"
    }

    /// The user's own address matching this header address (case-insensitive),
    /// or nil when it isn't one they own. Returns the full `Address` so callers
    /// can both compose from it and revoke it.
    private func ownedMatch(for address: EmailAddress) -> Address? {
        let target = canonicalEmail(for: address).lowercased()
        return ownedAddresses.first { $0.address.lowercased() == target }
    }

    private func copyName(for address: EmailAddress) {
        if let name = address.displayName, !name.isEmpty {
            copyToPasteboard(name)
            appState.showToast(Toast(kind: .success, message: "Name copied"))
            return
        }
        // No RFC 5322 phrase on the envelope — fall back to a Contacts name
        // before giving up.
        Task { @MainActor in
            if let name = await appState.contactsStore.displayName(for: address),
               !name.isEmpty {
                copyToPasteboard(name)
                appState.showToast(Toast(kind: .success, message: "Name copied"))
            } else {
                appState.showToast(Toast(kind: .info, message: "No name available"))
            }
        }
    }

    private func composeTo(_ address: EmailAddress) {
        presentCompose(seed: Draft(to: [address.formatted], composeIntent: .new))
    }

    private func composeFrom(_ ownedAddress: String) {
        presentCompose(seed: Draft(fromAddress: ownedAddress, composeIntent: .new))
    }

    // MARK: - Revoke confirmation

    /// Non-async entry point handed to `RevokeAddressConfirmation` (the dialog
    /// runs its Button actions synchronously). Kicks the API call onto a Task.
    func revoke(_ address: Address) {
        Task { await revokeAddress(address) }
    }

    private func revokeAddress(_ address: Address) async {
        guard let client = appState.client else { return }
        do {
            try await client.revokeAddress(
                address: address.address,
                subdomain: address.subdomain,
                tld: address.tld,
                publicKey: address.publicKey
            )
            // Drop it from the owned set so the menu's "Compose From" / "Revoke"
            // items disappear on the next open without a full re-fetch.
            ownedAddresses.removeAll { $0.address == address.address }
            appState.showToast(.addressRevoked(address.address))
        } catch {
            appState.showToast(Toast(kind: .error, message: "Couldn't revoke \(address.address)"))
        }
    }

    #if os(iOS) || os(visionOS)
    private func requestContactEditor(_ mode: ContactEditorMode, for address: EmailAddress) {
        let email = canonicalEmail(for: address)
        let name = address.displayName
        Task { @MainActor in
            var status = contactsAuth
            if status == .notDetermined {
                _ = await appState.contactsStore.requestAccess()
                status = await appState.contactsStore.authorizationStatus
                contactsAuth = status
            }
            guard status.isAccessible else {
                appState.showToast(Toast(kind: .info, message: "Contacts access denied"))
                return
            }
            contactEditorRequest = ContactEditorRequest(mode: mode, email: email, name: name)
        }
    }
    #endif
}

/// The header menu's "Revoke" confirmation dialog, extracted as a modifier so
/// its title / actions / message live outside `MessageDetailView` and don't
/// count against its SwiftLint type_body_length budget. Applied as a single
/// `.modifier(...)` line in `body`. Mirrors the wording of the address list's
/// own revoke dialog (`AddressListView`).
struct RevokeAddressConfirmation: ViewModifier {
    @Binding var pending: Address?
    let perform: (Address) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            pending.map { "Revoke \($0.address)?" } ?? "Revoke address?",
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            ),
            titleVisibility: .visible,
            presenting: pending
        ) { address in
            Button("Revoke", role: .destructive) {
                pending = nil
                perform(address)
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { address in
            Text("Mail sent to \(address.address) will be rejected. This can't be undone.")
        }
    }
}
