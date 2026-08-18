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
)

/**
 * The Addresses screen (plan §6.1) over [com.cabalmail.kit.cache.AddressRepository],
 * which the compose From picker also observes — so a revoke or favorite here
 * is reflected there without a refetch.
 */
class AddressesViewModel(
    private val container: AppContainer,
) : ViewModel() {
    private val mutableState = MutableStateFlow(AddressesUiState())
    val state: StateFlow<AddressesUiState> = mutableState.asStateFlow()

    init {
        viewModelScope.launch {
            val repository = runCatching { container.requireAddressRepository() }.getOrNull()
            repository?.addresses?.collect { addresses ->
                mutableState.update { it.copy(addresses = addresses) }
            }
        }
        refresh()
    }

    fun refresh() {
        viewModelScope.launch {
            mutableState.update { it.copy(refreshing = true, error = null) }
            try {
                container.requireAddressRepository().refresh()
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
        mutate(address.address, "Could not update favorite") { repository ->
            repository.setFavorite(address.address, favorite)
        }
    }

    fun revoke(address: Address) {
        mutate(address.address, "Could not revoke address") { repository ->
            repository.revoke(address.address)
        }
    }

    private fun mutate(
        address: String,
        failure: String,
        block: suspend (com.cabalmail.kit.cache.AddressRepository) -> Unit,
    ) {
        if (address in mutableState.value.busy) {
            return
        }
        mutableState.update { it.copy(busy = it.busy + address, error = null) }
        viewModelScope.launch {
            try {
                block(container.requireAddressRepository())
                mutableState.update { it.copy(busy = it.busy - address) }
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
            val all =
                container.configService.config.value
                    ?.mailDomains
                    .orEmpty()
            val allowed =
                runCatching { container.requireApi().listMyDomains() }
                    .getOrNull()
                    ?.let { permitted -> all.filter { it in permitted } }
                    ?: all
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
                container.requireAddressRepository().create(username, subdomain, tld, comment)
                mutableState.update { it.copy(creating = false) }
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

    companion object {
        fun factory(container: AppContainer): ViewModelProvider.Factory =
            viewModelFactory {
                initializer { AddressesViewModel(container) }
            }
    }
}
