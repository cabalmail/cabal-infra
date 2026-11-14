package com.cabalmail.android.ui.settings

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test

/**
 * The flag editor's name field (#2453): the server refuses a flag with an
 * empty name, and with it every other setting in the same request, so the
 * field never writes one. Before, the field wrote whatever it held, cut
 * with `take(32)`, and an emptied field stored an empty name.
 */
class FlagNameFieldTest {
    private fun type(
        field: FlagNameField,
        vararg values: String,
    ): Pair<FlagNameField, List<String?>> {
        var state = field
        val written = mutableListOf<String?>()
        for (value in values) {
            val (next, name) = state.typed(value)
            state = next
            written += name
        }
        return state to written
    }

    @Test
    fun `a typed name is written as it is typed`() {
        val (field, written) = type(FlagNameField.opening("Later"), "Late", "Lat", "Lati", "Latin")
        assertEquals(listOf<String?>("Late", "Lat", "Lati", "Latin"), written)
        assertEquals("Latin", field.text)
        assertNull(field.leaving())
    }

    @Test
    fun `an emptied field writes nothing, and leaving puts back the name it opened with`() {
        // Deleted one letter at a time: the flag holds the stub "L" while
        // the field is empty, and leaving gives "Later" back.
        val (field, written) = type(FlagNameField.opening("Later"), "Late", "La", "L", "")
        assertEquals(listOf<String?>("Late", "La", "L", null), written)
        assertEquals("", field.text)
        assertEquals("Later", field.leaving())
    }

    @Test
    fun `a field cleared in one stroke has nothing to put back`() {
        // Nothing was written, so the flag still holds the opening name.
        val (field, written) = type(FlagNameField.opening("Later"), "")
        assertEquals(listOf<String?>(null), written)
        assertNull(field.leaving())
    }

    @Test
    fun `typing again after emptying the field writes again`() {
        val (field, written) = type(FlagNameField.opening("Later"), "", "S", "So")
        assertEquals(listOf<String?>(null, "S", "So"), written)
        assertNull(field.leaving())
        assertEquals("So", field.text)
    }

    @Test
    fun `text that is nothing but control characters is an empty name`() {
        val (field, written) = type(FlagNameField.opening("Later"), "\u0007\n")
        assertEquals(listOf<String?>(null), written)
        assertEquals("", field.text)
    }

    @Test
    fun `a name is cut to what the server takes before it is written`() {
        // Twenty thumbs-up with a skin tone: one character each, two code
        // points each. The server takes 32 code points, which is sixteen.
        val thumbsUp = "👍🏽"
        val (field, written) = type(FlagNameField.opening("Later"), thumbsUp.repeat(20))
        assertEquals(listOf<String?>(thumbsUp.repeat(16)), written)
        assertEquals(thumbsUp.repeat(16), field.text)
    }

    @Test
    fun `a name that came by another route is shown and becomes the name to give back`() {
        // Reset to default, or a pull that brings a rename from another
        // device, while the field is empty.
        val (emptied, _) = type(FlagNameField.opening("Later"), "L", "")
        val renamed = emptied.seeing("Renamed elsewhere")
        assertEquals("Renamed elsewhere", renamed.text)
        assertNull(renamed.leaving(), "leaving writes nothing older over it")
        val (again, _) = type(renamed, "R", "")
        assertEquals("Renamed elsewhere", again.leaving())
    }

    @Test
    fun `the flag's name after this field's own write is not another route's`() {
        // The list hands back the name the field just wrote: the field
        // stays as the user left it, empty included.
        val (typed, _) = type(FlagNameField.opening("Later"), "L")
        assertEquals(typed, typed.seeing("L"))
        val (emptied, _) = type(typed, "")
        assertEquals("", emptied.seeing("L").text)
        assertEquals("Later", emptied.seeing("L").leaving())
    }
}
