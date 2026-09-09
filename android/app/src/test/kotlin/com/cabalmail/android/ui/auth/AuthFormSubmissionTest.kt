package com.cabalmail.android.ui.auth

import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.io.File

class AuthFormSubmissionTest {
    @Test
    fun `a complete sign-in form is submittable`() {
        assertTrue(
            canSubmitSignIn(busy = false, controlDomain = "admin.example.com", username = "ann", password = "s3cret"),
        )
    }

    @Test
    fun `a blank field blocks submission`() {
        assertFalse(canSubmitSignIn(busy = false, controlDomain = "", username = "ann", password = "s3cret"))
        assertFalse(
            canSubmitSignIn(busy = false, controlDomain = "admin.example.com", username = " ", password = "s3cret"),
        )
        assertFalse(canSubmitSignIn(busy = false, controlDomain = "admin.example.com", username = "ann", password = ""))
    }

    @Test
    fun `a sign-in already in flight is not submittable again`() {
        assertFalse(
            canSubmitSignIn(busy = true, controlDomain = "admin.example.com", username = "ann", password = "s3cret"),
        )
    }

    @Test
    fun `an MFA code is submittable once entered`() {
        assertTrue(canSubmitMfaCode(busy = false, code = "123456"))
        assertFalse(canSubmitMfaCode(busy = false, code = ""))
        assertFalse(canSubmitMfaCode(busy = true, code = "123456"))
    }
}

/**
 * The other half of #1477 is layout, which has no unit-test seam: what broke
 * was that the auth form could not scroll and its fields wired no IME action,
 * so on a landscape tablet the software keyboard covered `Sign In` and
 * `Verify` with no way to reach either. These hold the source to the rule.
 * Gradle runs unit tests from the module directory, so the repository root is
 * two levels up.
 */
class SignInScreenImeScanTest {
    private val source: String =
        File(File("../..").canonicalFile, "android/app/src/main/kotlin/com/cabalmail/android/ui/auth/SignInScreen.kt")
            .readText()

    private val fields: List<String>
        get() {
            val starts = Regex("OutlinedTextField\\(").findAll(source).map { it.range.first }.toList()
            return starts.mapIndexed { index, start ->
                source.substring(start, starts.getOrNull(index + 1) ?: source.length)
            }
        }

    @Test
    fun `the form gives back the IME's space and scrolls what is left`() {
        assertTrue(source.contains(".imePadding()"), "the auth form must not sit under the keyboard")
        assertTrue(source.contains(".verticalScroll("), "the auth form must scroll when the keyboard takes the height")
    }

    @Test
    fun `every field declares an IME action`() {
        assertTrue(fields.size >= 4, "expected the control-domain, username, password and MFA fields")
        fields.forEachIndexed { index, field ->
            assertTrue(field.contains("imeAction = ImeAction."), "field $index wires no IME action key")
        }
    }

    @Test
    fun `the terminal fields submit from the keyboard, on the button's own condition`() {
        assertTrue(
            source.contains("onDone = { if (canSignIn) onSignIn(controlDomain, username, password) }"),
            "the password field's action key must submit exactly what the Sign In button submits",
        )
        assertTrue(
            source.contains("onDone = { if (canSubmitCode) onSubmitMfaCode(mfaCode) }"),
            "the MFA field's action key must submit exactly what the Verify button submits",
        )
    }
}
