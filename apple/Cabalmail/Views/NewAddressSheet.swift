import SwiftUI
import CabalmailKit

/// Inline "Create new address…" form surfaced from the compose `From`
/// picker.
///
/// Per `docs/README.md`, minting a fresh relationship-scoped address every
/// time the user hands out their email is *the* Cabalmail idiom — the From
/// picker's primary action, not a secondary shortcut. This sheet mirrors
/// `react/admin/src/Addresses/Request.jsx`:
///
/// 1. Three fields — username, subdomain, domain (the TLD is picked from
///    the deployment's configured mail domains).
/// 2. A **Random** button that seeds all three with alphanumerics so users
///    who don't want to name the address themselves can produce a unique
///    one in a single tap.
/// 3. An optional comment that the Address record stores for later audit.
///
/// On success the new address is reported back to the parent via
/// `onCreate`, which typically selects it as the compose's From and dismisses
/// the sheet.
struct NewAddressSheet: View {
    let domains: [MailDomain]
    let onCreate: @MainActor (String) async -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var username: String = ""
    @State private var subdomain: String = ""
    @State private var domain: String = ""
    @State private var comment: String = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    // nil = still loading; a set (possibly empty) once `/list_my_domains`
    // has returned. Mirrors `react/admin/src/Addresses/Request.jsx`: on
    // fetch failure we fall back to the unfiltered `domains` list so a
    // transient error doesn't hide the picker; the `/new` Lambda still
    // rejects any request to a denied apex.
    @State private var allowedDomainNames: Set<String>?

    /// Domains the caller is entitled to mint on: `domains` intersected with
    /// the `/list_my_domains` allow list. While the allow list is loading
    /// this reads as empty so the picker shows a "Loading…" placeholder
    /// instead of transiently offering apexes the server would reject.
    private var visibleDomains: [MailDomain] {
        guard let allowed = allowedDomainNames else { return [] }
        return domains.filter { allowed.contains($0.domain) }
    }

    private var isLoadingDomains: Bool { allowedDomainNames == nil }
    private var noDomainsAvailable: Bool { !isLoadingDomains && visibleDomains.isEmpty }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Create Address")
                #if os(iOS) || os(visionOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            Task { await submit() }
                        } label: {
                            if isSubmitting {
                                ProgressView()
                            } else {
                                Text("Create")
                            }
                        }
                        .disabled(!canSubmit || isSubmitting)
                    }
                }
                .task { await loadAllowedDomains() }
        }
        // Size the sheet as a form card instead of a full-height card.
        // `.form` is a fixed system size, so the short form leaves blank
        // space below the fields on iPad — that's accepted deliberately.
        // Do NOT swap in `.fitted` to trim it: device-verified (0.11.2
        // TestFlight) that on iPad `.fitted` collapses this sheet to an
        // absurdly small box — both over the `Form` layout (no compact
        // ideal size) AND over a hand-built fixed-width VStack, i.e. the
        // NavigationStack-wrapped content never reports a usable intrinsic
        // height here. On compact-width iPhone `presentationSizing` is
        // ignored and the sheet keeps its full-height card presentation.
        // macOS keeps `.fitted`, where it does work: its layout pins its
        // own `.frame(width:)` and the sheet fits it correctly.
        #if os(macOS)
        .presentationSizing(.fitted)
        #else
        .presentationSizing(.form)
        #endif
    }

    // MARK: - Platform layouts
    //
    // `Form` is kept for iOS/visionOS, where its grouped list style renders
    // the field titles as in-field placeholders and section headers as tidy
    // group captions. On macOS that same `Form` instead pins every title as
    // an external left-hand label — which shatters the email-shaped row and
    // drops the in-field placeholders — so macOS gets a hand-built layout
    // that reproduces the iOS look: in-field placeholders, an `@`/`.`
    // email-shaped row, headline section captions, and real content margins.

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        macContent
        #else
        formContent
        #endif
    }

    #if os(macOS)
    private var macContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("New address")
                    .font(.headline)
                addressRow
                    .textFieldStyle(.roundedBorder)
                if let preview = composedAddress {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Comment")
                    .font(.headline)
                TextField("optional reminder", text: $comment)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            HStack {
                Button("Random", action: randomize)
                    .disabled(visibleDomains.isEmpty)
                Spacer()
            }
        }
        .padding(24)
        .frame(width: 460, alignment: .leading)
    }
    #else
    private var formContent: some View {
        Form {
            Section("New address") {
                addressRow
                if let preview = composedAddress {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Section("Comment") {
                TextField("optional reminder", text: $comment)
                    .autocorrectionDisabled()
            }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            Section {
                Button("Random", action: randomize)
                    .disabled(visibleDomains.isEmpty)
            }
        }
    }
    #endif

    /// The email-shaped input row shared by both layouts: `username @
    /// subdomain . domain`, with the domain drawn from the deployment's
    /// configured mail domains.
    @ViewBuilder
    private var addressRow: some View {
        HStack {
            TextField("username", text: $username)
                .autocorrectionDisabled()
                #if os(iOS) || os(visionOS)
                .textInputAutocapitalization(.never)
                #endif
            Text("@")
                .foregroundStyle(.secondary)
            TextField("subdomain", text: $subdomain)
                .autocorrectionDisabled()
                #if os(iOS) || os(visionOS)
                .textInputAutocapitalization(.never)
                #endif
            Text(".")
                .foregroundStyle(.secondary)
            Picker("", selection: $domain) {
                Text(domainPickerPlaceholder).tag("")
                ForEach(visibleDomains) { entry in
                    Text(entry.domain).tag(entry.domain)
                }
            }
            .labelsHidden()
            .disabled(isLoadingDomains || noDomainsAvailable)
        }
    }

    private var composedAddress: String? {
        guard !username.isEmpty, !subdomain.isEmpty, !domain.isEmpty else { return nil }
        return "\(username)@\(subdomain).\(domain)"
    }

    private var canSubmit: Bool {
        composedAddress != nil
    }

    private func submit() async {
        guard let address = composedAddress, let client = appState.client else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await client.requestAddress(
                username: username,
                subdomain: subdomain,
                tld: domain,
                comment: comment.isEmpty ? nil : comment,
                address: address
            )
            await onCreate(address)
            dismiss()
        } catch let error as CabalmailError {
            errorMessage = "\(error)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Seed each field with alphanumerics (mirroring the React Request
    /// form's Random button). `AddressMint` keeps the character pool
    /// identical so addresses minted from any surface look the same.
    private func randomize() {
        username = AddressMint.randomLabel()
        subdomain = AddressMint.randomLabel()
        if domain.isEmpty, let first = visibleDomains.first?.domain {
            domain = first
        }
    }

    private var domainPickerPlaceholder: String {
        if isLoadingDomains { return "Loading domains…" }
        if noDomainsAvailable { return "No domains available" }
        return "domain"
    }

    /// Populates `allowedDomainNames` from the `/list_my_domains` Lambda,
    /// then seeds the domain picker with the first entitled apex so the
    /// form starts usable. On failure we fall back to the full configured
    /// list (matching the React app) — the server still enforces
    /// entitlement, so the user just loses the client-side filter.
    private func loadAllowedDomains() async {
        guard allowedDomainNames == nil, let client = appState.client else { return }
        do {
            let allowed = try await client.allowedDomains()
            allowedDomainNames = Set(allowed)
        } catch {
            allowedDomainNames = Set(domains.map(\.domain))
        }
        if domain.isEmpty, let first = visibleDomains.first?.domain {
            domain = first
        }
    }
}
