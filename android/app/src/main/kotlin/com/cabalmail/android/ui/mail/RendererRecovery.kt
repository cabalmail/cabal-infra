package com.cabalmail.android.ui.mail

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * What a WebView host does when Android ends the view's render process,
 * because the system reclaimed its memory or because it crashed. The
 * WebView that lost its renderer can't be used again, and a
 * `WebViewClient` that leaves `onRenderProcessGone` unclaimed takes the
 * whole app down with it.
 *
 * The host claims the event through [onRenderProcessGone] and keys its
 * `AndroidView` on [generation], so a bump releases (and destroys) the
 * dead view and mounts a fresh one that loads the document again. A
 * reclaimed renderer is always remounted. A crashed one is remounted once
 * per document; the next crash sets [gaveUp], the host shows a notice in
 * place of the view, and [retry] is the reader asking again. A page that
 * crashes its renderer every time it loads therefore can't spin the view.
 *
 * Remember one per document: `remember(document) { RendererRecovery() }`.
 */
@Stable
class RendererRecovery {
    /** Bumped for each fresh WebView; the host's `key` for its `AndroidView`. */
    var generation by mutableIntStateOf(0)
        private set

    /** The renderer crashed again after the silent remount: show the notice, not the view. */
    var gaveUp by mutableStateOf(false)
        private set

    private var remountedAfterCrash = false

    /**
     * Call from `WebViewClient.onRenderProcessGone` with the detail's
     * `didCrash()`. The event is always claimed, so this returns true.
     */
    fun onRenderProcessGone(didCrash: Boolean): Boolean {
        if (didCrash && remountedAfterCrash) {
            gaveUp = true
        } else {
            if (didCrash) remountedAfterCrash = true
            generation += 1
        }
        return true
    }

    /** The notice's Retry: a fresh WebView for the same document. */
    fun retry() {
        if (!gaveUp) return
        gaveUp = false
        generation += 1
    }
}
