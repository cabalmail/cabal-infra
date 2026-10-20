import Foundation
import Observation
import CabalmailKit

/// The recovery email (auth parity B4; `docs/auth.md`, "Recovery email"):
/// see it, add or change it, send a code and verify it. One model drives
/// the Account settings page and the sheet the check after sign-in raises
/// (`RecoveryEmailCheck`), the way the webmail's Security section and its
/// VerifyEmail gate share their calls.
@Observable
@MainActor
final class RecoveryEmailModel {
    enum Step: Equatable {
        case loading
        case failed(String)
        /// The address, or its absence, and what can be done with it.
        case showing
        case editing
        /// A code is on its way to the address; the user enters it.
        case verifying
    }

    let smsEnabled: Bool
    private(set) var step: Step
    private(set) var contacts: RecoveryContacts?
    var draft = ""
    var code = ""
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    private(set) var notice: String?

    @ObservationIgnored private let auth: AuthService

    /// With a `prompt` from the check after sign-in, the model starts where
    /// that prompt points (adding, or offering to verify) without reading
    /// `GetUser` again; without one, `load()` reads it.
    init(auth: AuthService, smsEnabled: Bool, prompt: RecoveryEmailPrompt? = nil) {
        self.auth = auth
        self.smsEnabled = smsEnabled
        switch prompt {
        case .add:
            contacts = RecoveryContacts(email: nil, emailVerified: false, phoneVerified: false)
            step = .editing
        case .verify(let address):
            contacts = RecoveryContacts(email: address, emailVerified: false, phoneVerified: false)
            step = .showing
        case nil:
            step = .loading
        }
    }

    var address: String? { contacts?.email }
    var phoneVerified: Bool { contacts?.phoneVerified ?? false }
    var isVerified: Bool { contacts?.emailVerified ?? false }
    var normalizedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    var normalizedCode: String { code.filter(SignUpModel.isASCIIDigit) }
    var canSave: Bool { !isWorking && SignUpModel.isAddressShaped(normalizedDraft) }
    var canVerify: Bool { !isWorking && normalizedCode.count == 6 }

    /// What the showing step says, in the webmail's words.
    var statusText: String {
        guard let address else {
            return smsEnabled && (contacts?.phoneVerified ?? false)
                ? "You have no recovery email. Your phone number recovers your account; an address outside "
                    + "Cabalmail also gets you back in if you lose your phone."
                : "You have no recovery email. Add an address outside Cabalmail so you can get back in if you "
                    + "forget your password."
        }
        return isVerified
            ? "\(address) is verified and can be used to recover your account."
            : "\(address) is not verified yet, so it can't be used to recover your account."
    }

    /// The editing step's help. Changing a verified address warns first:
    /// the pool keeps no pending value, so the old one stops counting at
    /// once.
    var editingHelp: String {
        if let address, isVerified {
            return "Use an address outside Cabalmail. Until you verify it, \(address) stops being used for recovery."
        }
        return "Use an address outside Cabalmail: a mailbox you're locked out of can't receive its own reset code."
    }

    func load() async {
        step = .loading
        errorMessage = nil
        do {
            contacts = try await auth.recoveryContacts()
            step = .showing
        } catch {
            step = .failed("Couldn't load your recovery email. \(SignUpErrorText.message(for: error))")
        }
    }

    func startEditing() {
        draft = ""
        errorMessage = nil
        notice = nil
        step = .editing
    }

    func cancel() {
        errorMessage = nil
        step = .showing
    }

    func save() async {
        guard step == .editing, canSave else { return }
        let address = normalizedDraft
        await perform {
            try await auth.setRecoveryEmail(address)
            contacts = RecoveryContacts(email: address, emailVerified: false, phoneVerified: phoneVerified)
            code = ""
            step = .verifying
            notice = "A verification code is on its way to \(address)."
        }
    }

    func sendCode() async {
        guard let address, !isWorking else { return }
        await perform {
            try await auth.sendRecoveryEmailCode()
            code = ""
            step = .verifying
            notice = "A verification code is on its way to \(address)."
        }
    }

    func verify() async {
        guard step == .verifying, canVerify, let address else { return }
        let entered = normalizedCode
        await perform {
            try await auth.verifyRecoveryEmail(code: entered)
            contacts = RecoveryContacts(email: address, emailVerified: true, phoneVerified: phoneVerified)
            code = ""
            step = .showing
            notice = "Email verified. It can now be used to recover your account."
        }
    }

    private func perform(_ action: () async throws -> Void) async {
        isWorking = true
        errorMessage = nil
        notice = nil
        defer { isWorking = false }
        do {
            try await action()
        } catch {
            errorMessage = SignUpErrorText.message(for: error)
        }
    }
}

/// The check after an interactive sign-in (`docs/auth.md`, "After
/// sign-in"; plan D5): one `GetUser`, and what to ask, or nil. A failed
/// read never blocks the sign-in, so it answers nil.
enum RecoveryEmailCheck {
    static func prompt(auth: AuthService, smsEnabled: Bool) async -> RecoveryEmailPrompt? {
        guard let contacts = try? await auth.recoveryContacts() else { return nil }
        return contacts.promptAfterSignIn(smsEnabled: smsEnabled)
    }
}
