package com.cabalmail.kit.cache

import com.cabalmail.kit.api.ApiClient
import com.cabalmail.kit.models.Address
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * In-memory address list: a [StateFlow] the Addresses screen and the
 * compose From-picker both observe, re-fetched after every mutation so all
 * observers converge on the server's view. Null until the first [refresh].
 *
 * Favorites sort first, then alphabetical — the ordering both the address
 * list and the From picker present.
 */
class AddressRepository(
    private val api: ApiClient,
) {
    private val mutableAddresses = MutableStateFlow<List<Address>?>(null)
    val addresses: StateFlow<List<Address>?> = mutableAddresses.asStateFlow()

    suspend fun refresh(): List<Address> {
        val sorted =
            api
                .listAddresses()
                .sortedWith(compareByDescending<Address> { it.favorite }.thenBy { it.address })
        mutableAddresses.value = sorted
        return sorted
    }

    /** Creates the address and returns the derived full address. */
    suspend fun create(
        username: String,
        subdomain: String,
        tld: String,
        comment: String,
    ): String {
        val created = api.newAddress(username, subdomain, tld, comment)
        refresh()
        return created
    }

    suspend fun revoke(address: String) {
        api.revokeAddress(address)
        refresh()
    }

    suspend fun setFavorite(
        address: String,
        favorite: Boolean,
    ) {
        api.setFavorite(address, favorite)
        refresh()
    }
}
