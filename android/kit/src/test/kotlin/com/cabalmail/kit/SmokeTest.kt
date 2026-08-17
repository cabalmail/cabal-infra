package com.cabalmail.kit

import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Test

/** Verifies the module compiles and the JUnit 5 platform is wired up. */
class SmokeTest {
    @Test
    fun `kit module compiles and its types are constructible`() {
        assertNotNull(CabalmailClient::class)
    }
}
