package com.cabalmail.android.ui.settings

import com.cabalmail.kit.settings.ServerTextRules

/**
 * The state of the name field in the flag editor. The field writes each
 * name as it is typed, and the server refuses a flag with an empty name
 * together with every other setting sent beside it (#2453), so an emptied
 * field writes nothing: the flag keeps the last name the field wrote, and
 * leaving the editor with the field still empty puts back the name it
 * opened with. The Kotlin sibling of the Apple app's `FlagNameField`.
 *
 * [text] is what the field shows. [giveBack] is the name to put back when
 * the editor is left with the field empty. [lastWritten] is the name the
 * field's own last write left on the flag, which tells that write apart
 * from a name that came by another route ([seeing]).
 */
internal data class FlagNameField(
    val text: String,
    val giveBack: String,
    val lastWritten: String,
) {
    /**
     * The user typed [value]: the field's new state, and the name to
     * write to the flag, or null to write nothing. The name is held to
     * what the server takes ([ServerTextRules.flagLabel]), and one that
     * comes out empty is not written.
     */
    fun typed(value: String): Pair<FlagNameField, String?> {
        val accepted = ServerTextRules.flagLabel(value)
        return if (accepted.isEmpty()) {
            copy(text = "") to null
        } else {
            copy(text = accepted, lastWritten = accepted) to accepted
        }
    }

    /**
     * The field given the flag's name as the list holds it now. A name
     * that is not the one this field last wrote came by another route,
     * Reset to default or a pull that brought a rename from another
     * device, and is the newer one: the field shows it, and it becomes
     * the name to give back.
     */
    fun seeing(label: String): FlagNameField = if (label == lastWritten) this else opening(label)

    /**
     * The editor is being left: the name to write back to the flag, or
     * null when the flag already holds the right one.
     */
    fun leaving(): String? = if (text.isEmpty() && lastWritten != giveBack) giveBack else null

    companion object {
        /** The field as the editor opens on a flag named [label]. */
        fun opening(label: String) = FlagNameField(text = label, giveBack = label, lastWritten = label)
    }
}
