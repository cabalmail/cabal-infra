package com.cabalmail.kit.api

import com.cabalmail.kit.CabalmailException
import com.cabalmail.kit.auth.AuthService
import com.cabalmail.kit.models.Address
import com.cabalmail.kit.models.AddressList
import com.cabalmail.kit.models.Attachment
import com.cabalmail.kit.models.AttachmentList
import com.cabalmail.kit.models.BulkResult
import com.cabalmail.kit.models.ComposeFields
import com.cabalmail.kit.models.Envelope
import com.cabalmail.kit.models.FolderList
import com.cabalmail.kit.models.FolderStatus
import com.cabalmail.kit.models.MessageContent
import com.cabalmail.kit.models.MessagePage
import com.cabalmail.kit.models.MyDomains
import com.cabalmail.kit.models.NavState
import com.cabalmail.kit.models.Preferences
import com.cabalmail.kit.models.PreferencesUpdate
import com.cabalmail.kit.models.PushEnvelope
import com.cabalmail.kit.models.SaveDraftResult
import com.cabalmail.kit.models.SearchFilters
import com.cabalmail.kit.models.SearchResult
import com.cabalmail.kit.models.SendOutcome
import com.cabalmail.kit.models.UploadGrant
import com.cabalmail.kit.models.UploadGrantList
import io.ktor.client.HttpClient
import io.ktor.client.request.header
import io.ktor.client.request.put
import io.ktor.client.request.request
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.contentType
import io.ktor.http.encodedPath
import io.ktor.http.isSuccess
import io.ktor.http.takeFrom
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.add
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/**
 * The Lambda API surface — the Kotlin sibling of the Apple kit's
 * `URLSessionApiClient` and the React `ApiClient`.
 *
 * Wire conventions (see those clients and `lambda/api/_shared/helper.py`):
 * the `Authorization` header carries the raw Cognito ID token (no `Bearer`
 * prefix); folder paths travel in `/`-delimited display form; a 401 is
 * replayed once after a forced token refresh; success is any 2xx (`/new`
 * returns 201, `/revoke` 202).
 */
class ApiClient(
    baseUrl: String,
    /** The `host` value mail endpoints expect (`Config.imapHost`). */
    private val host: String,
    private val authService: AuthService,
    private val httpClient: HttpClient,
    /** Invoked when a request fails 401 even after a forced refresh. */
    private val onAuthExpired: (() -> Unit)? = null,
) {
    private val baseUrl = baseUrl.trimEnd('/')

    private val json = Json { ignoreUnknownKeys = true }

    // Request bodies: skip nulls (partial updates merge server-side), keep
    // defaults (compose requires empty lists to be present on the wire).
    private val bodyJson =
        Json {
            ignoreUnknownKeys = true
            encodeDefaults = true
            explicitNulls = false
        }

    // ----------------------------------------------------------------- core

    private suspend fun call(
        method: HttpMethod,
        path: String,
        query: Map<String, String> = emptyMap(),
        body: JsonObject? = null,
    ): String {
        var token = authService.currentIdToken()
        var response = execute(method, path, query, body, token)
        if (response.status == HttpStatusCode.Unauthorized) {
            // The server rejected a token the client believed fresh: refresh
            // once and replay. A second 401 is a real expiry.
            token = authService.forceRefreshedIdToken()
            response = execute(method, path, query, body, token)
            if (response.status == HttpStatusCode.Unauthorized) {
                onAuthExpired?.invoke()
                throw CabalmailException.AuthExpired()
            }
        }
        val text = response.bodyAsText()
        if (!response.status.isSuccess()) {
            throw mapError(response.status.value, text, response.headers["Retry-After"])
        }
        return text
    }

    private suspend fun execute(
        method: HttpMethod,
        path: String,
        query: Map<String, String>,
        body: JsonObject?,
        token: String,
    ): HttpResponse =
        httpClient.request {
            this.method = method
            url {
                takeFrom(baseUrl)
                encodedPath = "$encodedPath/${path.trimStart('/')}"
                query.forEach { (key, value) -> parameters.append(key, value) }
            }
            header("Authorization", token)
            if (body != null) {
                contentType(ContentType.Application.Json)
                setBody(body.toString())
            }
        }

    private fun mapError(
        status: Int,
        text: String,
        retryAfter: String?,
    ): CabalmailException {
        val obj = runCatching { json.parseToJsonElement(text).jsonObject }.getOrNull()
        val message =
            obj?.let {
                it.stringOrNull("status") ?: it.stringOrNull("Error") ?: it.stringOrNull("message")
            } ?: text
        if (status == 503 && obj?.stringOrNull("status") == "maintenance") {
            return CabalmailException.Maintenance(
                retryAfterSeconds = retryAfter?.toIntOrNull(),
                message = message,
            )
        }
        return CabalmailException.ApiError(httpStatus = status, message = message)
    }

    private fun JsonObject.stringOrNull(key: String): String? = this[key]?.jsonPrimitive?.contentOrNull

    private inline fun <reified T> decode(text: String): T =
        try {
            json.decodeFromString<T>(text)
        } catch (exception: Exception) {
            throw CabalmailException.DecodingError("Could not decode API response", exception)
        }

    // ------------------------------------------------------------ addresses

    suspend fun listAddresses(): List<Address> = decode<AddressList>(call(HttpMethod.Get, "list")).items

    /** Creates `username@subdomain.tld`; returns the derived address. */
    suspend fun newAddress(
        username: String,
        subdomain: String,
        tld: String,
        comment: String,
    ): String {
        val text =
            call(
                HttpMethod.Post,
                "new",
                body =
                    buildJsonObject {
                        put("username", username)
                        put("subdomain", subdomain)
                        put("tld", tld)
                        put("comment", comment)
                        put("address", "$username@$subdomain.$tld")
                    },
            )
        return json.parseToJsonElement(text).jsonObject.stringOrNull("address")
            ?: throw CabalmailException.DecodingError("Missing address in response")
    }

    suspend fun setFavorite(
        address: String,
        favorite: Boolean,
    ) {
        call(
            HttpMethod.Put,
            "set_favorite",
            body =
                buildJsonObject {
                    put("address", address)
                    put("favorite", favorite)
                },
        )
    }

    suspend fun revokeAddress(address: String) {
        call(HttpMethod.Delete, "revoke", body = buildJsonObject { put("address", address) })
    }

    /**
     * Mail apexes the caller is entitled to mint addresses on (the `/new`
     * Lambda rejects the rest). Intersect with `Config.mailDomains` for
     * the picker.
     */
    suspend fun listMyDomains(): List<String> = decode<MyDomains>(call(HttpMethod.Get, "list_my_domains")).domains

    /** BIMI logo URL for a sender domain, or null when there is none. */
    suspend fun fetchBimi(senderDomain: String): String? {
        val text = call(HttpMethod.Get, "fetch_bimi", query = mapOf("sender_domain" to senderDomain))
        return json.parseToJsonElement(text).jsonObject.stringOrNull("url")
    }

    // -------------------------------------------------------------- folders

    suspend fun listFolders(): FolderList = decode(call(HttpMethod.Get, "list_folders", query = mapOf("host" to host)))

    suspend fun folderStatus(
        folder: String,
        includeFlagged: Boolean = false,
    ): FolderStatus {
        val query = mutableMapOf("host" to host, "folder" to folder)
        if (includeFlagged) {
            query["flagged"] = "1"
        }
        return decode(call(HttpMethod.Get, "folder_status", query = query))
    }

    suspend fun newFolder(
        name: String,
        parent: String = "",
    ): FolderList =
        decode(
            call(
                HttpMethod.Put,
                "new_folder",
                body =
                    buildJsonObject {
                        put("host", host)
                        put("name", name)
                        put("parent", parent)
                    },
            ),
        )

    suspend fun deleteFolder(name: String): FolderList =
        decode(
            call(
                HttpMethod.Delete,
                "delete_folder",
                body =
                    buildJsonObject {
                        put("host", host)
                        put("name", name)
                    },
            ),
        )

    suspend fun subscribeFolder(folder: String) {
        call(
            HttpMethod.Put,
            "subscribe_folder",
            body =
                buildJsonObject {
                    put("host", host)
                    put("folder", folder)
                },
        )
    }

    suspend fun unsubscribeFolder(folder: String) {
        call(
            HttpMethod.Put,
            "unsubscribe_folder",
            body =
                buildJsonObject {
                    put("host", host)
                    put("folder", folder)
                },
        )
    }

    // ------------------------------------------------------------- messages

    /**
     * UIDs in [folder], sorted server-side. [descending] maps to the wire's
     * `"REVERSE "` sort order; [sortField] is one of the IMAP SORT keys
     * (ARRIVAL, CC, DATE, FROM, SIZE, SUBJECT, TO).
     */
    suspend fun listMessages(
        folder: String,
        sortField: String = "ARRIVAL",
        descending: Boolean = true,
        offset: Int? = null,
        limit: Int? = null,
    ): MessagePage {
        val query =
            mutableMapOf(
                "host" to host,
                "folder" to folder,
                "sort_order" to if (descending) "REVERSE " else "",
                "sort_field" to sortField,
            )
        offset?.let { query["offset"] = it.toString() }
        limit?.let { query["limit"] = it.toString() }
        return decode(call(HttpMethod.Get, "list_messages", query = query))
    }

    /** Envelopes keyed by UID. The `ids` wire format is a JSON-array string. */
    suspend fun listEnvelopes(
        folder: String,
        ids: List<Long>,
    ): Map<Long, Envelope> {
        if (ids.isEmpty()) {
            return emptyMap()
        }
        val text =
            call(
                HttpMethod.Get,
                "list_envelopes",
                query =
                    mapOf(
                        "host" to host,
                        "folder" to folder,
                        "ids" to ids.joinToString(",", prefix = "[", postfix = "]"),
                    ),
            )
        val map = json.parseToJsonElement(text).jsonObject["envelopes"]?.jsonObject ?: JsonObject(emptyMap())
        return map.entries.associate { (uid, element) ->
            uid.toLong() to json.decodeFromJsonElement(Envelope.serializer(), element)
        }
    }

    /**
     * Structured search. Null [folder] searches the subscribed folders
     * (excluding Trash) newest-first; [cursor] is the opaque page cursor
     * from the previous result.
     */
    suspend fun searchEnvelopes(
        text: String? = null,
        filters: SearchFilters = SearchFilters(),
        folder: String? = null,
        limit: Int? = null,
        cursor: String? = null,
    ): SearchResult {
        val query = mutableMapOf("host" to host)
        folder?.let { query["folder"] = it }
        text?.takeIf { it.isNotBlank() }?.let { query["text"] = it }
        filters.from?.let { query["from"] = it }
        filters.to?.let { query["to"] = it }
        filters.subject?.let { query["subject"] = it }
        filters.since?.let { query["since"] = it }
        filters.before?.let { query["before"] = it }
        if (filters.unread) {
            query["unread"] = "1"
        }
        if (filters.flagged) {
            query["flagged"] = "1"
        }
        if (filters.hasAttachment) {
            query["has_attachment"] = "1"
        }
        limit?.let { query["limit"] = it.toString() }
        cursor?.let { query["cursor"] = it }
        return decode(call(HttpMethod.Get, "search_envelopes", query = query))
    }

    suspend fun fetchMessage(
        folder: String,
        uid: Long,
    ): MessageContent =
        decode(
            call(
                HttpMethod.Get,
                "fetch_message",
                query = mapOf("host" to host, "folder" to folder, "id" to uid.toString()),
            ),
        )

    suspend fun listAttachments(
        folder: String,
        uid: Long,
    ): List<Attachment> =
        decode<AttachmentList>(
            call(
                HttpMethod.Get,
                "list_attachments",
                query = mapOf("host" to host, "folder" to folder, "id" to uid.toString()),
            ),
        ).attachments

    /** Presigned S3 URL for an attachment; fetch it with NO auth header. */
    suspend fun fetchAttachmentUrl(
        folder: String,
        uid: Long,
        index: Int,
        filename: String,
    ): String =
        urlOf(
            call(
                HttpMethod.Get,
                "fetch_attachment",
                query =
                    mapOf(
                        "host" to host,
                        "folder" to folder,
                        "id" to uid.toString(),
                        "index" to index.toString(),
                        "filename" to filename,
                    ),
            ),
        )

    /** Presigned URL for an inline image by Content-ID. */
    suspend fun fetchInlineImageUrl(
        folder: String,
        uid: Long,
        contentId: String,
    ): String {
        val bracketed = if (contentId.startsWith("<")) contentId else "<$contentId>"
        return urlOf(
            call(
                HttpMethod.Get,
                "fetch_inline_image",
                query =
                    mapOf(
                        "host" to host,
                        "folder" to folder,
                        "id" to uid.toString(),
                        "index" to bracketed,
                    ),
            ),
        )
    }

    private fun urlOf(text: String): String {
        val url =
            json.parseToJsonElement(text).jsonObject.stringOrNull("url")
                ?: throw CabalmailException.DecodingError("Missing url in response")
        // The Lambda degrades a signing failure to the literal "Error".
        if (!url.startsWith("http")) {
            throw CabalmailException.ApiError(httpStatus = 200, message = "Could not sign URL")
        }
        return url
    }

    // ------------------------------------------------------------ mutations

    /** Sets ([set] = true) or clears one IMAP flag on [ids]. */
    suspend fun setFlag(
        folder: String,
        ids: List<Long>,
        flag: String,
        set: Boolean,
    ): BulkResult =
        decode(
            call(
                HttpMethod.Put,
                "set_flag",
                body =
                    buildJsonObject {
                        put("host", host)
                        put("folder", folder)
                        putIds(ids)
                        put("flag", flag)
                        put("op", if (set) "set" else "unset")
                    },
            ),
        )

    suspend fun moveMessages(
        source: String,
        destination: String,
        ids: List<Long>,
        markSeen: Boolean? = null,
    ): BulkResult =
        decode(
            call(
                HttpMethod.Put,
                "move_messages",
                body =
                    buildJsonObject {
                        put("host", host)
                        put("source", source)
                        put("destination", destination)
                        putIds(ids)
                        markSeen?.let { put("mark_seen", it) }
                    },
            ),
        )

    /** Permanent expunge; the server accepts only the `Trash` folder. */
    suspend fun purgeMessages(
        folder: String,
        ids: List<Long>,
    ) {
        call(
            HttpMethod.Delete,
            "purge_messages",
            body =
                buildJsonObject {
                    put("host", host)
                    put("folder", folder)
                    putIds(ids)
                },
        )
    }

    suspend fun emptyTrash(folder: String) {
        call(
            HttpMethod.Delete,
            "empty_trash",
            body =
                buildJsonObject {
                    put("host", host)
                    put("folder", folder)
                },
        )
    }

    private fun kotlinx.serialization.json.JsonObjectBuilder.putIds(ids: List<Long>) {
        put("ids", bodyJson.encodeToJsonElement(ids))
    }

    // -------------------------------------------------------------- compose

    /**
     * Sends [fields]. When re-sending a synced draft, [discardDraftUid] /
     * [discardDraftUidValidity] name the Drafts copy `/send` should expunge
     * after delivery. HTTP 409 (an earlier submission still in flight) maps
     * to [SendOutcome.DuplicateInFlight] — keep the message and retry.
     */
    suspend fun send(
        fields: ComposeFields,
        discardDraftUid: Long? = null,
        discardDraftUidValidity: Long? = null,
    ): SendOutcome {
        val body =
            JsonObject(
                bodyJson.encodeToJsonElement(fields).jsonObject +
                    buildJsonObject {
                        put("host", host)
                        discardDraftUid?.let { put("discard_draft_uid", it) }
                        discardDraftUidValidity?.let { put("discard_draft_uidvalidity", it) }
                    },
            )
        val text =
            try {
                call(HttpMethod.Put, "send", body = body)
            } catch (exception: CabalmailException.ApiError) {
                if (exception.httpStatus == 409) {
                    return SendOutcome.DuplicateInFlight
                }
                throw exception
            }
        val duplicate =
            json
                .parseToJsonElement(text)
                .jsonObject["duplicate"]
                ?.jsonPrimitive
                ?.boolean ?: false
        return SendOutcome.Submitted(duplicate = duplicate)
    }

    /**
     * Saves (or with [discard] = true, discards) the server Drafts copy.
     * [replacesUid] / [replacesUidValidity] are the UIDPLUS coordinates of
     * the prior save, passed both-or-neither.
     */
    suspend fun saveDraft(
        fields: ComposeFields,
        replacesUid: Long? = null,
        replacesUidValidity: Long? = null,
        discard: Boolean = false,
    ): SaveDraftResult {
        val body =
            JsonObject(
                bodyJson.encodeToJsonElement(fields).jsonObject +
                    buildJsonObject {
                        put("host", host)
                        put("op", if (discard) "discard" else "save")
                        replacesUid?.let { put("replaces_uid", it) }
                        replacesUidValidity?.let { put("replaces_uidvalidity", it) }
                    },
            )
        return decode(call(HttpMethod.Put, "save_draft", body = body))
    }

    // ---------------------------------------------------------- attachments

    /**
     * Presigned S3 PUT grants for outbound attachments, one per file in
     * order. API Gateway caps a proxy request at 10 MB, so attachment
     * bytes bypass `/send` entirely: PUT each file to its grant URL, then
     * reference the returned key in `ComposeFields.attachments`. Grants
     * expire in about two minutes — upload promptly.
     */
    suspend fun requestUploadUrls(files: List<Pair<String, String>>): List<UploadGrant> {
        if (files.isEmpty()) {
            return emptyList()
        }
        val body =
            buildJsonObject {
                put("host", host)
                put(
                    "files",
                    buildJsonArray {
                        files.forEach { (filename, mimeType) ->
                            add(
                                buildJsonObject {
                                    put("filename", filename)
                                    put("mime_type", mimeType)
                                },
                            )
                        }
                    },
                )
            }
        return decode<UploadGrantList>(call(HttpMethod.Put, "upload_url", body = body)).uploads
    }

    /**
     * PUTs [bytes] to a presigned grant URL. No Authorization header — the
     * URL carries its own signature — and the exact Content-Type the grant
     * was requested with.
     */
    suspend fun uploadToGrant(
        url: String,
        mimeType: String,
        bytes: ByteArray,
    ) {
        val response =
            httpClient.put(url) {
                contentType(ContentType.parse(mimeType.ifBlank { "application/octet-stream" }))
                setBody(bytes)
            }
        if (!response.status.isSuccess()) {
            throw CabalmailException.ApiError(
                httpStatus = response.status.value,
                message = "Attachment upload failed (${response.status.value})",
            )
        }
    }

    // ------------------------------------------- preferences and nav state

    suspend fun getPreferences(): Preferences = decode(call(HttpMethod.Get, "get_preferences"))

    /** Sends only the non-null fields; the server merges per key. */
    suspend fun setPreferences(update: PreferencesUpdate) {
        call(HttpMethod.Put, "set_preferences", body = bodyJson.encodeToJsonElement(update).jsonObject)
    }

    /** The stored resume cursor, or null when none has been saved. */
    suspend fun getNavState(): NavState? {
        val state = decode<NavState>(call(HttpMethod.Get, "get_nav_state"))
        return state.takeIf { it.folder != null }
    }

    /** Replaces the stored cursor; `updated_at` is stamped server-side. */
    suspend fun setNavState(state: NavState): NavState {
        val body =
            JsonObject(
                bodyJson.encodeToJsonElement(state.copy(updatedAt = null)).jsonObject,
            )
        return decode(call(HttpMethod.Put, "set_nav_state", body = body))
    }

    // ----------------------------------------------------------------- push

    /**
     * Registers (upserts) this device's FCM registration token for the
     * signed-in user. Idempotent — call it on every launch and again on
     * token rotation. [deviceToken] is case-significant: never normalize
     * it.
     *
     * [enabledFolders] is the per-device folder opt-in, wire semantics
     * verbatim: null omits the key (the server preserves the row's
     * existing selection), an empty list resets to the INBOX-only
     * default, `["*"]` means every folder, anything else is exact
     * membership.
     */
    suspend fun pushRegister(
        deviceToken: String,
        bundleId: String,
        appVersion: String,
        locale: String,
        enabledFolders: List<String>? = null,
    ) {
        call(
            HttpMethod.Post,
            "push_register",
            body =
                buildJsonObject {
                    put("device_token", deviceToken)
                    put("bundle_id", bundleId)
                    put("platform", "android")
                    put("app_version", appVersion)
                    put("locale", locale)
                    enabledFolders?.let { folders ->
                        put("enabled_folders", buildJsonArray { folders.forEach { add(it) } })
                    }
                },
        )
    }

    /**
     * Removes this device's token row (sign-out, or notifications turned
     * off). The dispatcher also prunes rows the push service rejects, so
     * this is the polite path, not the only one.
     */
    suspend fun pushDeregister(deviceToken: String) {
        call(
            HttpMethod.Post,
            "push_deregister",
            body = buildJsonObject { put("device_token", deviceToken) },
        )
    }

    /**
     * Enriches a content-free wake signal with sender/subject/snippet.
     * [msgId] is authoritative when present; [uid] is a best-effort hint
     * (procmail enqueues before Dovecot assigns the UID). 404 = the
     * message is gone; 503 = a planned IMAP roll — callers degrade to the
     * generic alert either way.
     */
    suspend fun pushEnvelope(
        folder: String,
        uid: Long?,
        msgId: String?,
    ): PushEnvelope =
        decode(
            call(
                HttpMethod.Post,
                "push_envelope",
                body =
                    buildJsonObject {
                        put("folder", folder)
                        uid?.takeIf { it > 0 }?.let { put("uid", it) }
                        msgId?.takeIf { it.isNotBlank() }?.let { put("msg_id", it) }
                    },
            ),
        )
}
