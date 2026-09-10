package com.cabalmail.android.ui.addresses

import com.cabalmail.kit.models.Address
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
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

/**
 * Regression coverage for issue #1485: a successful create or revoke said
 * nothing on Android, while React posts `Address "<addr>" created.` /
 * `Revoked "<addr>".` and the Apple clients raise the same pair. The only
 * thing the screen's `SnackbarHost` ever showed was `state.error`, so the
 * whole feedback for a revoke was the row disappearing — measured 1.4-2.9s
 * behind the tap on the retest.
 *
 * Failure paths keep their existing behaviour, and favoriting stays silent
 * (the star flips under the finger). Both are pinned here so a later change
 * that starts confirming everything has to say so.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class AddressesConfirmationTest {
    private val dispatcher = StandardTestDispatcher()

    @BeforeEach
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @AfterEach
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private class FakeBackend : AddressesBackend {
        val rows =
            MutableStateFlow<List<Address>?>(
                listOf(Address(address = "old@a.example.com")),
            )
        var created = "new@a.example.com"
        var failure: Exception? = null
        val revoked = mutableListOf<String>()
        val favorited = mutableListOf<Pair<String, Boolean>>()

        override suspend fun addresses(): StateFlow<List<Address>?> = rows.asStateFlow()

        override suspend fun refresh() {
            failure?.let { throw it }
        }

        override suspend fun create(
            username: String,
            subdomain: String,
            tld: String,
            comment: String,
        ): String {
            failure?.let { throw it }
            return created
        }

        override suspend fun revoke(address: String) {
            failure?.let { throw it }
            revoked += address
        }

        override suspend fun setFavorite(
            address: String,
            favorite: Boolean,
        ) {
            failure?.let { throw it }
            favorited += address to favorite
        }

        override suspend fun mintableDomains(): List<String> = listOf("a.example.com")
    }

    @Test
    fun `a successful create confirms the address the server derived`() =
        runTest(dispatcher) {
            val backend = FakeBackend().apply { created = "minted@a.example.com" }
            val viewModel = AddressesViewModel(backend)
            var closed = false

            viewModel.create("minted", "a", "example.com", "") { closed = true }
            advanceUntilIdle()

            // The confirmation names the address the server composed, not
            // the parts the user typed.
            assertEquals(AddressesMessage.Created("minted@a.example.com"), viewModel.state.value.message)
            assertTrue(closed)
            assertNull(viewModel.state.value.createError)
        }

    @Test
    fun `a successful revoke confirms the address`() =
        runTest(dispatcher) {
            val backend = FakeBackend()
            val viewModel = AddressesViewModel(backend)

            viewModel.revoke(Address(address = "burned@a.example.com"))
            advanceUntilIdle()

            assertEquals(AddressesMessage.Revoked("burned@a.example.com"), viewModel.state.value.message)
            assertEquals(listOf("burned@a.example.com"), backend.revoked)
        }

    @Test
    fun `showing a confirmation clears it, so a recomposition cannot repeat it`() =
        runTest(dispatcher) {
            val backend = FakeBackend()
            val viewModel = AddressesViewModel(backend)

            viewModel.revoke(Address(address = "burned@a.example.com"))
            advanceUntilIdle()
            assertNotNull(viewModel.state.value.message)
            viewModel.clearMessage()

            assertNull(viewModel.state.value.message)
        }

    @Test
    fun `favoriting stays silent`() =
        runTest(dispatcher) {
            val backend = FakeBackend()
            val viewModel = AddressesViewModel(backend)

            viewModel.setFavorite(Address(address = "kept@a.example.com"), true)
            advanceUntilIdle()

            assertNull(viewModel.state.value.message)
            assertEquals(listOf("kept@a.example.com" to true), backend.favorited)
        }

    @Test
    fun `a failed create raises the sheet's error and no confirmation`() =
        runTest(dispatcher) {
            val backend = FakeBackend().apply { failure = IllegalStateException("nope") }
            val viewModel = AddressesViewModel(backend)
            var closed = false

            viewModel.create("minted", "a", "example.com", "") { closed = true }
            advanceUntilIdle()

            assertNull(viewModel.state.value.message)
            assertFalse(closed)
            assertNotNull(viewModel.state.value.createError)
        }

    @Test
    fun `a failed revoke raises the screen's error and no confirmation`() =
        runTest(dispatcher) {
            val backend = FakeBackend().apply { failure = IllegalStateException("nope") }
            val viewModel = AddressesViewModel(backend)

            viewModel.revoke(Address(address = "burned@a.example.com"))
            advanceUntilIdle()

            assertNull(viewModel.state.value.message)
            assertNotNull(viewModel.state.value.error)
            assertEquals(emptySet<String>(), viewModel.state.value.busy)
        }
}
