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
    #if os(iOS) || os(visionOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    #endif

    @State private var username: String = ""
    @State private var subdomain: String = ""
    @State private var domain: String = ""
    @State private var comment: String = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

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
                .onAppear {
                    if domain.isEmpty, let first = domains.first?.domain {
                        domain = first
                    }
                }
        }
        // Size the sheet to the form's actual height instead of a fixed
        // card. `.fitted` measures the content's ideal size, which works
        // because the regular-width layout (macOS and iPad) is the
        // hand-built VStack in `cardContent` — it reports a real intrinsic
        // width and height. (A `Form` cannot be measured this way: it
        // reports no compact ideal size, so `.fitted` over a Form collapses
        // to a tiny box.) On compact-width iPhone `presentationSizing` is
        // ignored, so the `Form` there keeps its full-height card.
        .presentationSizing(.fitted)
    }

    // MARK: - Platform layouts
    //
    // Two layouts, chosen by how the sheet is sized:
    //
    // - `cardContent` — a hand-built VStack used on macOS and on
    //   regular-width iOS/visionOS (iPad). It has a real intrinsic height,
    //   so `.presentationSizing(.fitted)` can shrink the sheet to the form
    //   instead of leaving ~40% empty space. It reproduces the grouped
    //   look manually: in-field placeholders, an `@`/`.` email-shaped row,
    //   and headline section captions.
    // - `formContent` — SwiftUI's grouped `Form`, used only on
    //   compact-width iPhone, where the sheet is a full-height card and
    //   `presentationSizing` is ignored, so the Form's inability to
    //   self-size to its content doesn't matter. (A `Form` also renders
    //   cleaner grouped sections than the hand-built layout when it has the
    //   full card to fill.)

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        cardContent
        #else
        if hSizeClass == .regular {
            cardContent
        } else {
            formContent
        }
        #endif
    }

    private var cardContent: some View {
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
                    .disabled(domains.isEmpty)
                Spacer()
            }
        }
        .padding(24)
        .frame(width: 460, alignment: .leading)
    }

    #if os(iOS) || os(visionOS)
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
                    .disabled(domains.isEmpty)
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
                Text("domain").tag("")
                ForEach(domains) { entry in
                    Text(entry.domain).tag(entry.domain)
                }
            }
            .labelsHidden()
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
    /// form's Random button). Keeps the character pools identical so
    /// addresses minted from either client look the same.
    private func randomize() {
        let alphanum = "abcdefghijklmnopqrstuvwxyz0123456789"
        username = String((0..<8).map { _ in alphanum.randomElement() ?? "a" })
        subdomain = String((0..<8).map { _ in alphanum.randomElement() ?? "a" })
        if domain.isEmpty, let first = domains.first?.domain {
            domain = first
        }
    }
}
