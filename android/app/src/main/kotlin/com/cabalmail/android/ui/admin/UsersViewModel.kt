package com.cabalmail.android.ui.admin

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.cabalmail.android.AppContainer
import com.cabalmail.android.userMessage
import com.cabalmail.kit.CabalmailException
import com.cabalmail.kit.models.DomainAllowance
import com.cabalmail.kit.models.PoolUser
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlin.coroutines.cancellation.CancellationException

/**
 * The slice of the client the Users screen needs, narrowed so tests can fake
 * it instead of the whole [com.cabalmail.kit.api.ApiClient] (the same shape
 * as the Apple client's `UsersBackend`).
 */
interface UsersBackend {
    suspend fun listUsers(): List<PoolUser>

    suspend fun listDomainAccess(): List<DomainAllowance>

    suspend fun confirm(username: String)

    suspend fun setEnabled(
        username: String,
        enabled: Boolean,
    )

    suspend fun delete(username: String)

    suspend fun setDomainAccess(
        user: String,
        domain: String,
        allowed: Boolean,
    )

    /** The configured mail domains, the ones access can be granted on. */
    fun mailDomains(): List<String>

    /** The signed-in administrator. */
    suspend fun currentUsername(): String?
}

private class LiveUsersBackend(
    private val container: AppContainer,
) : UsersBackend {
    override suspend fun listUsers(): List<PoolUser> = container.requireApi().listUsers()

    override suspend fun listDomainAccess(): List<DomainAllowance> = container.requireApi().listUserDomainAccess()

    override suspend fun confirm(username: String) = container.requireApi().confirmUser(username)

    override suspend fun setEnabled(
        username: String,
        enabled: Boolean,
    ) {
        if (enabled) container.requireApi().enableUser(username) else container.requireApi().disableUser(username)
    }

    override suspend fun delete(username: String) = container.requireApi().deleteUser(username)

    override suspend fun setDomainAccess(
        user: String,
        domain: String,
        allowed: Boolean,
    ) = container.requireApi().setUserDomainAccess(user, domain, allowed)

    override fun mailDomains(): List<String> =
        container.configService.config.value
            ?.mailDomains
            .orEmpty()

    override suspend fun currentUsername(): String? = container.requireAuth().currentUsername()
}

/** What a failed action was doing, so the screen can word it from `strings.xml`. */
enum class UsersAction { CONFIRM, ENABLE, DISABLE, DELETE, GRANT, REVOKE }

data class UsersActionError(
    val action: UsersAction,
    val username: String,
    /** The domain, for [UsersAction.GRANT] and [UsersAction.REVOKE]. */
    val domain: String? = null,
    /** The server's sentence, or a fallback, from [userMessage]. */
    val detail: String,
)

data class UsersUiState(
    val loading: Boolean = true,
    val loadError: String? = null,
    val users: List<PoolUser> = emptyList(),
    val allowances: Set<DomainAllowance> = emptySet(),
    val domains: List<String> = emptyList(),
    val currentUsername: String? = null,
    /** The server answered an admin call with 403. */
    val accessDenied: Boolean = false,
    /** Usernames with an action on the wire; their buttons are disabled. */
    val busy: Set<String> = emptySet(),
    val actionError: UsersActionError? = null,
) {
    /** Accounts awaiting confirmation: any Cognito status but `CONFIRMED`. */
    val pending: List<PoolUser> get() = listed.filter { it.isPending }

    /** Confirmed accounts. */
    val confirmed: List<PoolUser> get() = listed.filterNot { it.isPending }

    private val listed: List<PoolUser>
        get() =
            users
                .filterNot { it.username in SYSTEM_USERNAMES }
                .sortedBy { it.username.lowercase() }

    fun user(username: String): PoolUser? = users.firstOrNull { it.username == username }

    fun isCurrentUser(username: String): Boolean = username == currentUsername

    fun hasAccess(
        username: String,
        domain: String,
    ): Boolean = DomainAllowance(username, domain) in allowances

    companion object {
        /**
         * Pool accounts the system itself signs in as: `master` (the Lambdas'
         * IMAP logins), `dmarc` (report ingestion) and `ci-probe` (the
         * post-deploy mail probe), the accounts `require_admin_mfa` exempts
         * (`terraform/infra/modules/user_pool/require_admin_mfa.tf`). Hidden
         * so none can be disabled or deleted by accident.
         */
        val SYSTEM_USERNAMES = setOf("master", "dmarc", "ci-probe")
    }
}

/**
 * The administrator's Users screen (auth parity plan, C2): the pool's
 * accounts, split into those awaiting confirmation and the rest, and the
 * per-user domain allow list. The counterpart of the Apple client's
 * `UsersViewModel`.
 *
 * Every action is admin only on the server. A 403 sets
 * [UsersUiState.accessDenied], which the screen shows instead of the list;
 * the settings route then re-reads the session's admin status so Settings
 * stops listing Users.
 */
class UsersViewModel(
    private val backend: UsersBackend,
) : ViewModel() {
    private val mutableState = MutableStateFlow(UsersUiState(domains = backend.mailDomains()))
    val state: StateFlow<UsersUiState> = mutableState.asStateFlow()

    init {
        load()
    }

    /**
     * Fetches the accounts and the allow list together. Either failing fails
     * the load: toggles drawn from a missing allow list would all read as off.
     */
    fun load() {
        mutableState.update { it.copy(loading = true, loadError = null) }
        viewModelScope.launch {
            try {
                val (users, allowances) =
                    coroutineScope {
                        val users = async { backend.listUsers() }
                        val allowances = async { backend.listDomainAccess() }
                        users.await() to allowances.await()
                    }
                val currentUsername = runCatching { backend.currentUsername() }.getOrNull()
                mutableState.update {
                    it.copy(
                        loading = false,
                        users = users,
                        allowances = allowances.toSet(),
                        domains = backend.mailDomains(),
                        currentUsername = currentUsername,
                        accessDenied = false,
                    )
                }
            } catch (exception: CancellationException) {
                throw exception
            } catch (exception: Exception) {
                mutableState.update {
                    if (exception.isForbidden()) {
                        it.copy(loading = false, accessDenied = true)
                    } else {
                        it.copy(loading = false, loadError = userMessage(exception, "Could not load users"))
                    }
                }
            }
        }
    }

    fun confirm(username: String) {
        perform(username, UsersAction.CONFIRM) {
            backend.confirm(username)
            replace(username) { it.copy(status = "CONFIRMED") }
        }
    }

    fun setEnabled(
        username: String,
        enabled: Boolean,
    ) {
        // Disabling your own account would sign you out for good.
        if (!enabled && mutableState.value.isCurrentUser(username)) return
        perform(username, if (enabled) UsersAction.ENABLE else UsersAction.DISABLE) {
            backend.setEnabled(username, enabled)
            replace(username) { it.copy(enabled = enabled) }
        }
    }

    /** Deletes the account; the server refuses your own, and so does this. */
    fun delete(username: String) {
        if (mutableState.value.isCurrentUser(username)) return
        perform(username, UsersAction.DELETE) {
            backend.delete(username)
            mutableState.update { state ->
                state.copy(
                    users = state.users.filterNot { it.username == username },
                    allowances = state.allowances.filterNot { it.user == username }.toSet(),
                )
            }
        }
    }

    /** Grants or revokes access to [domain]; the toggle moves at once and back on a refusal. */
    fun setAccess(
        username: String,
        domain: String,
        allowed: Boolean,
    ) {
        val allowance = DomainAllowance(username, domain)
        val wasAllowed = allowance in mutableState.value.allowances
        if (wasAllowed == allowed) return
        apply(allowance, allowed)
        perform(
            username,
            if (allowed) UsersAction.GRANT else UsersAction.REVOKE,
            domain = domain,
            onFailure = { apply(allowance, wasAllowed) },
        ) {
            backend.setDomainAccess(username, domain, allowed)
        }
    }

    fun clearActionError() {
        mutableState.update { it.copy(actionError = null) }
    }

    private fun perform(
        username: String,
        action: UsersAction,
        domain: String? = null,
        onFailure: () -> Unit = {},
        work: suspend () -> Unit,
    ) {
        mutableState.update { it.copy(busy = it.busy + username) }
        viewModelScope.launch {
            try {
                work()
            } catch (exception: CancellationException) {
                throw exception
            } catch (exception: Exception) {
                onFailure()
                mutableState.update {
                    if (exception.isForbidden()) {
                        it.copy(accessDenied = true)
                    } else {
                        it.copy(
                            actionError =
                                UsersActionError(
                                    action = action,
                                    username = username,
                                    domain = domain,
                                    detail = userMessage(exception, "The server refused"),
                                ),
                        )
                    }
                }
            } finally {
                mutableState.update { it.copy(busy = it.busy - username) }
            }
        }
    }

    private fun replace(
        username: String,
        transform: (PoolUser) -> PoolUser,
    ) {
        mutableState.update { state ->
            state.copy(users = state.users.map { if (it.username == username) transform(it) else it })
        }
    }

    private fun apply(
        allowance: DomainAllowance,
        allowed: Boolean,
    ) {
        mutableState.update {
            it.copy(allowances = if (allowed) it.allowances + allowance else it.allowances - allowance)
        }
    }

    private fun Exception.isForbidden(): Boolean = (this as? CabalmailException.ApiError)?.httpStatus == 403

    companion object {
        fun factory(container: AppContainer): ViewModelProvider.Factory =
            viewModelFactory {
                initializer { UsersViewModel(LiveUsersBackend(container)) }
            }
    }
}
