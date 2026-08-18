package com.cabalmail.android.ui.compose

import com.cabalmail.android.AppContainer
import com.cabalmail.kit.compose.SignatureFormatter
import com.cabalmail.kit.models.ComposeIntent
import com.cabalmail.kit.models.Draft
import java.util.UUID

/**
 * Every way into the compose screen goes through the local draft buffer:
 * the caller persists a seed [Draft] and navigates to `compose/{id}`, and
 * [ComposeViewModel] loads it back. That keeps the route argument a plain
 * id (no serialized seed in the back stack) and means a seed survives
 * process death before the screen even opens.
 */
object ComposeLaunch {
    /** Persists [draft] and returns the id to navigate with. */
    suspend fun stage(
        container: AppContainer,
        draft: Draft,
    ): String {
        container.draftStore.save(draft)
        return draft.id
    }

    /**
     * A blank draft for the "new message" FAB, seeded from preferences
     * (plan §6.3): the default From address, if any, and the signature.
     */
    fun blank(container: AppContainer): Draft {
        val prefs = container.preferences.preferences.value
        val body = SignatureFormatter.seedBody("", prefs.signature)
        return Draft(
            id = UUID.randomUUID().toString(),
            updatedAt = System.currentTimeMillis(),
            fromAddress = prefs.defaultFromAddress,
            body = body,
            seedBody = body,
        )
    }

    /**
     * Seeds a draft from shared content: text becomes the body, the
     * subject extra the subject, and every stream URI an attachment
     * copied into the draft directory while the URI grant is still live.
     */
    suspend fun fromShare(
        container: AppContainer,
        content: SharedContent,
    ): Draft {
        val id = UUID.randomUUID().toString()
        val importer = AttachmentImporter(container.applicationContext, container.draftStore)
        val attachments = content.uris.mapNotNull { uri -> importer.import(id, uri) }
        val prefs = container.preferences.preferences.value
        // Shared text is user content, so only the signature scaffold is
        // the seed: a share the user backs out of is still worth keeping.
        return Draft(
            id = id,
            updatedAt = System.currentTimeMillis(),
            fromAddress = prefs.defaultFromAddress,
            subject = content.subject.orEmpty(),
            body = SignatureFormatter.seedBody(content.text.orEmpty(), prefs.signature),
            seedBody = SignatureFormatter.seedBody("", prefs.signature),
            composeIntent = ComposeIntent.NEW,
            attachments = attachments,
        )
    }
}
