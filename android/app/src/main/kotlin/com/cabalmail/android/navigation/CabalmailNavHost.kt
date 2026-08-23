package com.cabalmail.android.navigation

import android.net.Uri
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.adaptive.currentWindowAdaptiveInfo
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteScaffold
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteScaffoldDefaults
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteType
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import androidx.window.core.layout.WindowWidthSizeClass
import com.cabalmail.android.AppContainer
import com.cabalmail.android.R
import com.cabalmail.android.Shortcut
import com.cabalmail.android.notifications.NewMailSync
import com.cabalmail.android.notifications.PushRegistrar
import com.cabalmail.android.ui.addresses.AddressesScreen
import com.cabalmail.android.ui.addresses.AddressesViewModel
import com.cabalmail.android.ui.compose.ComposeLaunch
import com.cabalmail.android.ui.compose.ComposeScreen
import com.cabalmail.android.ui.compose.ComposeViewModel
import com.cabalmail.android.ui.folders.FoldersAdminScreen
import com.cabalmail.android.ui.folders.FoldersAdminViewModel
import com.cabalmail.android.ui.mail.FolderListScreen
import com.cabalmail.android.ui.mail.FoldersViewModel
import com.cabalmail.android.ui.mail.MailListDetailScreen
import com.cabalmail.android.ui.mail.MessageDetailScreen
import com.cabalmail.android.ui.mail.MessageDetailViewModel
import com.cabalmail.android.ui.mail.MessageListScreen
import com.cabalmail.android.ui.mail.MessageListViewModel
import com.cabalmail.android.ui.mail.SearchScreen
import com.cabalmail.android.ui.mail.SearchViewModel
import com.cabalmail.android.ui.mail.disposeAdvanceTarget
import com.cabalmail.android.ui.settings.SettingsScreen
import com.cabalmail.android.ui.settings.SettingsViewModel
import com.cabalmail.kit.models.NavState
import kotlinx.coroutines.launch

/**
 * The top-level destinations (plan §7.1): a bottom `NavigationBar` on
 * phones, a `NavigationRail` from medium widths up — chosen by
 * [NavigationSuiteScaffold] from the window size class.
 */
enum class TopLevel(
    val route: String,
    val labelRes: Int,
    val icon: ImageVector,
) {
    MAIL("folders", R.string.nav_mail, Icons.Default.Email),
    ADDRESSES("addresses", R.string.addresses_title, Icons.Default.Person),
    FOLDERS("folders_admin", R.string.nav_folders, Icons.AutoMirrored.Filled.List),
    SETTINGS("settings", R.string.settings_title, Icons.Default.Settings),
}

/** Routes that belong to the Mail tab even though they are nested. */
private val MAIL_ROUTES =
    setOf("folders", "messages/{folder}?uid={uid}", "search?folder={folder}", "message/{folder}/{uid}")

/** The folder phone-width launches open into. */
private const val INBOX = "INBOX"

/**
 * Navigation shell: the suite (bar / rail), the graph, and the app-wide
 * overlays (offline banner, unsent-draft prompt). Folder paths ride as
 * encoded route arguments (they may contain `/`).
 */
@Composable
fun CabalmailNavHost(
    container: AppContainer,
    onSignOut: () -> Unit,
) {
    val navController = rememberNavController()
    val scope = rememberCoroutineScope()
    val backStackEntry by navController.currentBackStackEntryAsState()
    val currentRoute = backStackEntry?.destination?.route
    val adaptiveInfo = currentWindowAdaptiveInfo()
    val compactWidth = adaptiveInfo.windowSizeClass.windowWidthSizeClass == WindowWidthSizeClass.COMPACT

    // Every compose entry stages a seed draft in the local buffer first and
    // navigates by id (see ComposeLaunch).
    val openCompose: (String) -> Unit = { draftId -> navController.navigate("compose/$draftId") }
    val composeNew: () -> Unit = {
        scope.launch { openCompose(ComposeLaunch.stage(container, ComposeLaunch.blank(container))) }
    }

    // Preferences (plan §6.3): the synced subset is re-pulled on every
    // launch so web/Apple changes apply here (server wins).
    val context = LocalContext.current
    LaunchedEffect(Unit) {
        container.preferences.refreshFromServer()
        // Keep the background sync scheduled to match the preference (a
        // fresh install or a cleared WorkManager DB would otherwise drift).
        NewMailSync.schedule(context, container.preferences.current().notificationsEnabled)
        // Re-assert the push registration every launch, like the Apple
        // client: /push_register is an idempotent upsert, and this is what
        // heals reinstalls and missed token rotations. Quiet no-op when
        // push is unavailable or the user has not opted in.
        PushRegistrar.register(container)
    }

    // Ctrl+N from anywhere but an open compose (plan §7.2).
    LaunchedEffect(Unit) {
        container.shortcuts.events.collect { shortcut ->
            if (shortcut == Shortcut.COMPOSE &&
                navController.currentBackStackEntry?.destination?.route != "compose/{draftId}"
            ) {
                composeNew()
            }
        }
    }

    // Shared content (ACTION_SEND) lands in a fresh compose, once.
    LaunchedEffect(Unit) {
        container.shareIntake.pending.collect { pending ->
            if (pending != null) {
                val content = container.shareIntake.consume() ?: return@collect
                val draft = ComposeLaunch.fromShare(container, content)
                openCompose(ComposeLaunch.stage(container, draft))
            }
        }
    }

    // A local draft left behind by a kill mid-compose (or a close whose
    // server save failed) is offered once per launch, like the resume
    // cursor — never opened unbidden. Hosted here rather than on the folder
    // screen because a same-install resume cursor may land elsewhere.
    val snackbarHostState = remember { SnackbarHostState() }
    val localDraftMessage = stringResource(R.string.local_draft_prompt)
    val localDraftAction = stringResource(R.string.local_draft_resume)
    LaunchedEffect(Unit) {
        if (container.launchOneShotsDone) {
            return@LaunchedEffect
        }
        container.launchOneShotsDone = true
        container.sendQueue.flush()
        container.draftStore.pruneEmpty()
        val unsent = container.draftStore.list().firstOrNull { it.queuedMessageId == null }
        val draftId = unsent?.id ?: return@LaunchedEffect
        val result =
            snackbarHostState.showSnackbar(
                message = localDraftMessage,
                actionLabel = localDraftAction,
                withDismissAction = true,
                duration = SnackbarDuration.Indefinite,
            )
        if (result == SnackbarResult.ActionPerformed) {
            openCompose(draftId)
        }
    }

    // Notification taps (plan §7.3) open the message: in the pane on wide
    // windows, pushed on phones.
    LaunchedEffect(Unit) {
        container.openIntake.pending.collect { pending ->
            if (pending != null) {
                val request = container.openIntake.consume() ?: return@collect
                navController.openCursor(NavState(folder = request.folder, uid = request.uid), compactWidth)
            }
        }
    }

    // Outbox (plan §7.4): outcomes surface here (the launch flush is above).
    LaunchedEffect(Unit) {
        container.sendQueue.notices.collect { notice -> snackbarHostState.showSnackbar(notice) }
    }

    // Phones launch straight into INBOX, with the folder list beneath it on
    // the back stack; wide windows keep the folder list as the hub.
    // Process-scoped (like the one-shots above) so an activity recreation
    // doesn't push a second copy onto the restored stack, and consumed even
    // on wide windows so a later resize to compact doesn't yank mid-session.
    LaunchedEffect(Unit) {
        if (!container.launchDestinationDone) {
            container.launchDestinationDone = true
            if (compactWidth) {
                navController.navigate("messages/${Uri.encode(INBOX)}")
            }
        }
    }

    // Resume cursor (plan §4.5): a cursor this install wrote restores
    // silently; one from another device only offers a prompt — hosted on the
    // app-wide snackbar (like the unsent-draft prompt) so it shows over the
    // INBOX launch view too — and launch never yanks the user unbidden.
    val resumeMessage = stringResource(R.string.resume_prompt)
    val resumeAction = stringResource(R.string.resume_action)
    LaunchedEffect(Unit) {
        val cursor = container.navCursor.restoreOnce() ?: return@LaunchedEffect
        if (cursor.local) {
            navController.openCursor(cursor.state, compactWidth)
            return@LaunchedEffect
        }
        val result =
            snackbarHostState.showSnackbar(
                message = resumeMessage,
                actionLabel = resumeAction,
                withDismissAction = true,
                duration = SnackbarDuration.Indefinite,
            )
        if (result == SnackbarResult.ActionPerformed) {
            navController.openCursor(cursor.state, compactWidth)
        }
    }

    // The suite shows on top-level destinations; on phones it hides inside
    // nested mail screens (list / reader / compose / search) to give the
    // content the full height, while the rail stays put on wider windows.
    val topLevel = TopLevel.entries.any { it.route == currentRoute }
    val layoutType =
        if (topLevel || !compactWidth) {
            NavigationSuiteScaffoldDefaults.calculateFromAdaptiveInfo(adaptiveInfo)
        } else {
            NavigationSuiteType.None
        }
    val online by container.connectivity.online.collectAsState()

    NavigationSuiteScaffold(
        layoutType = layoutType,
        navigationSuiteItems = {
            TopLevel.entries.forEach { destination ->
                val selected =
                    backStackEntry?.destination?.hierarchy?.any { it.route == destination.route } == true ||
                        (destination == TopLevel.MAIL && currentRoute in MAIL_ROUTES)
                item(
                    selected = selected,
                    onClick = {
                        navController.navigate(destination.route) {
                            popUpTo(navController.graph.findStartDestination().id) { saveState = true }
                            launchSingleTop = true
                            restoreState = true
                        }
                    },
                    icon = { Icon(destination.icon, contentDescription = null) },
                    label = { Text(stringResource(destination.labelRes)) },
                )
            }
        },
    ) {
        Box(modifier = Modifier.fillMaxSize()) {
            Column(modifier = Modifier.fillMaxSize()) {
                if (!online) {
                    OfflineBanner()
                }
                // The banner already sits under the status bar; tell the
                // screens' Scaffolds not to pad for it a second time.
                Box(
                    modifier =
                        Modifier
                            .weight(1f)
                            .then(if (!online) Modifier.consumeWindowInsets(WindowInsets.statusBars) else Modifier),
                ) {
                    MailNavGraph(
                        navController = navController,
                        container = container,
                        compactWidth = compactWidth,
                        onSignOut = onSignOut,
                        composeNew = composeNew,
                        openCompose = openCompose,
                    )
                }
            }
            // Sits above the compose FAB / reader bottom bar rather than over them.
            SnackbarHost(
                hostState = snackbarHostState,
                modifier =
                    Modifier
                        .align(Alignment.BottomCenter)
                        .navigationBarsPadding()
                        .padding(bottom = 88.dp),
            )
        }
    }
}

/** Plan §7.4: a slim strip while there is no validated internet path. */
@Composable
private fun OfflineBanner() {
    Surface(
        color = MaterialTheme.colorScheme.errorContainer,
        contentColor = MaterialTheme.colorScheme.onErrorContainer,
        modifier = Modifier.fillMaxWidth().statusBarsPadding(),
    ) {
        Text(
            text = stringResource(R.string.offline_banner),
            style = MaterialTheme.typography.labelMedium,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp),
        )
    }
}

@Composable
private fun MailNavGraph(
    navController: NavHostController,
    container: AppContainer,
    compactWidth: Boolean,
    onSignOut: () -> Unit,
    composeNew: () -> Unit,
    openCompose: (String) -> Unit,
) {
    NavHost(navController = navController, startDestination = "folders") {
        composable("folders") {
            val viewModel: FoldersViewModel =
                viewModel(factory = FoldersViewModel.factory(container))
            val state by viewModel.state.collectAsState()
            val preferences by container.preferences.preferences.collectAsState()
            FolderListScreen(
                state = state,
                countDisplay = preferences.folderCountDisplay,
                onRefresh = viewModel::refresh,
                onPoll = viewModel::poll,
                onOpenFolder = { folder ->
                    navController.navigate("messages/${Uri.encode(folder)}")
                },
                onOpenSearch = { navController.navigate("search") },
                onEmptyTrash = viewModel::emptyTrash,
                onCompose = composeNew,
            )
        }

        composable(
            route = "messages/{folder}?uid={uid}",
            arguments =
                listOf(
                    navArgument("folder") { type = NavType.StringType },
                    // A message to preselect in the detail pane on wide
                    // windows (resume cursor); ignored on phones.
                    navArgument("uid") {
                        type = NavType.LongType
                        defaultValue = -1L
                    },
                ),
        ) { entry ->
            val folder = Uri.decode(entry.arguments?.getString("folder").orEmpty())
            val initialUid = entry.arguments?.getLong("uid")?.takeIf { it > 0 }
            val viewModel: MessageListViewModel =
                viewModel(factory = MessageListViewModel.factory(container, folder))
            val state by viewModel.state.collectAsState()
            if (compactWidth) {
                val config by container.configService.config.collectAsState()
                MessageListScreen(
                    folder = folder,
                    state = state,
                    viewModel = viewModel,
                    bimiLookup = container.bimiLookup,
                    mailDomains = config?.mailDomains.orEmpty(),
                    onOpenMessage = { envelope ->
                        navController.navigate("message/${Uri.encode(folder)}/${envelope.id}")
                    },
                    onOpenSearch = { navController.navigate("search?folder=${Uri.encode(folder)}") },
                    onBack = { navController.popBackStack() },
                    onCompose = composeNew,
                )
            } else {
                // Tablet / foldable (plan §7.2): list | detail side by side.
                MailListDetailScreen(
                    container = container,
                    folder = folder,
                    listViewModel = viewModel,
                    listState = state,
                    initialUid = initialUid,
                    onOpenSearch = { navController.navigate("search?folder=${Uri.encode(folder)}") },
                    onBack = { navController.popBackStack() },
                    onCompose = composeNew,
                    openCompose = openCompose,
                )
            }
        }

        composable(
            route = "search?folder={folder}",
            arguments =
                listOf(
                    navArgument("folder") {
                        type = NavType.StringType
                        nullable = true
                        defaultValue = null
                    },
                ),
        ) { entry ->
            val folder = entry.arguments?.getString("folder")?.let(Uri::decode)
            val viewModel: SearchViewModel =
                viewModel(factory = SearchViewModel.factory(container, folder))
            val state by viewModel.state.collectAsState()
            val config by container.configService.config.collectAsState()
            SearchScreen(
                state = state,
                viewModel = viewModel,
                bimiLookup = container.bimiLookup,
                mailDomains = config?.mailDomains.orEmpty(),
                onOpenMessage = { envelope ->
                    // Search rows carry their source folder; route there.
                    envelope.folder?.let { source ->
                        navController.navigate("message/${Uri.encode(source)}/${envelope.id}")
                    }
                },
                onBack = { navController.popBackStack() },
            )
        }

        composable(
            route = "message/{folder}/{uid}",
            arguments =
                listOf(
                    navArgument("folder") { type = NavType.StringType },
                    navArgument("uid") { type = NavType.LongType },
                ),
        ) { entry ->
            val folder = Uri.decode(entry.arguments?.getString("folder").orEmpty())
            val uid = entry.arguments?.getLong("uid") ?: 0L
            val viewModel: MessageDetailViewModel =
                viewModel(factory = MessageDetailViewModel.factory(container, folder, uid))
            val state by viewModel.state.collectAsState()
            // The list entry below owns the window the after-dispose advance
            // walks; a reader opened from search (or a mismatched folder)
            // has no such context and disposes fall back to popping.
            val listEntry =
                remember(entry) {
                    runCatching {
                        navController.getBackStackEntry("messages/{folder}?uid={uid}")
                    }.getOrNull()?.takeIf { candidate ->
                        Uri.decode(candidate.arguments?.getString("folder").orEmpty()) == folder
                    }
                }
            val listViewModel: MessageListViewModel? =
                listEntry?.let { owner ->
                    viewModel(
                        viewModelStoreOwner = owner,
                        factory = MessageListViewModel.factory(container, folder),
                    )
                }
            MessageDetailScreen(
                state = state,
                viewModel = viewModel,
                bimiLookup = container.bimiLookup,
                onBack = { navController.popBackStack() },
                onCompose = { draftId, replaceMessage ->
                    if (replaceMessage) {
                        navController.popBackStack()
                    }
                    openCompose(draftId)
                },
                computeAdvance =
                    listViewModel?.let { list ->
                        { disposedUid, advance ->
                            disposeAdvanceTarget(list.state.value.filteredRows, disposedUid, advance)?.id
                        }
                    },
                onOpenMessage = { target ->
                    navController.navigate("message/${Uri.encode(folder)}/$target") {
                        popUpTo("message/{folder}/{uid}") { inclusive = true }
                    }
                },
            )
        }

        composable("addresses") {
            val viewModel: AddressesViewModel =
                viewModel(factory = AddressesViewModel.factory(container))
            val state by viewModel.state.collectAsState()
            AddressesScreen(state = state, viewModel = viewModel, onBack = null)
        }

        composable("folders_admin") {
            val viewModel: FoldersAdminViewModel =
                viewModel(factory = FoldersAdminViewModel.factory(container))
            val state by viewModel.state.collectAsState()
            FoldersAdminScreen(state = state, viewModel = viewModel, onBack = null)
        }

        composable("settings") {
            val viewModel: SettingsViewModel =
                viewModel(factory = SettingsViewModel.factory(container))
            val state by viewModel.state.collectAsState()
            val preferences by viewModel.preferences.collectAsState()
            val folderChoices by viewModel.folderChoices.collectAsState()
            SettingsScreen(
                state = state,
                preferences = preferences,
                onUpdate = viewModel::update,
                onPushChange = { enabled ->
                    if (enabled) viewModel.registerPush() else viewModel.deregisterPush()
                },
                folderChoices = folderChoices,
                onLoadFolderChoices = viewModel::loadFolderChoices,
                onPushFoldersChange = viewModel::updatePushFolders,
                onSignOut = onSignOut,
                onBack = null,
            )
        }

        composable(
            route = "compose/{draftId}",
            arguments = listOf(navArgument("draftId") { type = NavType.StringType }),
        ) { entry ->
            val draftId = entry.arguments?.getString("draftId").orEmpty()
            val viewModel: ComposeViewModel =
                viewModel(factory = ComposeViewModel.factory(container, draftId))
            val state by viewModel.state.collectAsState()
            ComposeScreen(
                state = state,
                viewModel = viewModel,
                onDismiss = { navController.popBackStack() },
            )
        }
    }
}

/**
 * Builds the back stack a stored cursor points at: folder → message on a
 * phone; on wide windows the list-detail view with the message selected.
 */
private fun NavHostController.openCursor(
    state: NavState,
    compactWidth: Boolean,
) {
    val folder = state.folder ?: return
    val uid = state.uid?.takeIf { it > 0 }
    // singleTop: the target list may already be on top (the INBOX launch
    // view, or the list the user is looking at) — reuse it rather than
    // stacking a duplicate.
    if (!compactWidth && uid != null) {
        navigate("messages/${Uri.encode(folder)}?uid=$uid") { launchSingleTop = true }
        return
    }
    navigate("messages/${Uri.encode(folder)}") { launchSingleTop = true }
    if (uid != null) {
        navigate("message/${Uri.encode(folder)}/$uid")
    }
}
