package com.cabalmail.android

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Whether the device currently has a validated internet path (plan §7.4).
 * Drives the offline banner and the send queue's reconnect trigger.
 *
 * Tracks the networks the callback reports rather than re-querying
 * `activeNetwork` on each event: during a loss the framework can still
 * name the dying network as active, and no later event would correct it.
 */
class ConnectivityMonitor(
    context: Context,
) {
    private val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val validated = mutableMapOf<Network, Boolean>()
    private val mutableOnline = MutableStateFlow(isOnlineNow())
    val online: StateFlow<Boolean> = mutableOnline.asStateFlow()

    private val callback =
        object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                synchronized(validated) {
                    validated[network] = manager.getNetworkCapabilities(network)?.isValidated() ?: false
                }
                publish()
            }

            override fun onLost(network: Network) {
                synchronized(validated) { validated.remove(network) }
                publish()
            }

            override fun onCapabilitiesChanged(
                network: Network,
                networkCapabilities: NetworkCapabilities,
            ) {
                synchronized(validated) { validated[network] = networkCapabilities.isValidated() }
                publish()
            }
        }

    init {
        runCatching {
            manager.registerNetworkCallback(
                NetworkRequest.Builder().addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET).build(),
                callback,
            )
        }
    }

    private fun publish() {
        mutableOnline.value = synchronized(validated) { validated.values.any { it } }
    }

    private fun isOnlineNow(): Boolean = manager.getNetworkCapabilities(manager.activeNetwork)?.isValidated() ?: false

    private fun NetworkCapabilities.isValidated(): Boolean =
        hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
}
