package com.cabalmail.android.ui.rules

import com.cabalmail.kit.models.RuleField
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

/**
 * Which rule condition fields take the email keyboard (#2022): the address
 * headers do, the free-text fields keep the plain one.
 */
class RuleFieldKeyboardTest {
    @Test
    fun `only the address headers take the email keyboard`() {
        assertEquals(
            listOf(RuleField.FROM, RuleField.TO, RuleField.CC),
            RuleField.entries.filter { it.holdsAddresses },
        )
    }
}
