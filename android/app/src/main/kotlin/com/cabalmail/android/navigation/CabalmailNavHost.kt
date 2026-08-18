package com.cabalmail.android.navigation

import android.net.Uri
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.cabalmail.android.AppContainer
import com.cabalmail.android.ui.compose.ComposeLaunch
import com.cabalmail.android.ui.compose.ComposeScreen
import com.cabalmail.android.ui.compose.ComposeViewModel
import com.cabalmail.android.ui.mail.FolderListScreen
import com.cabalmail.android.ui.mail.FoldersViewModel
import com.cabalmail.android.ui.mail.MessageDetailScreen
import com.cabalmail.android.ui.mail.MessageDetailViewModel
import com.cabalmail.android.ui.mail.MessageListScreen
import com.cabalmail.android.ui.mail.MessageListViewModel
import com.cabalmail.android.ui.mail.SearchScreen
import com.cabalmail.android.ui.mail.SearchViewModel
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
        scope.launch { openCompose(ComposeLaunch.stage(container, ComposeLaunch.blank())) }
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
    // cursor — never opened unbidden.
    var localDraftPrompt by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        localDraftPrompt = container.draftStore.list().firstOrNull { !it.isEmpty }?.id
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

    NavHost(navController = navController, startDestination = "folders") {
        composable("folders") {
            val viewModel: FoldersViewModel =
                viewModel(factory = FoldersViewModel.factory(container))
            val state by viewModel.state.collectAsState()
            FolderListScreen(
                state = state,
                onRefresh = viewModel::refresh,
                onOpenFolder = { folder ->
                    navController.navigate("messages/${Uri.encode(folder)}")
                },
                onOpenSearch = { navController.navigate("search") },
                onEmptyTrash = viewModel::emptyTrash,
                onSignOut = onSignOut,
                onCompose = composeNew,
                resumeAvailable = resumePrompt != null,
                onResume = {
                    resumePrompt?.let(navController::openCursor)
                    resumePrompt = null
                },
                onResumeDismiss = { resumePrompt = null },
                localDraftAvailable = localDraftPrompt != null,
                onOpenLocalDraft = {
                    localDraftPrompt?.let(openCompose)
                    localDraftPrompt = null
                },
                onLocalDraftDismiss = { localDraftPrompt = null },
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
                onCompose = openCompose,
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
