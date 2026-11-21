package com.cabalmail.android.ui.rules

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * [RuleListEdits] over a rule of its own, so the rules both lists hold to
 * are tested once and apart from either kind of rule. Null is "nothing
 * changed", which is what keeps a no-op from scheduling a save.
 */
class RuleListEditsTest {
    private data class Item(
        val id: String,
        val name: String = id,
        val locked: Boolean = false,
    )

    private val edits =
        RuleListEdits<Item>(
            maxCount = 4,
            id = { it.id },
            isEditable = { !it.locked },
            copyOf = { it.copy(id = it.id + "'", name = it.name + " copy") },
        )

    private val a = Item("a")
    private val b = Item("b")
    private val c = Item("c")
    private val locked = Item("x", locked = true)

    @Test
    fun `update writes a changed rule back in place`() {
        assertEquals(listOf(a, b.copy(name = "B"), c), edits.update(listOf(a, b, c), b.copy(name = "B")))
    }

    @Test
    fun `update is nothing for an equal rule, a missing one, or a locked one`() {
        assertNull(edits.update(listOf(a, b), b))
        assertNull(edits.update(listOf(a, b), c))
        assertNull(edits.update(listOf(a, locked), locked.copy(name = "rewritten")))
    }

    @Test
    fun `add appends up to the cap`() {
        assertEquals(listOf(a, b), edits.add(listOf(a), b))
        assertNull(edits.add(listOf(a, b, c, locked), Item("d")))
        assertFalse(edits.isFull(listOf(a, b, c)))
        assertTrue(edits.isFull(listOf(a, b, c, locked)))
    }

    @Test
    fun `duplicate places the copy after its original and answers its id`() {
        val (rules, id) = edits.duplicate(listOf(a, b, c), "b")!!

        assertEquals(listOf(a, b, Item("b'", "b copy"), c), rules)
        assertEquals("b'", id)
    }

    @Test
    fun `duplicate is nothing at the cap, for a missing rule, or for a locked one`() {
        assertNull(edits.duplicate(listOf(a, b, c, locked), "a"))
        assertNull(edits.duplicate(listOf(a), "b"))
        assertNull(edits.duplicate(listOf(a, locked), "x"))
    }

    @Test
    fun `delete removes the rule, a locked one included`() {
        assertEquals(listOf(a, c), edits.delete(listOf(a, b, c), "b"))
        assertEquals(listOf(a), edits.delete(listOf(a, locked), "x"))
        assertNull(edits.delete(listOf(a), "b"))
    }

    @Test
    fun `move shifts a rule by the delta, a locked one included`() {
        assertEquals(listOf(b, a, c), edits.move(listOf(a, b, c), "b", -1))
        assertEquals(listOf(a, c, b), edits.move(listOf(a, b, c), "b", 1))
        assertEquals(listOf(c, a, b), edits.move(listOf(a, b, c), "c", -2))
        assertEquals(listOf(locked, a), edits.move(listOf(a, locked), "x", -1))
    }

    @Test
    fun `move is nothing past either end, by zero, or for a missing rule`() {
        assertNull(edits.move(listOf(a, b), "a", -1))
        assertNull(edits.move(listOf(a, b), "b", 1))
        assertNull(edits.move(listOf(a, b), "a", 0))
        assertNull(edits.move(listOf(a, b), "c", 1))
    }

    @Test
    fun `the two lists hold the server's caps, and only a feed rule can be locked`() {
        assertTrue(
            RuleListEdits.mail.isFull(
                List(100) {
                    com.cabalmail.kit.models
                        .Rule()
                },
            ),
        )
        assertTrue(
            RuleListEdits.feed.isFull(
                List(100) {
                    com.cabalmail.kit.models
                        .FeedRule()
                },
            ),
        )
    }
}
