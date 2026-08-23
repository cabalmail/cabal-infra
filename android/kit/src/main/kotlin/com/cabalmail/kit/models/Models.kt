package com.cabalmail.kit.models

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive

// Wire models for the Lambda API, transcribed from the deployed contract
// (lambda/api/_shared/helper.py + the per-endpoint handlers; the React and
// Apple clients are the reference consumers). Kotlin types are defined
// fresh — only the JSON contract is shared.

/** SPF/DKIM/DMARC verdicts. Nullable on the envelope: absence ≠ pass. */
@Serializable
data class AuthResults(
    val spf: String? = null,
    val dkim: String? = null,
    val dmarc: String? = null,
)

/**
 * One message envelope. `/list_envelopes` returns these keyed by UID in a
 * map; `/search_envelopes` returns them in an array with [folder] set.
 *
 * Quirks preserved from the wire: [date] is a stringified Python datetime
 * (`"2024-01-15 10:30:45+00:00"`) and the literal string `"None"` when the
 * message has no date; there is no size field; attachment presence must be
 * derived from the BODYSTRUCTURE tree in [struct].
 */
@Serializable
data class Envelope(
    val id: Long,
    val date: String = "None",
    val subject: String = "",
    val from: List<String> = emptyList(),
    val to: List<String> = emptyList(),
    val cc: List<String> = emptyList(),
    val flags: List<String> = emptyList(),
    val struct: JsonElement? = null,
    val priority: List<String> = emptyList(),
    @SerialName("message_id") val messageId: List<String> = emptyList(),
    @SerialName("in_reply_to") val inReplyTo: List<String> = emptyList(),
    /** Angle-bracketed ids, capped server-side to the newest 20. */
    val references: List<String> = emptyList(),
    @SerialName("auth_results") val authResults: AuthResults? = null,
    /** Source folder; set on search results only. */
    val folder: String? = null,
) {
    val isSeen: Boolean get() = flags.any { it.equals("\\Seen", ignoreCase = true) }

    val isFlagged: Boolean get() = flags.any { it.equals("\\Flagged", ignoreCase = true) }

    /** `priority-1` / `priority-2` mean high priority. */
    val isHighPriority: Boolean get() = priority.any { it == "priority-1" || it == "priority-2" }

    /**
     * Walks the BODYSTRUCTURE tree for an attachment marker — a leaf string
     * equal (case-insensitively) to `attachment` or `application`, the same
     * heuristic the React and Apple clients use.
     */
    val hasAttachments: Boolean get() = struct?.let(::containsAttachmentMarker) ?: false

    private fun containsAttachmentMarker(node: JsonElement): Boolean =
        when (node) {
            is JsonArray -> node.any(::containsAttachmentMarker)
            is JsonPrimitive ->
                node.isString &&
                    (
                        node.content.equals("attachment", ignoreCase = true) ||
                            node.content.equals("application", ignoreCase = true)
                    )
            else -> false
        }
}

/** `/list_folders` (and folder-mutation) response: flat `/`-delimited paths. */
@Serializable
data class FolderList(
    val folders: List<String> = emptyList(),
    @SerialName("sub_folders") val subscribedFolders: List<String> = emptyList(),
)

/** `/folder_status`. `flagged` is present only when requested. */
@Serializable
data class FolderStatus(
    val messages: Int? = null,
    val unseen: Int? = null,
    @SerialName("uid_validity") val uidValidity: Long? = null,
    @SerialName("uid_next") val uidNext: Long? = null,
    val flagged: Int? = null,
)

@Serializable
data class Address(
    val address: String,
    val subdomain: String = "",
    val tld: String = "",
    val username: String = "",
    /** Slash-joined assignee list; multi-user addresses have several. */
    val user: String = "",
    val comment: String = "",
    val favorite: Boolean = false,
    val suspended: Boolean = false,
)

@Serializable
data class AddressList(
    @SerialName("Items") val items: List<Address> = emptyList(),
)

/** One `/list_attachments` descriptor. [id] is the MIME-walk index. */
@Serializable
data class Attachment(
    val name: String? = null,
    val type: String = "",
    val size: Long = 0,
    val id: Int,
)

@Serializable
data class AttachmentList(
    val attachments: List<Attachment> = emptyList(),
)

/**
 * `/fetch_message`. The three threading fields here are RAW header values
 * (nullable, possibly several space-separated ids in one string), unlike the
 * pre-split envelope fields.
 */
@Serializable
data class MessageContent(
    @SerialName("message_raw") val messageRawUrl: String = "",
    @SerialName("message_body_plain") val bodyPlain: String = "",
    @SerialName("message_body_html") val bodyHtml: String = "",
    val recipient: String = "",
    @SerialName("message_id") val messageId: List<String>? = null,
    @SerialName("in_reply_to") val inReplyTo: List<String>? = null,
    val references: List<String>? = null,
)

@Serializable
data class MessagePage(
    @SerialName("message_ids") val messageIds: List<Long> = emptyList(),
    val total: Int = 0,
)

@Serializable
data class SearchResult(
    val envelopes: List<Envelope> = emptyList(),
    @SerialName("total_estimate") val totalEstimate: Int = 0,
    /** Opaque; pass back verbatim. Null on the last page. */
    @SerialName("next_cursor") val nextCursor: String? = null,
    @SerialName("folders_searched") val foldersSearched: List<String> = emptyList(),
    val truncated: Boolean = false,
)

/** Structured predicates for `/search_envelopes`. All optional. */
data class SearchFilters(
    val from: String? = null,
    val to: String? = null,
    val subject: String? = null,
    /** Day-granular, `YYYY-MM-DD`. */
    val since: String? = null,
    val before: String? = null,
    val unread: Boolean = false,
    val flagged: Boolean = false,
    val hasAttachment: Boolean = false,
)

/**
 * Bulk-operation outcome (`/set_flag`, `/move_messages`). `partial` arrives
 * as HTTP 200 — anything other than an explicit `partial` status means the
 * whole requested set succeeded.
 */
@Serializable
data class BulkResult(
    val status: String = "submitted",
    @SerialName("flagged_ids") val flaggedIds: List<Long>? = null,
    @SerialName("moved_ids") val movedIds: List<Long>? = null,
    @SerialName("failed_ids") val failedIds: List<Long>? = null,
) {
    val isPartial: Boolean get() = status == "partial"
}

/** Shared compose fields for `/send` and `/save_draft`. */
@Serializable
data class ComposeFields(
    val sender: String,
    @SerialName("to_list") val toList: List<String> = emptyList(),
    @SerialName("cc_list") val ccList: List<String> = emptyList(),
    @SerialName("bcc_list") val bccList: List<String> = emptyList(),
    val subject: String = "",
    val text: String = "",
    val html: String = "",
    @SerialName("other_headers") val otherHeaders: OtherHeaders = OtherHeaders(),
    val attachments: List<OutgoingAttachment> = emptyList(),
)

@Serializable
data class OtherHeaders(
    @SerialName("message_id") val messageId: List<String>? = null,
    @SerialName("in_reply_to") val inReplyTo: List<String>? = null,
    val references: List<String>? = null,
)

/** Pre-uploaded S3 attachment reference (`/upload_url` flow). */
@Serializable
data class OutgoingAttachment(
    val filename: String,
    @SerialName("mime_type") val mimeType: String,
    @SerialName("s3_key") val s3Key: String,
)

/** One `/upload_url` grant: PUT the bytes to [url], then reference [key]. */
@Serializable
data class UploadGrant(
    val key: String,
    val url: String,
    @SerialName("expires_in") val expiresIn: Int = 0,
)

@Serializable
data class UploadGrantList(
    val uploads: List<UploadGrant> = emptyList(),
)

/** `/list_my_domains`: the mail apexes the caller may mint addresses on. */
@Serializable
data class MyDomains(
    @SerialName("Domains") val domains: List<String> = emptyList(),
)

/** `/send` outcome. */
sealed interface SendOutcome {
    /** Delivered ([duplicate] = an earlier identical submission won). */
    data class Submitted(
        val duplicate: Boolean,
    ) : SendOutcome

    /**
     * An earlier submission is still in flight (HTTP 409) — keep the
     * message and retry later; it is NOT sent.
     */
    data object DuplicateInFlight : SendOutcome
}

/** `/save_draft` save outcome; UIDPLUS coordinates are nullable. */
@Serializable
data class SaveDraftResult(
    val status: String = "",
    val uid: Long? = null,
    val uidvalidity: Long? = null,
    val replaced: Boolean = false,
    val discarded: Boolean = false,
)

/** Server-synced preferences; [app] is the native clients' string map. */
@Serializable
data class Preferences(
    val theme: String = "light",
    val accent: String = "forest",
    val density: String = "compact",
    val name: String = "",
    val app: Map<String, String> = emptyMap(),
)

/**
 * Partial preferences update — only non-null fields go on the wire, and the
 * server merges per key (per member key inside [app]).
 */
@Serializable
data class PreferencesUpdate(
    val theme: String? = null,
    val accent: String? = null,
    val density: String? = null,
    val name: String? = null,
    val app: Map<String, String>? = null,
)

/** Cross-device resume cursor. `updated_at` is server-stamped epoch millis. */
@Serializable
data class NavState(
    val folder: String? = null,
    @SerialName("client_id") val clientId: String? = null,
    @SerialName("updated_at") val updatedAt: Long? = null,
    @SerialName("message_id") val messageId: String? = null,
    @SerialName("msg_anchor") val msgAnchor: String? = null,
    val uid: Long? = null,
    @SerialName("uid_validity") val uidValidity: Long? = null,
    @SerialName("list_scroll") val listScroll: Long? = null,
    @SerialName("msg_scroll") val msgScroll: Long? = null,
)

/**
 * `/push_envelope` enrichment for a content-free wake signal: the sender
 * (raw RFC 5322 From header), subject, plain-text snippet, and the resolved
 * UID (authoritative when the signal carried only a Message-ID).
 */
@Serializable
data class PushEnvelope(
    val from: String = "",
    val subject: String = "",
    val snippet: String = "",
    val uid: Long = 0,
)
