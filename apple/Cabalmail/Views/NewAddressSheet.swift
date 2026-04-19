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

    var body: some View {
        NavigationStack {
            Form {
                Section("New address") {
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
