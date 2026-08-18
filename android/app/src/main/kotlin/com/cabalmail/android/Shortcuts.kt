package com.cabalmail.android

import android.view.KeyEvent
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

/**
 * Hardware-keyboard chords (plan §7.2), mirroring the Apple client's set
 * with Ctrl in place of Cmd. Ctrl chords are dispatched at the activity
 * level so they work whatever has focus; plain `j`/`k` stay in the message
 * list, which handles them itself only when it holds focus (a text field
 * must keep its letters).
 */
enum class Shortcut { COMPOSE, REPLY, REPLY_ALL, TOGGLE_READ, TOGGLE_FLAG }

class ShortcutBus {
    private val mutable = MutableSharedFlow<Shortcut>(extraBufferCapacity = 4)
    val events: SharedFlow<Shortcut> = mutable.asSharedFlow()

    /** Maps a framework key event to a chord; true when it was consumed. */
    fun dispatch(event: KeyEvent): Boolean {
        if (event.action != KeyEvent.ACTION_DOWN || event.repeatCount > 0) {
            return false
        }
        return dispatch(event.keyCode, ctrl = event.isCtrlPressed, shift = event.isShiftPressed)
    }

    /** Same mapping over raw key code + modifiers (Compose's `KeyEvent` path). */
    fun dispatch(
        keyCode: Int,
        ctrl: Boolean,
        shift: Boolean,
    ): Boolean {
        if (!ctrl) {
            return false
        }
        val shortcut =
            when (keyCode) {
                KeyEvent.KEYCODE_N -> if (shift) null else Shortcut.COMPOSE
                KeyEvent.KEYCODE_R -> if (shift) Shortcut.REPLY_ALL else Shortcut.REPLY
                KeyEvent.KEYCODE_U -> if (shift) Shortcut.TOGGLE_READ else null
                KeyEvent.KEYCODE_L -> if (shift) Shortcut.TOGGLE_FLAG else null
                else -> null
            } ?: return false
        return mutable.tryEmit(shortcut)
    }
}
