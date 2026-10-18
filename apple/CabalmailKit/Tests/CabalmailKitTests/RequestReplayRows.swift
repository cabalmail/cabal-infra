import Foundation
@testable import CabalmailKit

/// Every request the Kit makes, with the verdict `docs/request-replay.md`
/// gives it: sent again after a dropped connection, or sent once.
/// `RequestReplayTableTests` drives each row through the real transport.
enum RequestReplayRows {
    enum Verdict: Sendable {
        case sentAgain
        case sentOnce

        var attempts: Int { self == .sentAgain ? 2 : 1 }

        var description: String {
            self == .sentAgain ? "the table says it is sent again" : "the table says it is sent once"
        }
    }

    struct ApiRow: Sendable {
        let endpoint: String
        let verdict: Verdict
        let call: @Sendable (URLSessionApiClient) async throws -> Void

        init(
            _ endpoint: String,
            _ verdict: Verdict,
            _ call: @escaping @Sendable (URLSessionApiClient) async throws -> Void
        ) {
            self.endpoint = endpoint
            self.verdict = verdict
            self.call = call
        }
    }

    struct CognitoRow: Sendable {
        let operation: String
        let verdict: Verdict
        /// Signed in first, for the calls that send the access token.
        let needsSession: Bool
        /// A sign-in that met a second-factor challenge first.
        let needsChallenge: Bool
        let call: @Sendable (CognitoAuthService) async throws -> Void

        init(
            _ operation: String,
            _ verdict: Verdict,
            needsSession: Bool = false,
            needsChallenge: Bool = false,
            _ call: @escaping @Sendable (CognitoAuthService) async throws -> Void
        ) {
            self.operation = operation
            self.verdict = verdict
            self.needsSession = needsSession
            self.needsChallenge = needsChallenge
            self.call = call
        }
    }

    static let api: [ApiRow] = mailWrites + accountWrites + feedWrites + reads

    private static let mailWrites: [ApiRow] = [
        ApiRow("set_flag", .sentAgain) {
            _ = try await $0.setFlag(SetFlagRequest(
                host: "h", folder: "INBOX", ids: [1], flag: "\\Seen", operation: "set",
                sortOrder: "REVERSE", sortField: "DATE"
            ))
        },
        ApiRow("move_messages", .sentAgain) {
            _ = try await $0.moveMessages(MoveMessagesRequest(
                host: "h", source: "INBOX", destination: "Archive", ids: [1], sortOrder: "REVERSE", sortField: "DATE"
            ))
        },
        ApiRow("purge_messages", .sentAgain) { try await $0.purgeMessages(host: "h", folder: "Trash", ids: [1]) },
        ApiRow("empty_trash", .sentOnce) { try await $0.emptyTrash(host: "h", folder: "Trash") },
        ApiRow("mark_folder_read", .sentAgain) { _ = try await $0.markFolderRead(host: "h", folder: "INBOX") },
        ApiRow("send", .sentAgain) {
            try await $0.sendMessage(SendMessageRequest(
                host: "h", smtpHost: "smtp-out.example", sender: "a@b.example", toList: ["c@d.example"],
                ccList: [], bccList: [], subject: "s", otherHeaders: ApiSendOtherHeaders(),
                htmlBody: "", textBody: "t", draft: false
            ))
        },
        ApiRow("save_draft", .sentAgain) {
            _ = try await $0.saveDraft(SaveDraftRequest(
                host: "h", sender: "a@b.example", toList: [], ccList: [], bccList: [], subject: "s",
                otherHeaders: ApiSendOtherHeaders(), htmlBody: "", textBody: ""
            ))
        },
        ApiRow("save_draft", .sentAgain) { _ = try await $0.discardDraft(host: "h", uid: 1, uidValidity: 1) },
        ApiRow("upload_url", .sentAgain) {
            _ = try await $0.requestAttachmentUploads(
                host: "h", files: [AttachmentUploadSlot(filename: "a.txt", mimeType: "text/plain")]
            )
        },
    ]

    private static let accountWrites: [ApiRow] = [
        ApiRow("new_folder", .sentOnce) { try await $0.createFolder(host: "h", parent: "", name: "n") },
        ApiRow("delete_folder", .sentOnce) { try await $0.deleteFolder(host: "h", name: "n") },
        ApiRow("subscribe_folder", .sentAgain) { try await $0.subscribeFolder(host: "h", folder: "n") },
        ApiRow("unsubscribe_folder", .sentAgain) { try await $0.unsubscribeFolder(host: "h", folder: "n") },
        ApiRow("new", .sentAgain) {
            try await $0.newAddress(
                username: "u", subdomain: "s", tld: "cabalmail.example", comment: nil,
                address: "u@s.cabalmail.example"
            )
        },
        ApiRow("revoke", .sentOnce) {
            try await $0.revokeAddress(
                address: "u@s.cabalmail.example", subdomain: "s", tld: "cabalmail.example", publicKey: nil
            )
        },
        ApiRow("suspend_address", .sentAgain) { try await $0.suspendAddress(address: "u@s.cabalmail.example") },
        ApiRow("reinstate_address", .sentAgain) { try await $0.reinstateAddress(address: "u@s.cabalmail.example") },
        ApiRow("set_favorite", .sentAgain) {
            try await $0.setFavorite(address: "u@s.cabalmail.example", favorite: true)
        },
        ApiRow("set_preferences", .sentAgain) { try await $0.updateDisplayName("Name") },
        ApiRow("set_preferences", .sentAgain) { try await $0.saveAppPreferences(["k": "v"]) },
        ApiRow("set_nav_state", .sentAgain) { try await $0.saveNavState(NavState(folder: "INBOX", clientID: "A")) },
        ApiRow("set_rules", .sentOnce) { _ = try await $0.setRules([], expectedVersion: 1) },
        ApiRow("push_register", .sentAgain) {
            try await $0.registerPushDevice(PushDeviceRegistration(
                deviceToken: "ab12", bundleId: "com.cabalmail.Cabalmail", appVersion: "1", locale: "en_US"
            ))
        },
        ApiRow("push_deregister", .sentAgain) { try await $0.deregisterPushDevice(token: "ab12") },
        // A read sent as a POST.
        ApiRow("push_envelope", .sentAgain) {
            _ = try await $0.fetchPushEnvelope(folder: "INBOX", uid: 1, messageID: nil)
        },
    ]

    private static let feedWrites: [ApiRow] = [
        ApiRow("rss_subscribe", .sentOnce) { _ = try await $0.subscribe(url: "https://x.example/feed", folderId: nil) },
        ApiRow("rss_unsubscribe", .sentOnce) { _ = try await $0.unsubscribe(subscriptionId: "s") },
        ApiRow("rss_update_subscription", .sentAgain) {
            _ = try await $0.updateSubscription("s", RssSubscriptionUpdate(customTitle: "t"))
        },
        ApiRow("rss_new_folder", .sentOnce) {
            _ = try await $0.newFolder(name: "n", parentFolderId: nil, displayOrder: nil)
        },
        ApiRow("rss_update_folder", .sentAgain) { _ = try await $0.updateFolder("f", RssFolderUpdate(name: "n")) },
        ApiRow("rss_delete_folder", .sentOnce) { _ = try await $0.deleteFolder("f") },
        ApiRow("rss_set_item_state", .sentAgain) {
            _ = try await $0.setItemState([RssItemStateChange(feedId: "f", sortKey: "k", isRead: true)])
        },
        ApiRow("rss_mark_all_read", .sentAgain) { _ = try await $0.markAllRead(scope: .all, watermark: nil) },
        ApiRow("rss_opml_import", .sentOnce) { _ = try await $0.importOpml("<opml/>", folderId: nil) },
    ]

    /// Every GET is sent again; these are the client's, one row each.
    private static let reads: [ApiRow] = [
        ApiRow("list", .sentAgain) { _ = try await $0.listAddresses() },
        ApiRow("list_my_domains", .sentAgain) { _ = try await $0.listMyDomains() },
        ApiRow("fetch_bimi", .sentAgain) { _ = try await $0.fetchBimiURL(senderDomain: "example.com") },
        ApiRow("list_folders", .sentAgain) { _ = try await $0.listFolders(host: "h") },
        ApiRow("folder_status", .sentAgain) {
            _ = try await $0.folderStatus(host: "h", folder: "INBOX", flagged: true)
        },
        ApiRow("list_messages", .sentAgain) {
            _ = try await $0.listMessageIds(host: "h", folder: "INBOX", sortOrder: "REVERSE", sortField: "DATE",
                                            page: nil)
        },
        ApiRow("list_envelopes", .sentAgain) { _ = try await $0.listEnvelopes(host: "h", folder: "INBOX", ids: [1]) },
        ApiRow("search_envelopes", .sentAgain) {
            _ = try await $0.searchEnvelopes(host: "h", query: SearchQuery(text: "x"))
        },
        ApiRow("fetch_message", .sentAgain) {
            _ = try await $0.fetchMessage(host: "h", folder: "INBOX", id: 1, markSeen: false)
        },
        ApiRow("list_attachments", .sentAgain) {
            _ = try await $0.listAttachments(host: "h", folder: "INBOX", id: 1, markSeen: false)
        },
        ApiRow("fetch_attachment", .sentAgain) {
            _ = try await $0.fetchAttachmentURL(FetchAttachmentRequest(
                host: "h", folder: "INBOX", id: 1, index: 0, filename: "a.pdf", markSeen: false
            ))
        },
        ApiRow("fetch_inline_image", .sentAgain) {
            _ = try await $0.fetchInlineImageURL(host: "h", folder: "INBOX", id: 1, contentId: "c", markSeen: false)
        },
        ApiRow("get_preferences", .sentAgain) { _ = try await $0.fetchAppPreferences() },
        ApiRow("get_nav_state", .sentAgain) { _ = try await $0.loadNavState() },
        ApiRow("get_rules", .sentAgain) { _ = try await $0.listRules() },
        ApiRow("rss_list_subscriptions", .sentAgain) { _ = try await $0.listSubscriptions() },
        ApiRow("rss_list_items", .sentAgain) {
            _ = try await $0.listItems(scope: .all, filter: .all, order: .newest, limit: 10, cursor: nil)
        },
        ApiRow("rss_get_item", .sentAgain) { _ = try await $0.getItem(feedId: "f", sortKey: "k") },
        ApiRow("rss_opml_export", .sentAgain) { _ = try await $0.exportOpml() },
    ]

    static let cognito: [CognitoRow] = [
        CognitoRow("InitiateAuth", .sentAgain) { _ = try await $0.signIn(username: "alice", password: "pw") },
        CognitoRow("InitiateAuth", .sentAgain, needsSession: true) {
            _ = try await $0.refreshIdToken(replacing: "id")
        },
        CognitoRow("RespondToAuthChallenge", .sentAgain, needsChallenge: true) { try await $0.submitMfaCode("123456") },
        CognitoRow("SignUp", .sentOnce) {
            try await $0.signUp(username: "alice", password: "pw", email: "a@b.example", phone: nil)
        },
        CognitoRow("ConfirmSignUp", .sentOnce) { try await $0.confirmSignUp(username: "alice", code: "123456") },
        CognitoRow("ResendConfirmationCode", .sentOnce) { try await $0.resendConfirmationCode(username: "alice") },
        CognitoRow("ForgotPassword", .sentOnce) { try await $0.forgotPassword(username: "alice") },
        CognitoRow("ConfirmForgotPassword", .sentOnce) {
            try await $0.confirmForgotPassword(username: "alice", code: "123456", newPassword: "pw2")
        },
        CognitoRow("GetUser", .sentAgain, needsSession: true) { _ = try await $0.totpEnabled() },
        CognitoRow("AssociateSoftwareToken", .sentOnce, needsSession: true) {
            _ = try await $0.beginTotpEnrollment()
        },
        // Fails at VerifySoftwareToken, so SetUserMFAPreference is never sent.
        CognitoRow("VerifySoftwareToken", .sentOnce, needsSession: true) {
            try await $0.confirmTotpEnrollment(code: "123456")
        },
        CognitoRow("SetUserMFAPreference", .sentAgain, needsSession: true) { try await $0.disableTotp() },
    ]
}
