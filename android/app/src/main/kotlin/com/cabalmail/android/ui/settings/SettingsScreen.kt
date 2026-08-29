package com.cabalmail.android.ui.settings

import android.content.Intent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.adaptive.ExperimentalMaterial3AdaptiveApi
import androidx.compose.material3.adaptive.layout.AnimatedPane
import androidx.compose.material3.adaptive.layout.ListDetailPaneScaffoldRole
import androidx.compose.material3.adaptive.layout.PaneAdaptedValue
import androidx.compose.material3.adaptive.navigation.NavigableListDetailPaneScaffold
import androidx.compose.material3.adaptive.navigation.rememberListDetailPaneScaffoldNavigator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.core.net.toUri
import com.cabalmail.android.BuildConfig
import com.cabalmail.android.R
import com.cabalmail.kit.settings.Accent
import com.cabalmail.kit.settings.AppPreferences
import com.cabalmail.kit.settings.AppTheme
import com.cabalmail.kit.settings.BodyRenderMode
import com.cabalmail.kit.settings.DefaultSort
import com.cabalmail.kit.settings.Density
import com.cabalmail.kit.settings.DisposeAction
import com.cabalmail.kit.settings.DisposeAdvance
import com.cabalmail.kit.settings.FolderCountDisplay
import com.cabalmail.kit.settings.LoadRemoteContent
import com.cabalmail.kit.settings.MarkAsRead
import kotlinx.coroutines.launch

private const val ISSUES_URL = "https://github.com/cabalmail/cabal-infra/issues"

/** The selectable settings categories, in presentation order. */
enum class SettingsCategory(
    val titleRes: Int,
) {
    ACCOUNT(R.string.settings_account),
    READING(R.string.settings_reading),
    COMPOSING(R.string.settings_composing),
    RULES(R.string.rules_title),
    FLAGS(R.string.settings_flags),
    ACTIONS(R.string.settings_actions),
    NOTIFICATIONS(R.string.settings_notifications),
    APPEARANCE(R.string.settings_appearance),
    ABOUT(R.string.settings_about),
}

/**
 * Settings (plan §6.3), System-Settings style: the categories are a
 * selectable list in a [NavigableListDetailPaneScaffold] — side by side
 * with the selected category's options on wide windows, a full-screen list
 * that drills into each category on phones (system back / the top-bar
 * arrow return to the list). Rules is a category like any other; its
 * detail pane is the rules experience itself, supplied by the nav host so
 * this screen stays unaware of the rules view model and editor routes.
 * Every change writes through the preference repository (DataStore now,
 * server on a short debounce).
 */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
@Composable
fun SettingsScreen(
    state: SettingsUiState,
    preferences: AppPreferences,
    onUpdate: ((AppPreferences) -> AppPreferences) -> Unit,
    /** Push (de)registration when the notifications toggle changes. */
    onPushChange: (Boolean) -> Unit,
    /** Folder names for the push-folders picker; null until loaded. */
    folderChoices: List<String>?,
    onLoadFolderChoices: () -> Unit,
    onPushFoldersChange: (Set<String>) -> Unit,
    /**
     * The Rules category's detail pane (`docs/1.x/user-mail-rules-plan.md`
     * 4b). `onBack` is null when the category list is visible alongside.
     */
    rulesPane: @Composable (onBack: (() -> Unit)?) -> Unit,
    onSignOut: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    val navigator = rememberListDetailPaneScaffoldNavigator<SettingsCategory>()
    val twoPane =
        navigator.scaffoldValue[ListDetailPaneScaffoldRole.List] == PaneAdaptedValue.Expanded &&
            navigator.scaffoldValue[ListDetailPaneScaffoldRole.Detail] == PaneAdaptedValue.Expanded

    // Wide windows land on the first category instead of an empty detail
    // pane; on phones the list is the whole screen and nothing preselects.
    LaunchedEffect(twoPane) {
        if (twoPane && navigator.currentDestination?.contentKey == null) {
            navigator.navigateTo(ListDetailPaneScaffoldRole.Detail, SettingsCategory.ACCOUNT)
        }
    }

    NavigableListDetailPaneScaffold(
        navigator = navigator,
        modifier = modifier.fillMaxSize(),
        listPane = {
            AnimatedPane {
                SettingsCategoryList(
                    selected = navigator.currentDestination?.contentKey.takeIf { twoPane },
                    onSelect = { category ->
                        scope.launch { navigator.navigateTo(ListDetailPaneScaffoldRole.Detail, category) }
                    },
                )
            }
        },
        detailPane = {
            AnimatedPane {
                val category = navigator.currentDestination?.contentKey
                val onBack: (() -> Unit)? =
                    if (twoPane) null else ({ scope.launch { navigator.navigateBack() } })
                when (category) {
                    // Only visible in the wide layout for the frame before
                    // the auto-select above lands.
                    null -> Unit
                    SettingsCategory.RULES -> rulesPane(onBack)
                    else ->
                        SettingsCategoryDetail(
                            category = category,
                            state = state,
                            preferences = preferences,
                            onUpdate = onUpdate,
                            onPushChange = onPushChange,
                            folderChoices = folderChoices,
                            onLoadFolderChoices = onLoadFolderChoices,
                            onPushFoldersChange = onPushFoldersChange,
                            onSignOut = onSignOut,
                            onBack = onBack,
                        )
                }
            }
        },
    )
}

/** The category list pane: a top-level destination, so no back arrow. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SettingsCategoryList(
    selected: SettingsCategory?,
    onSelect: (SettingsCategory) -> Unit,
) {
    Scaffold(
        modifier = Modifier.fillMaxSize(),
        topBar = { TopAppBar(title = { Text(stringResource(R.string.settings_title)) }) },
    ) { innerPadding ->
        Column(
            modifier =
                Modifier
                    .padding(innerPadding)
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState()),
        ) {
            SettingsCategory.entries.forEach { category ->
                ListItem(
                    headlineContent = { Text(stringResource(category.titleRes)) },
                    colors =
                        ListItemDefaults.colors(
                            containerColor =
                                if (category == selected) {
                                    MaterialTheme.colorScheme.secondaryContainer
                                } else {
                                    MaterialTheme.colorScheme.surface
                                },
                        ),
                    modifier = Modifier.clickable { onSelect(category) },
                )
                HorizontalDivider()
            }
        }
    }
}

/** One category's options: its own top bar (back arrow when collapsed). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SettingsCategoryDetail(
    category: SettingsCategory,
    state: SettingsUiState,
    preferences: AppPreferences,
    onUpdate: ((AppPreferences) -> AppPreferences) -> Unit,
    onPushChange: (Boolean) -> Unit,
    folderChoices: List<String>?,
    onLoadFolderChoices: () -> Unit,
    onPushFoldersChange: (Set<String>) -> Unit,
    onSignOut: () -> Unit,
    onBack: (() -> Unit)?,
) {
    Scaffold(
        modifier = Modifier.fillMaxSize(),
        topBar = {
            TopAppBar(
                title = { Text(stringResource(category.titleRes)) },
                navigationIcon = {
                    if (onBack != null) {
                        IconButton(onClick = onBack) {
                            Icon(
                                Icons.AutoMirrored.Filled.ArrowBack,
                                contentDescription = stringResource(R.string.back),
                            )
                        }
                    }
                },
            )
        },
    ) { innerPadding ->
        Column(
            modifier =
                Modifier
                    .padding(innerPadding)
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState()),
        ) {
            when (category) {
                SettingsCategory.ACCOUNT -> AccountSettings(state, preferences, onUpdate, onSignOut)
                SettingsCategory.READING -> ReadingSettings(preferences, onUpdate)
                SettingsCategory.COMPOSING -> ComposingSettings(state, preferences, onUpdate)
                // Handled by the caller (the pane comes from the nav host).
                SettingsCategory.RULES -> Unit
                SettingsCategory.FLAGS -> FlagPaletteSettings(preferences, onUpdate)
                SettingsCategory.ACTIONS -> ActionsSettings(preferences, onUpdate)
                SettingsCategory.NOTIFICATIONS ->
                    NotificationsSettings(
                        preferences = preferences,
                        onUpdate = onUpdate,
                        onPushChange = onPushChange,
                        folderChoices = folderChoices,
                        onLoadFolderChoices = onLoadFolderChoices,
                        onPushFoldersChange = onPushFoldersChange,
                    )
                SettingsCategory.APPEARANCE -> AppearanceSettings(preferences, onUpdate)
                SettingsCategory.ABOUT -> AboutSettings()
            }
        }
    }
}

// ---------------------------------------------------------- categories

@Composable
private fun AccountSettings(
    state: SettingsUiState,
    preferences: AppPreferences,
    onUpdate: ((AppPreferences) -> AppPreferences) -> Unit,
    onSignOut: () -> Unit,
) {
    ListItem(
        headlineContent = { Text(state.username ?: "") },
        supportingContent = { Text(stringResource(R.string.settings_signed_in_as)) },
    )
    ListItem(
        headlineContent = { Text(state.controlDomain ?: "") },
        supportingContent = { Text(stringResource(R.string.settings_server)) },
    )
    TextRow(
        title = stringResource(R.string.settings_display_name),
        value = preferences.displayName,
        empty = stringResource(R.string.settings_display_name_empty),
        singleLine = true,
        onChange = { name -> onUpdate { it.copy(displayName = name.trim()) } },
    )
    ListItem(
        headlineContent = { Text(stringResource(R.string.sign_out), color = MaterialTheme.colorScheme.error) },
        modifier = Modifier.clickable(onClick = onSignOut),
    )
}

@Composable
private fun ReadingSettings(
    preferences: AppPreferences,
    onUpdate: ((AppPreferences) -> AppPreferences) -> Unit,
) {
    EnumRow(
        title = stringResource(R.string.settings_mark_as_read),
        value = preferences.markAsRead,
        options = MarkAsRead.entries,
        label = { it.label() },
        onSelect = { value -> onUpdate { it.copy(markAsRead = value) } },
    )
    EnumRow(
        title = stringResource(R.string.settings_load_remote_content),
        value = preferences.loadRemoteContent,
        options = LoadRemoteContent.entries,
        label = { it.label() },
        onSelect = { value -> onUpdate { it.copy(loadRemoteContent = value) } },
    )
    EnumRow(
        title = stringResource(R.string.settings_render_mode),
        value = preferences.bodyRenderMode,
        options = BodyRenderMode.entries,
        label = { it.label() },
        onSelect = { value -> onUpdate { it.copy(bodyRenderMode = value) } },
    )
    EnumRow(
        title = stringResource(R.string.settings_folder_count),
        value = preferences.folderCountDisplay,
        options = FolderCountDisplay.entries,
        label = { it.label() },
        onSelect = { value -> onUpdate { it.copy(folderCountDisplay = value) } },
    )
    EnumRow(
        title = stringResource(R.string.settings_default_sort),
        value = preferences.defaultSort,
        options = DefaultSort.entries,
        label = { it.label() },
        onSelect = { value -> onUpdate { it.copy(defaultSort = value) } },
    )
    ToggleRow(
        title = stringResource(R.string.sort_descending),
        checked = preferences.defaultSortDescending,
        onChange = { value -> onUpdate { it.copy(defaultSortDescending = value) } },
    )
}

@Composable
private fun ComposingSettings(
    state: SettingsUiState,
    preferences: AppPreferences,
    onUpdate: ((AppPreferences) -> AppPreferences) -> Unit,
) {
    DefaultFromRow(
        value = preferences.defaultFromAddress,
        addresses = state.addresses?.map { it.address }.orEmpty(),
        onSelect = { value -> onUpdate { it.copy(defaultFromAddress = value) } },
    )
    TextRow(
        title = stringResource(R.string.settings_signature),
        value = preferences.signature,
        empty = stringResource(R.string.settings_signature_empty),
        singleLine = false,
        onChange = { signature -> onUpdate { it.copy(signature = signature) } },
    )
}

@Composable
private fun ActionsSettings(
    preferences: AppPreferences,
    onUpdate: ((AppPreferences) -> AppPreferences) -> Unit,
) {
    EnumRow(
        title = stringResource(R.string.settings_dispose_action),
        value = preferences.disposeAction,
        options = DisposeAction.entries,
        label = { it.label() },
        onSelect = { value -> onUpdate { it.copy(disposeAction = value) } },
    )
    EnumRow(
        title = stringResource(R.string.settings_dispose_advance),
        value = preferences.disposeAdvance,
        options = DisposeAdvance.entries,
        label = { it.label() },
        onSelect = { value -> onUpdate { it.copy(disposeAdvance = value) } },
    )
}

@Composable
private fun NotificationsSettings(
    preferences: AppPreferences,
    onUpdate: ((AppPreferences) -> AppPreferences) -> Unit,
    onPushChange: (Boolean) -> Unit,
    folderChoices: List<String>?,
    onLoadFolderChoices: () -> Unit,
    onPushFoldersChange: (Set<String>) -> Unit,
) {
    NotificationsRow(
        enabled = preferences.notificationsEnabled,
        onChange = { value -> onUpdate { it.copy(notificationsEnabled = value) } },
        onPushChange = onPushChange,
    )
    PushFoldersRow(
        pushFolders = preferences.pushFolders,
        enabled = preferences.notificationsEnabled,
        folderChoices = folderChoices,
        onLoadFolderChoices = onLoadFolderChoices,
        onChange = onPushFoldersChange,
    )
}

@Composable
private fun AppearanceSettings(
    preferences: AppPreferences,
    onUpdate: ((AppPreferences) -> AppPreferences) -> Unit,
) {
    EnumRow(
        title = stringResource(R.string.settings_theme),
        value = preferences.theme,
        options = AppTheme.entries,
        label = { it.label() },
        onSelect = { value -> onUpdate { it.copy(theme = value) } },
    )
    ToggleRow(
        title = stringResource(R.string.settings_dynamic_color),
        checked = preferences.dynamicColor,
        onChange = { value -> onUpdate { it.copy(dynamicColor = value) } },
        supporting = stringResource(R.string.settings_dynamic_color_hint),
    )
    EnumRow(
        title = stringResource(R.string.settings_accent),
        value = preferences.accent,
        options = Accent.entries,
        label = { it.label() },
        enabled = !preferences.dynamicColor,
        onSelect = { value -> onUpdate { it.copy(accent = value) } },
    )
    EnumRow(
        title = stringResource(R.string.settings_density),
        value = preferences.density,
        options = Density.entries,
        label = { it.label() },
        onSelect = { value -> onUpdate { it.copy(density = value) } },
    )
}

@Composable
private fun AboutSettings() {
    val context = LocalContext.current
    ListItem(
        headlineContent = { Text(stringResource(R.string.settings_version)) },
        supportingContent = { Text("${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})") },
    )
    ListItem(
        headlineContent = { Text(stringResource(R.string.settings_report_issue)) },
        supportingContent = { Text(ISSUES_URL) },
        modifier =
            Modifier.clickable {
                runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, ISSUES_URL.toUri())) }
            },
    )
}
