package com.cabalmail.android.ui.addresses

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.cabalmail.android.AppContainer
import com.cabalmail.android.userMessage
import com.cabalmail.kit.models.Address
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * A completed address mutation worth confirming, so the screen can say so
 * the way React and the Apple clients do (#1485). The wording is the
 * screen's — the model names the event, `strings.xml` spells it.
 *
 * Favoriting is deliberately absent: the star flips under the user's
 * finger, so it confirms itself.
 */
sealed interface AddressesMessage {
    val address: String

    data class Created(
        override val address: String,
    ) : AddressesMessage

    data class Revoked(
        override val address: String,
    ) : AddressesMessage
}

data class AddressesUiState(
    /** Favorites first, then alphabetical (the repository's order); null until loaded. */
    val addresses: List<Address>? = null,
    val refreshing: Boolean = false,
    /** Addresses with a mutation in flight (revoke / favorite). */
    val busy: Set<String> = emptySet(),
    val error: String? = null,
    /** Mail apexes the user may mint on; null until the sheet loads them. */
    val mintableDomains: List<String>? = null,
    val creating: Boolean = false,
    val createError: String? = null,
    /** One-shot confirmation of a completed mutation; cleared once shown. */
    val message: AddressesMessage? = null,
)

/**
 * What the Addresses screen needs from the app graph. Narrow so the view
 * model is drivable from a unit test — the same seam [com.cabalmail.android.ui.rules.RulesBackend]
 * uses, and the reason this one exists: the success confirmations added for
 * #1485 had no way to be tested while the model held a concrete
 * [AppContainer].
 */
interface AddressesBackend {
    /**
     * The shared address list every observer converges on. Suspending
     * because the repository is only built once config and auth have
     * loaded.
     */
    suspend fun addresses(): StateFlow<List<Address>?>

    suspend fun refresh()

    /** Returns the derived full address. */
    suspend fun create(
        username: String,
        subdomain: String,
        tld: String,
        comment: String,
    ): String

    suspend fun revoke(address: String)

    suspend fun setFavorite(
        address: String,
        favorite: Boolean,
    )

    /** Mail apexes this user may mint on. */
    suspend fun mintableDomains(): List<String>
}

private class LiveAddressesBackend(
    private val container: AppContainer,
) : AddressesBackend {
    override suspend fun addresses(): StateFlow<List<Address>?> = container.requireAddressRepository().addresses

    override suspend fun refresh() {
        container.requireAddressRepository().refresh()
    }

    override suspend fun create(
        username: String,
        subdomain: String,
        tld: String,
        comment: String,
    ): String = container.requireAddressRepository().create(username, subdomain, tld, comment)

    override suspend fun revoke(address: String) {
        container.requireAddressRepository().revoke(address)
    }

    override suspend fun setFavorite(
        address: String,
        favorite: Boolean,
    ) {
        container.requireAddressRepository().setFavorite(address, favorite)
    }

    override suspend fun mintableDomains(): List<String> {
        val all =
            container.configService.config.value
                ?.mailDomains
                .orEmpty()
        return runCatching { container.requireApi().listMyDomains() }
            .getOrNull()
            ?.let { permitted -> all.filter { it in permitted } }
            ?: all
    }
}

/**
 * The Addresses screen (plan §6.1) over [com.cabalmail.kit.cache.AddressRepository],
 * which the compose From picker also observes — so a revoke or favorite here
 * is reflected there without a refetch.
 */
class AddressesViewModel(
    private val backend: AddressesBackend,
) : ViewModel() {
    private val mutableState = MutableStateFlow(AddressesUiState())
    val state: StateFlow<AddressesUiState> = mutableState.asStateFlow()

    init {
        viewModelScope.launch {
            runCatching { backend.addresses() }.getOrNull()?.collect { addresses ->
                mutableState.update { it.copy(addresses = addresses) }
            }
        }
        refresh()
    }

    fun refresh() {
        viewModelScope.launch {
            mutableState.update { it.copy(refreshing = true, error = null) }
            try {
                backend.refresh()
                mutableState.update { it.copy(refreshing = false) }
            } catch (exception: Exception) {
                mutableState.update {
                    it.copy(refreshing = false, error = userMessage(exception, "Could not load addresses"))
                }
            }
        }
    }

    fun setFavorite(
        address: Address,
        favorite: Boolean,
    ) {
        mutate(address.address, "Could not update favorite") {
            backend.setFavorite(address.address, favorite)
            null
        }
    }

    fun revoke(address: Address) {
        mutate(address.address, "Could not revoke address") {
            backend.revoke(address.address)
            AddressesMessage.Revoked(address.address)
        }
    }

    /**
     * Runs a per-row mutation, clearing the row's busy flag either way. The
     * block returns the confirmation to raise, or null for a mutation that
     * speaks for itself.
     */
    private fun mutate(
        address: String,
        failure: String,
        block: suspend () -> AddressesMessage?,
    ) {
        if (address in mutableState.value.busy) {
            return
        }
        mutableState.update { it.copy(busy = it.busy + address, error = null) }
        viewModelScope.launch {
            try {
                val message = block()
                mutableState.update { it.copy(busy = it.busy - address, message = message ?: it.message) }
            } catch (exception: Exception) {
                mutableState.update { it.copy(busy = it.busy - address, error = userMessage(exception, failure)) }
            }
        }
    }

    /** Loads the mint-eligible domain list for the "Request new" sheet. */
    fun loadMintableDomains() {
        if (mutableState.value.mintableDomains != null) {
            return
        }
        viewModelScope.launch {
            val allowed = runCatching { backend.mintableDomains() }.getOrNull().orEmpty()
            mutableState.update { it.copy(mintableDomains = allowed) }
        }
    }

    fun create(
        username: String,
        subdomain: String,
        tld: String,
        comment: String,
        onCreated: () -> Unit,
    ) {
        mutableState.update { it.copy(creating = true, createError = null) }
        viewModelScope.launch {
            try {
                val created = backend.create(username, subdomain, tld, comment)
                mutableState.update { it.copy(creating = false, message = AddressesMessage.Created(created)) }
                onCreated()
            } catch (exception: Exception) {
                mutableState.update {
                    it.copy(creating = false, createError = userMessage(exception, "Could not create address"))
                }
            }
        }
    }

    fun clearError() {
        mutableState.update { it.copy(error = null) }
    }

    fun clearMessage() {
        mutableState.update { it.copy(message = null) }
    }

    companion object {
        fun factory(container: AppContainer): ViewModelProvider.Factory =
            viewModelFactory {
                initializer { AddressesViewModel(LiveAddressesBackend(container)) }
            }
    }
}
