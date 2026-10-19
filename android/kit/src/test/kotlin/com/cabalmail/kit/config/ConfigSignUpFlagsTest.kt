package com.cabalmail.kit.config

import kotlinx.serialization.json.Json
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * `invitation_required` and `sms_enabled` decide which fields the sign-up
 * screens show. They read as the webmail reads them (`App.jsx`), and a file
 * without them still decodes (auth parity plan, B1).
 */
class ConfigSignUpFlagsTest {
    // ConfigService's own decoder settings.
    private val json = Json { ignoreUnknownKeys = true }

    private fun decode(flags: String): Config =
        json.decodeFromString(
            """
            {
              "control_domain": "example.com",
              "invokeUrl": "https://api.example.com/prod",
              $flags
              "cognitoConfig": {"region": "us-east-1", "poolData": {"UserPoolId": "p", "ClientId": "c"}}
            }
            """.trimIndent(),
        )

    @Test
    fun `the flags are read`() {
        val gated = decode(""""invitation_required": true, "sms_enabled": false,""")
        assertTrue(gated.invitationRequired)
        assertFalse(gated.smsEnabled)

        val open = decode(""""invitation_required": false, "sms_enabled": true,""")
        assertFalse(open.invitationRequired)
        assertTrue(open.smsEnabled)
    }

    /** An older file: no invitation field, and the phone field kept. */
    @Test
    fun `missing flags take the webmail's defaults`() {
        val config = decode("")
        assertFalse(config.invitationRequired)
        assertTrue(config.smsEnabled)
    }

    /**
     * The consent text names the operator when the file does; an older
     * file, `OPERATOR_NAME` unset or a malformed value leave it out.
     */
    @Test
    fun `the operator name is read when present`() {
        assertEquals("Example Operator LLC", decode(""""operator_name": " Example Operator LLC ",""").operatorName)
        assertEquals("", decode("").operatorName)
        assertEquals("", decode(""""operator_name": 7,""").operatorName)
        assertEquals("", decode(""""operator_name": null,""").operatorName)
    }

    /** A flag of the wrong type must not cost the user the sign-in form. */
    @Test
    fun `a malformed flag does not fail the file`() {
        val config = decode(""""invitation_required": "true", "sms_enabled": null,""")
        assertFalse(config.invitationRequired)
        assertTrue(config.smsEnabled)

        val numeric = decode(""""invitation_required": 1, "sms_enabled": 0,""")
        assertFalse(numeric.invitationRequired)
        assertTrue(numeric.smsEnabled)
    }
}
