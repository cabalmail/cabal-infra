package com.cabalmail.android.navigation

import android.net.Uri
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.cabalmail.android.AppContainer
import com.cabalmail.android.R
import com.cabalmail.android.ui.addresses.AddressesScreen
import com.cabalmail.android.ui.addresses.AddressesViewModel
import com.cabalmail.android.ui.compose.ComposeLaunch
import com.cabalmail.android.ui.compose.ComposeScreen
import com.cabalmail.android.ui.compose.ComposeViewModel
import com.cabalmail.android.ui.folders.FoldersAdminScreen
import com.cabalmail.android.ui.folders.FoldersAdminViewModel
import com.cabalmail.android.ui.mail.FolderListScreen
import com.cabalmail.android.ui.mail.FoldersViewModel
import com.cabalmail.android.ui.mail.MessageDetailScreen
import com.cabalmail.android.ui.mail.MessageDetailViewModel
import com.cabalmail.android.ui.mail.MessageListScreen
import com.cabalmail.android.ui.mail.MessageListViewModel
import com.cabalmail.android.ui.mail.SearchScreen
import com.cabalmail.android.ui.mail.SearchViewModel
import com.cabalmail.android.ui.settings.SettingsScreen
import com.cabalmail.android.ui.settings.SettingsViewModel
import com.cabalmail.kit.models.NavState
import kotlinx.coroutines.launch

/**
 * Phone navigation graph for the mail flow. Folder paths ride as encoded
 * route arguments (they may contain `/`). Adaptive two-pane layouts arrive
 * with the tablet work (Phase 7).
 */
@Composable
fun CabalmailNavHost(
    container: AppContainer,
    onSignOut: () -> Unit,
) {
    val navController = rememberNavController()
    val scope = rememberCoroutineScope()

    // Every compose entry stages a seed draft in the local buffer first and
    // navigates by id (see ComposeLaunch).
    val openCompose: (String) -> Unit = { draftId -> navController.navigate("compose/$draftId") }
    val composeNew: () -> Unit = {
        scope.launch { openCompose(ComposeLaunch.stage(container, ComposeLaunch.blank(container))) }
    }

    // Preferences (plan §6.3): the synced subset is re-pulled on every
    // launch so web/Apple changes apply here (server wins).
    LaunchedEffect(Unit) { container.preferences.refreshFromServer() }

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
        container.draftStore.pruneEmpty()
        val draftId = container.draftStore.list().firstOrNull()?.id ?: return@LaunchedEffect
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

    // Resume cursor (plan §4.5): a cursor this install wrote restores
    // silently; one from another device only offers a prompt on the folder
    // list, so launch never yanks the user somewhere unexpected.
    var resumePrompt by remember { mutableStateOf<NavState?>(null) }
    LaunchedEffect(Unit) {
        val cursor = container.navCursor.restoreOnce() ?: return@LaunchedEffect
        if (cursor.local) {
            navController.openCursor(cursor.state)
        } else {
            resumePrompt = cursor.state
        }
    }

    Box(modifier = Modifier.fillMaxSize()) {
        MailNavGraph(
            navController = navController,
            container = container,
            onSignOut = onSignOut,
            resumePrompt = resumePrompt,
            onResumeConsumed = { resumePrompt = null },
            composeNew = composeNew,
            openCompose = openCompose,
        )
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

@Composable
private fun MailNavGraph(
    navController: NavHostController,
    container: AppContainer,
    onSignOut: () -> Unit,
    resumePrompt: NavState?,
    onResumeConsumed: () -> Unit,
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
                onOpenFolder = { folder ->
                    navController.navigate("messages/${Uri.encode(folder)}")
                },
                onOpenSearch = { navController.navigate("search") },
                onEmptyTrash = viewModel::emptyTrash,
                onSignOut = onSignOut,
                onCompose = composeNew,
                onOpenAddresses = { navController.navigate("addresses") },
                onOpenFolders = { navController.navigate("folders_admin") },
                onOpenSettings = { navController.navigate("settings") },
                resumeAvailable = resumePrompt != null,
                onResume = {
                    resumePrompt?.let(navController::openCursor)
                    onResumeConsumed()
                },
                onResumeDismiss = onResumeConsumed,
            )
        }

        composable(
            route = "messages/{folder}",
            arguments = listOf(navArgument("folder") { type = NavType.StringType }),
        ) { entry ->
            val folder = Uri.decode(entry.arguments?.getString("folder").orEmpty())
            val viewModel: MessageListViewModel =
                viewModel(factory = MessageListViewModel.factory(container, folder))
            val state by viewModel.state.collectAsState()
            MessageListScreen(
                folder = folder,
                state = state,
                viewModel = viewModel,
                bimiLookup = container.bimiLookup,
                onOpenMessage = { envelope ->
                    navController.navigate("message/${Uri.encode(folder)}/${envelope.id}")
                },
                onOpenSearch = { navController.navigate("search?folder=${Uri.encode(folder)}") },
                onBack = { navController.popBackStack() },
                onCompose = composeNew,
            )
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
            SearchScreen(
                state = state,
                viewModel = viewModel,
                bimiLookup = container.bimiLookup,
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
            )
        }

        composable("addresses") {
            val viewModel: AddressesViewModel =
                viewModel(factory = AddressesViewModel.factory(container))
            val state by viewModel.state.collectAsState()
            AddressesScreen(state = state, viewModel = viewModel, onBack = { navController.popBackStack() })
        }

        composable("folders_admin") {
            val viewModel: FoldersAdminViewModel =
                viewModel(factory = FoldersAdminViewModel.factory(container))
            val state by viewModel.state.collectAsState()
            FoldersAdminScreen(state = state, viewModel = viewModel, onBack = { navController.popBackStack() })
        }

        composable("settings") {
            val viewModel: SettingsViewModel =
                viewModel(factory = SettingsViewModel.factory(container))
            val state by viewModel.state.collectAsState()
            val preferences by viewModel.preferences.collectAsState()
            SettingsScreen(
                state = state,
                preferences = preferences,
                onUpdate = viewModel::update,
                onSignOut = onSignOut,
                onBack = { navController.popBackStack() },
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

/** Builds the folder → message back stack a stored cursor points at. */
private fun NavHostController.openCursor(state: NavState) {
    val folder = state.folder ?: return
    navigate("messages/${Uri.encode(folder)}")
    val uid = state.uid
    if (uid != null && uid > 0) {
        navigate("message/${Uri.encode(folder)}/$uid")
    }
}
