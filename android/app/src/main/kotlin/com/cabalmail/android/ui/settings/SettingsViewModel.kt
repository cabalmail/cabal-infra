package com.cabalmail.android.ui.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.cabalmail.android.AppContainer
import com.cabalmail.android.notifications.PushRegistrar
import com.cabalmail.kit.models.Address
import com.cabalmail.kit.settings.AppPreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class SettingsUiState(
    val username: String? = null,
    /** The control domain this session is signed in to. */
    val controlDomain: String? = null,
    /** Owned addresses for the Default From picker; null until loaded. */
    val addresses: List<Address>? = null,
)

/**
 * Settings (plan §6.3). Preference values themselves come straight from
 * [com.cabalmail.kit.settings.PreferencesRepository]'s flow; this holds
 * only the surrounding account context.
 */
class SettingsViewModel(
    private val container: AppContainer,
) : ViewModel() {
    private val mutableState = MutableStateFlow(SettingsUiState())
    val state: StateFlow<SettingsUiState> = mutableState.asStateFlow()

    private val mutableFolderChoices = MutableStateFlow<List<String>?>(null)

    val preferences: StateFlow<AppPreferences> = container.preferences.preferences

    init {
        viewModelScope.launch {
            mutableState.update {
                it.copy(
                    username = runCatching { container.requireAuth().currentUsername() }.getOrNull(),
                    controlDomain = container.configService.controlDomain.value,
                )
            }
            val repository = runCatching { container.requireAddressRepository() }.getOrNull() ?: return@launch
            runCatching { repository.addresses.value ?: repository.refresh() }
            repository.addresses.collect { addresses ->
                mutableState.update { it.copy(addresses = addresses) }
            }
        }
    }

    fun update(transform: (AppPreferences) -> AppPreferences) {
        viewModelScope.launch { container.preferences.update(transform) }
    }

    /** Push registration when the notifications toggle turns on. */
    fun registerPush() {
        viewModelScope.launch { PushRegistrar.register(container) }
    }

    /** Folder names offered by the push-folders picker; null until loaded. */
    val folderChoices: StateFlow<List<String>?> = mutableFolderChoices.asStateFlow()

    /** Lazily fetches the folder list the first time the picker opens. */
    fun loadFolderChoices() {
        if (mutableFolderChoices.value != null) {
            return
        }
        viewModelScope.launch {
            mutableFolderChoices.value =
                runCatching { container.requireApi().listFolders().folders }.getOrNull()
        }
    }

    /**
     * Stores the folder scope and re-registers in the same coroutine, so
     * the token row is upserted only after the preference write landed.
     */
    fun updatePushFolders(folders: Set<String>) {
        viewModelScope.launch {
            container.preferences.update { it.copy(pushFolders = folders) }
            PushRegistrar.register(container)
        }
    }

    /** Push deregistration when the notifications toggle turns off. */
    fun deregisterPush() {
        viewModelScope.launch { PushRegistrar.deregister(container) }
    }

    companion object {
        fun factory(container: AppContainer): ViewModelProvider.Factory =
            viewModelFactory {
                initializer { SettingsViewModel(container) }
            }
    }
}
