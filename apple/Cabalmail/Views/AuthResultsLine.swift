import SwiftUI
import CabalmailKit

/// Compact authentication line for the message-detail header: one chip per
/// method (SPF / DKIM / DMARC) colored by verdict, plus a short warning
/// sentence when the message failed authentication. Rendered in all three
/// `AuthVerificationState`s — "Not verified" shows muted so absent data is
/// honest without being alarming, and never dresses up as a pass.
///
/// Compiled into both the iOS and macOS targets (this directory is shared
/// per `project.yml`); the bucketing itself lives in CabalmailKit.
struct AuthResultsLine: View {
    let results: AuthResults?

    var body: some View {
        if let results, !results.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    chip(method: "SPF", token: results.spf)
                    chip(method: "DKIM", token: results.dkim)
                    chip(method: "DMARC", token: results.dmarc)
                }
                if AuthVerificationState(results) == .warning {
                    // Deliberately "could not be authenticated", not
                    // "dangerous" — forwarding legitimately breaks these
                    // checks.
                    Label(Self.warningCopy, systemImage: "exclamationmark.shield.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        } else {
            Text("Not verified")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Sender authentication: not verified")
        }
    }

    /// Shared with the list row's warning icon so both surfaces speak with
    /// one voice.
    static let warningCopy =
        "This message could not be authenticated as coming from its claimed sender."

    /// One method chip. An absent token renders an em dash on the neutral
    /// tint — a method that wasn't evaluated must look distinct from a
    /// pass. Fixed padding keeps the chip footprint stable across verdicts.
    private func chip(method: String, token: String?) -> some View {
        HStack(spacing: 3) {
            Text(method)
                .fontWeight(.semibold)
            Text(token ?? "—")
        }
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(color(for: token))
        .background(color(for: token).opacity(0.12), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(method) \(token ?? "not checked")")
    }

    private func color(for token: String?) -> Color {
        switch AuthMethodSeverity(token: token) {
        case .ok: return .green
        case .bad: return .orange
        case .neutral: return .secondary
        }
    }
}
