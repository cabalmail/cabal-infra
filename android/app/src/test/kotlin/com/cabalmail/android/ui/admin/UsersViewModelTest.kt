package com.cabalmail.android.ui.admin

import com.cabalmail.android.ui.settings.SettingsCategory
import com.cabalmail.kit.CabalmailException
import com.cabalmail.kit.models.DomainAllowance
import com.cabalmail.kit.models.PoolUser
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import java.io.IOException

/**
 * [UsersViewModel] against a scripted [UsersBackend] (auth parity plan, C2),
 * mirroring the Apple client's `UsersViewModelTests`: the pending / confirmed
 * split, the hidden system accounts, each action, the self guard, the
 * optimistic domain toggle, and the 403 path.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class UsersViewModelTest {
    private val dispatcher = StandardTestDispatcher()

    @BeforeEach
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @AfterEach
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private class FakeBackend : UsersBackend {
        var users =
            listOf(
                PoolUser("zed", "CONFIRMED", enabled = true),
                PoolUser("admin", "CONFIRMED", enabled = true),
                PoolUser("alice", "CONFIRMED", enabled = true, osidText = "2001"),
                PoolUser("newbie", "UNCONFIRMED", enabled = true),
                PoolUser("resetter", "FORCE_CHANGE_PASSWORD", enabled = true),
                PoolUser("master", "CONFIRMED", enabled = true),
                PoolUser("dmarc", "CONFIRMED", enabled = true),
                PoolUser("ci-probe", "CONFIRMED", enabled = true),
            )
        var allowances = listOf(DomainAllowance("alice", "cabalmail.example"))
        var listFailure: Exception? = null
        var allowanceFailure: Exception? = null
        var actionFailure: Exception? = null

        /** When set, every action waits on it before answering. */
        var gate: CompletableDeferred<Unit>? = null
        val calls = mutableListOf<String>()

        override suspend fun listUsers(): List<PoolUser> = listFailure?.let { throw it } ?: users

        override suspend fun listDomainAccess(): List<DomainAllowance> =
            allowanceFailure?.let { throw it } ?: allowances

        override suspend fun confirm(username: String) = act("confirm $username")

        override suspend fun setEnabled(
            username: String,
            enabled: Boolean,
        ) = act("setEnabled $username $enabled")

        override suspend fun delete(username: String) = act("delete $username")

        override suspend fun setDomainAccess(
            user: String,
            domain: String,
            allowed: Boolean,
        ) = act("setDomainAccess $user $domain $allowed")

        override fun mailDomains(): List<String> = listOf("cabalmail.example", "other.example")

        override suspend fun currentUsername(): String = "admin"

        private suspend fun act(call: String) {
            calls += call
            gate?.await()
            actionFailure?.let { throw it }
        }
    }

    private val forbidden = CabalmailException.ApiError(403, "Admin access required")

    @Test
    fun `load splits pending from confirmed and hides the system accounts`() =
        runTest(dispatcher) {
            val model = UsersViewModel(FakeBackend())
            advanceUntilIdle()

            val state = model.state.value
            assertEquals(listOf("newbie", "resetter"), state.pending.map { it.username })
            assertEquals(listOf("admin", "alice", "zed"), state.confirmed.map { it.username })
            assertFalse(state.loading)
            assertNull(state.loadError)
            assertEquals("admin", state.currentUsername)
            assertEquals(listOf("cabalmail.example", "other.example"), state.domains)
            assertTrue(state.hasAccess("alice", "cabalmail.example"))
            assertFalse(state.hasAccess("alice", "other.example"))
        }

    @Test
    fun `a load failure shows an error and a reload recovers`() =
        runTest(dispatcher) {
            val backend = FakeBackend().apply { listFailure = IOException("offline") }
            val model = UsersViewModel(backend)
            advanceUntilIdle()
            assertNotNull(model.state.value.loadError)

            backend.listFailure = null
            model.load()
            advanceUntilIdle()
            assertNull(model.state.value.loadError)
            assertEquals(3, model.state.value.confirmed.size)
        }

    /** Toggles drawn without the allow list would all read as off. */
    @Test
    fun `the allow list failing fails the load`() =
        runTest(dispatcher) {
            val model = UsersViewModel(FakeBackend().apply { allowanceFailure = IOException("offline") })
            advanceUntilIdle()
            assertNotNull(model.state.value.loadError)
        }

    @Test
    fun `a 403 on load shows administrators only rather than an error`() =
        runTest(dispatcher) {
            val model = UsersViewModel(FakeBackend().apply { listFailure = forbidden })
            advanceUntilIdle()

            assertTrue(model.state.value.accessDenied)
            assertNull(model.state.value.loadError)
        }

    @Test
    fun `confirming marks the account confirmed`() =
        runTest(dispatcher) {
            val backend = FakeBackend()
            val model = UsersViewModel(backend)
            advanceUntilIdle()

            model.confirm("newbie")
            advanceUntilIdle()

            assertEquals("confirm newbie", backend.calls.last())
            assertEquals(
                listOf("resetter"),
                model.state.value.pending
                    .map { it.username },
            )
            assertTrue(
                model.state.value.confirmed
                    .any { it.username == "newbie" },
            )
        }

    @Test
    fun `disabling and enabling flip sign-in`() =
        runTest(dispatcher) {
            val backend = FakeBackend()
            val model = UsersViewModel(backend)
            advanceUntilIdle()

            model.setEnabled("alice", enabled = false)
            advanceUntilIdle()
            assertEquals(
                false,
                model.state.value
                    .user("alice")
                    ?.enabled,
            )
            model.setEnabled("alice", enabled = true)
            advanceUntilIdle()
            assertEquals(
                true,
                model.state.value
                    .user("alice")
                    ?.enabled,
            )
            assertEquals(listOf("setEnabled alice false", "setEnabled alice true"), backend.calls.takeLast(2))
        }

    /** The server only refuses deleting yourself; disabling yourself would lock you out. */
    @Test
    fun `your own account is neither disabled nor deleted`() =
        runTest(dispatcher) {
            val backend = FakeBackend()
            val model = UsersViewModel(backend)
            advanceUntilIdle()

            model.setEnabled("admin", enabled = false)
            model.delete("admin")
            advanceUntilIdle()

            assertTrue(backend.calls.isEmpty())
            assertEquals(
                true,
                model.state.value
                    .user("admin")
                    ?.enabled,
            )
        }

    @Test
    fun `deleting removes the account and its grants`() =
        runTest(dispatcher) {
            val backend = FakeBackend()
            val model = UsersViewModel(backend)
            advanceUntilIdle()

            model.delete("alice")
            advanceUntilIdle()

            assertEquals("delete alice", backend.calls.last())
            assertNull(model.state.value.user("alice"))
            assertFalse(model.state.value.hasAccess("alice", "cabalmail.example"))
        }

    @Test
    fun `a domain toggle moves at once and back when refused`() =
        runTest(dispatcher) {
            val backend = FakeBackend()
            val model = UsersViewModel(backend)
            advanceUntilIdle()
            val gate = CompletableDeferred<Unit>().also { backend.gate = it }
            backend.actionFailure = CabalmailException.ApiError(400, "Unknown domain \"other.example\"")

            model.setAccess("alice", "other.example", allowed = true)
            advanceUntilIdle()
            assertTrue(model.state.value.hasAccess("alice", "other.example"), "the toggle moves before the reply")
            assertTrue("alice" in model.state.value.busy)

            gate.complete(Unit)
            advanceUntilIdle()
            assertFalse(model.state.value.hasAccess("alice", "other.example"), "and back when the server refuses")
            assertFalse("alice" in model.state.value.busy)
            val error = model.state.value.actionError
            assertEquals(UsersAction.GRANT, error?.action)
            assertEquals("other.example", error?.domain)
            assertEquals("Unknown domain \"other.example\"", error?.detail)
        }

    @Test
    fun `revoking access sends allowed false`() =
        runTest(dispatcher) {
            val backend = FakeBackend()
            val model = UsersViewModel(backend)
            advanceUntilIdle()

            model.setAccess("alice", "cabalmail.example", allowed = false)
            advanceUntilIdle()

            assertEquals("setDomainAccess alice cabalmail.example false", backend.calls.last())
            assertFalse(model.state.value.hasAccess("alice", "cabalmail.example"))
            assertNull(model.state.value.actionError)
        }

    @Test
    fun `a failed action reports which and changes nothing`() =
        runTest(dispatcher) {
            val backend = FakeBackend()
            val model = UsersViewModel(backend)
            advanceUntilIdle()
            backend.actionFailure = CabalmailException.ApiError(500, "boom")

            model.confirm("newbie")
            advanceUntilIdle()

            assertEquals(
                UsersAction.CONFIRM,
                model.state.value.actionError
                    ?.action,
            )
            assertEquals(
                listOf("newbie", "resetter"),
                model.state.value.pending
                    .map { it.username },
            )

            model.clearActionError()
            assertNull(model.state.value.actionError)
        }

    @Test
    fun `a 403 on an action shows administrators only`() =
        runTest(dispatcher) {
            val backend = FakeBackend()
            val model = UsersViewModel(backend)
            advanceUntilIdle()
            backend.actionFailure = forbidden

            model.setEnabled("alice", enabled = false)
            advanceUntilIdle()

            assertTrue(model.state.value.accessDenied)
            assertNull(model.state.value.actionError)
        }

    @Test
    fun `settings lists users only for an administrator`() {
        assertFalse(SettingsCategory.USERS in SettingsCategory.listed(isAdmin = false))
        val forAdmin = SettingsCategory.listed(isAdmin = true)
        assertTrue(SettingsCategory.USERS in forAdmin)
        assertEquals(SettingsCategory.listed(isAdmin = false), forAdmin.filter { it != SettingsCategory.USERS })
    }
}
