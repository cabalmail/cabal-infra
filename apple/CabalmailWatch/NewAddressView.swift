import CabalmailKit
import SwiftUI
import WatchKit

/// The watch's new-address flow, tuned for the wrist scenario: someone just
/// asked for your email. One optional dictated label, a domain picker (only
/// when the deployment has more than one), a pre-randomized address with a
/// reroll button, Create — then the finished address big enough to read
/// aloud. watchOS has no pasteboard, so "show it large" IS the hand-off.
///
/// The username/subdomain are always random (the iOS sheet's Random idiom —
/// same 8-alphanumeric pool as the React client). Hand-picking a memorable
/// local part is a phone-sized task; the wrist mints and moves on.
struct NewAddressView: View {
    @Environment(WatchAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var comment = ""
    @State private var username = NewAddressView.randomToken()
    @State private var subdomain = NewAddressView.randomToken()
    @State private var domain = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var created: String?

    var body: some View {
        Group {
            if let created {
                success(created)
            } else {
                form
            }
        }
        .navigationTitle("New Address")
        .task {
            // Fetch the entitled apex list (silent-fails to the configured
            // full list, matching the phone sheet) before seeding the
            // picker, so we never hand the user an apex the `/new` Lambda
            // will reject.
            await model.loadAllowedDomains()
            if domain.isEmpty, let first = model.domains.first?.domain {
                domain = first
            }
            #if DEBUG
            // Screenshot scaffolding for the success screen (see
            // WatchAppModel's preview seed).
            if ProcessInfo.processInfo.environment["CABAL_WATCH_PREVIEW"] == "created" {
                created = "\(username)@\(subdomain).\(domain)"
            }
            #endif
        }
    }

    // MARK: - Form

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                TextField("What's it for?", text: $comment)

                if model.domains.count > 1 {
                    // navigationLink style: the inline watch picker wants a
                    // fixed-height wheel and renders clipped inside a
                    // ScrollView; a pushed selection list is the watch idiom.
                    Picker("Domain", selection: $domain) {
                        ForEach(model.domains) { entry in
                            Text(entry.domain).tag(entry.domain)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }

                HStack(alignment: .firstTextBaseline) {
                    Text(preview)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    Spacer(minLength: 4)
                    Button {
                        username = Self.randomToken()
                        subdomain = Self.randomToken()
                    } label: {
                        Image(systemName: "die.face.5")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Reroll address")
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }

                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Create")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(domain.isEmpty || isSubmitting)
            }
        }
    }

    private var preview: String {
        domain.isEmpty ? "\(username)@\(subdomain)." : "\(username)@\(subdomain).\(domain)"
    }

    // MARK: - Success

    private func success(_ address: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Label("Created", systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                // Same treatment as the tap-a-row detail view: this screen
                // is shown across the same counters.
                LargeTypeAddress(address: address)
                Button("Done") { dismiss() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Actions

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
            try await model.createAddress(
                username: username,
                subdomain: subdomain,
                domain: domain,
                comment: trimmed.isEmpty ? nil : trimmed
            )
            WKInterfaceDevice.current().play(.success)
            created = "\(username)@\(subdomain).\(domain)"
        } catch let error as CabalmailError {
            WKInterfaceDevice.current().play(.failure)
            errorMessage = "\(error)"
        } catch {
            WKInterfaceDevice.current().play(.failure)
            errorMessage = error.localizedDescription
        }
    }

    /// Same character pool and length as the iOS sheet's Random button and
    /// the React Request form, so addresses minted from any client look
    /// alike.
    private static func randomToken() -> String {
        let alphanum = "abcdefghijklmnopqrstuvwxyz0123456789"
        return String((0..<8).map { _ in alphanum.randomElement() ?? "a" })
    }
}
