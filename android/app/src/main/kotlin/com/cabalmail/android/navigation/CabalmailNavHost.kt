package com.cabalmail.android.navigation

import android.net.Uri
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.cabalmail.android.AppContainer
import com.cabalmail.android.ui.mail.FolderListScreen
import com.cabalmail.android.ui.mail.FoldersViewModel
import com.cabalmail.android.ui.mail.MessageDetailScreen
import com.cabalmail.android.ui.mail.MessageDetailViewModel
import com.cabalmail.android.ui.mail.MessageListScreen
import com.cabalmail.android.ui.mail.MessageListViewModel

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
                onSignOut = onSignOut,
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
                onRefresh = viewModel::refresh,
                onVisibleRange = viewModel::onVisibleRange,
                onOpenMessage = { envelope ->
                    navController.navigate("message/${Uri.encode(folder)}/${envelope.id}")
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
                isTrashFolder = viewModel.isTrashFolder,
                onToggleSeen = {
                    viewModel.setFlag("\\Seen", state.envelope?.isSeen != true)
                },
                onToggleFlag = {
                    viewModel.setFlag("\\Flagged", state.envelope?.isFlagged != true)
                },
                onDispose = viewModel::dispose,
                onAllowRemoteContent = viewModel::allowRemoteContent,
                onBack = { navController.popBackStack() },
            )
        }
    }
}
