package com.cabalmail.android.ui.mail

import android.content.SharedPreferences
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.interaction.DragInteraction
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.width
import androidx.compose.material3.LocalMinimumInteractiveComponentSize
import androidx.compose.material3.VerticalDragHandle
import androidx.compose.material3.adaptive.ExperimentalMaterial3AdaptiveApi
import androidx.compose.material3.adaptive.layout.PaneExpansionState
import androidx.compose.material3.adaptive.layout.PaneExpansionStateKey
import androidx.compose.material3.adaptive.layout.ThreePaneScaffoldScope
import androidx.compose.material3.adaptive.layout.rememberPaneExpansionState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.PointerIcon
import androidx.compose.ui.input.pointer.pointerHoverIcon
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.coerceIn
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.max
import androidx.core.content.edit
import com.cabalmail.android.R

/** Narrowest the folder (or feed) pane can be dragged. */
internal val SIDE_PANE_MIN_WIDTH = 160.dp

/** Narrowest either message pane — the list or the reader — can be dragged. */
internal val MESSAGE_PANE_MIN_WIDTH = 220.dp

/** Width of the side pane's drag target, centred on its divider. */
private val SIDE_HANDLE_TOUCH_WIDTH = 24.dp

/** How far one accessibility widen / narrow action moves a divider. */
private val ACCESSIBILITY_RESIZE_STEP = 40.dp

/**
 * The side pane's width in a window [total] wide: what the user asked for,
 * held between [SIDE_PANE_MIN_WIDTH] and whatever leaves both message
 * panes [MESSAGE_PANE_MIN_WIDTH].
 */
internal fun clampSidePaneWidth(
    requested: Dp,
    total: Dp,
): Dp = requested.coerceIn(SIDE_PANE_MIN_WIDTH, max(SIDE_PANE_MIN_WIDTH, total - MESSAGE_PANE_MIN_WIDTH * 2))

/**
 * The list pane's width in a list-detail scaffold [scaffold] wide whose
 * panes are [spacer] apart: what the user asked for, leaving each pane at
 * least [MESSAGE_PANE_MIN_WIDTH]. The scaffold itself lets a pane be
 * dragged to nothing; this is what a drag settles back to.
 */
internal fun clampListPaneWidth(
    requested: Dp,
    scaffold: Dp,
    spacer: Dp,
): Dp =
    requested.coerceIn(
        MESSAGE_PANE_MIN_WIDTH,
        max(
            MESSAGE_PANE_MIN_WIDTH,
            scaffold - spacer - MESSAGE_PANE_MIN_WIDTH,
        ),
    )

/** Which list-detail screen a remembered width belongs to. */
enum class PaneLayoutScreen(
    internal val key: String,
) {
    MAIL("mail"),
    FEEDS("feeds"),
}

/**
 * The pane widths the user dragged to, per install and per screen. Window
 * layout is a property of the device, so nothing here is synced; the
 * stored value is the user's preference, and each window clamps it to fit
 * rather than overwriting it, so a narrower window does not lose it.
 */
class PaneWidths(
    private val prefs: SharedPreferences,
) {
    fun sidePane(screen: PaneLayoutScreen): Dp? = read("${screen.key}.side")

    fun setSidePane(
        screen: PaneLayoutScreen,
        width: Dp,
    ) = write("${screen.key}.side", width)

    fun listPane(screen: PaneLayoutScreen): Dp? = read("${screen.key}.list")

    fun setListPane(
        screen: PaneLayoutScreen,
        width: Dp,
    ) = write("${screen.key}.list", width)

    private fun read(key: String): Dp? = prefs.getFloat(key, 0f).takeIf { it > 0f }?.dp

    private fun write(
        key: String,
        width: Dp,
    ) = prefs.edit { putFloat(key, width.value) }
}

/** The leading side pane's width, and how a drag changes it. */
@Stable
internal class SidePaneWidth(
    private val store: PaneWidths,
    private val screen: PaneLayoutScreen,
    initial: Dp,
) {
    private var preferred by mutableStateOf(initial)
    internal var total by mutableStateOf(0.dp)

    /** The width to lay the side pane out at. */
    val width: Dp get() = clampSidePaneWidth(preferred, total)

    fun dragBy(delta: Dp) {
        preferred = clampSidePaneWidth(width + delta, total)
    }

    fun commit() = store.setSidePane(screen, width)
}

/** The side pane width for [screen] in a window [total] wide. */
@Composable
internal fun rememberSidePaneWidth(
    store: PaneWidths,
    screen: PaneLayoutScreen,
    total: Dp,
): SidePaneWidth {
    val state = remember(store, screen) { SidePaneWidth(store, screen, store.sidePane(screen) ?: FOLDER_PANE_WIDTH) }
    state.total = total
    return state
}

/**
 * The drag handle on the side pane's trailing divider, laid over it (not
 * beside it) so the panes keep their footprint. Place it in a [Box] that
 * starts where the side pane does.
 */
@Composable
internal fun SidePaneResizeHandle(
    state: SidePaneWidth,
    modifier: Modifier = Modifier,
) {
    val density = LocalDensity.current
    val interactionSource = remember { MutableInteractionSource() }
    val widen = stringResource(R.string.pane_resize_widen)
    val narrow = stringResource(R.string.pane_resize_narrow)
    Box(
        modifier =
            modifier
                .offset(x = state.width - SIDE_HANDLE_TOUCH_WIDTH / 2)
                .width(SIDE_HANDLE_TOUCH_WIDTH)
                .fillMaxHeight()
                .resizePointerIcon()
                .draggable(
                    state = rememberDraggableState { px -> state.dragBy(with(density) { px.toDp() }) },
                    orientation = Orientation.Horizontal,
                    interactionSource = interactionSource,
                    // A drag towards the trailing edge widens the leading pane.
                    reverseDirection = LocalLayoutDirection.current == LayoutDirection.Rtl,
                    onDragStopped = { state.commit() },
                ).semantics {
                    customActions =
                        listOf(
                            CustomAccessibilityAction(widen) {
                                state.dragBy(ACCESSIBILITY_RESIZE_STEP)
                                state.commit()
                                true
                            },
                            CustomAccessibilityAction(narrow) {
                                state.dragBy(-ACCESSIBILITY_RESIZE_STEP)
                                state.commit()
                                true
                            },
                        )
                },
        contentAlignment = Alignment.Center,
    ) {
        VerticalDragHandle(interactionSource = interactionSource)
    }
}

/**
 * The list pane's expansion in a list-detail scaffold: the state the
 * scaffold lays the list pane out from, seeded from the stored width, and
 * what [ListDetailDragHandle] reports drags through. [listWidthPx] is the
 * list pane's measured width — the scaffold does not expose the width a
 * drag left behind, so the list pane reports it.
 */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
@Stable
internal class ListPaneExpansion(
    val state: PaneExpansionState,
    val interactionSource: MutableInteractionSource,
) {
    var listWidthPx by mutableIntStateOf(0)
}

/**
 * The list pane's expansion for [screen] in a scaffold [scaffold] wide
 * with panes [spacer] apart. The stored width is applied (clamped) on
 * first composition and whenever the scaffold's width changes; a drag that
 * ends is clamped, applied and stored.
 */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
@Composable
internal fun rememberListPaneExpansion(
    store: PaneWidths,
    screen: PaneLayoutScreen,
    scaffold: Dp,
    spacer: Dp,
): ListPaneExpansion {
    val density = LocalDensity.current
    val state = rememberPaneExpansionState(PaneExpansionStateKey.Default)
    val expansion = remember(state) { ListPaneExpansion(state, MutableInteractionSource()) }
    var preferred by remember(store, screen) { mutableStateOf(store.listPane(screen)) }
    val targetPx = preferred?.let { with(density) { clampListPaneWidth(it, scaffold, spacer).roundToPx() } }
    // Applied during composition, ahead of the scaffold that reads it, so the
    // first frame is already at the stored width rather than jumping to it;
    // keyed so it runs once per target, not on every recomposition.
    remember(state, targetPx) { targetPx?.also(state::setFirstPaneWidth) }
    val currentScaffold by rememberUpdatedState(scaffold)
    val currentSpacer by rememberUpdatedState(spacer)
    LaunchedEffect(expansion) {
        expansion.interactionSource.interactions.collect { interaction ->
            if (interaction is DragInteraction.Stop || interaction is DragInteraction.Cancel) {
                // Let the last drag delta reach layout before reading the width.
                withFrameNanos { }
                val dragged = with(density) { expansion.listWidthPx.toDp() }
                val width = clampListPaneWidth(dragged, currentScaffold, currentSpacer)
                state.setFirstPaneWidth(with(density) { width.roundToPx() })
                preferred = width
                store.setListPane(screen, width)
            }
        }
    }
    return expansion
}

/** The scaffold's `paneExpansionDragHandle`: the handle between list and reader. */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
@Composable
internal fun ThreePaneScaffoldScope.ListDetailDragHandle(
    state: PaneExpansionState,
    interactionSource: MutableInteractionSource,
) {
    VerticalDragHandle(
        modifier =
            Modifier
                .paneExpansionDraggable(state, LocalMinimumInteractiveComponentSize.current, interactionSource)
                .resizePointerIcon(),
        interactionSource = interactionSource,
    )
}

/** The left-right resize cursor, for a mouse or trackpad over a handle. */
@Composable
private fun Modifier.resizePointerIcon(): Modifier {
    val context = LocalContext.current
    val icon =
        remember(context) {
            PointerIcon(
                android.view.PointerIcon.getSystemIcon(context, android.view.PointerIcon.TYPE_HORIZONTAL_DOUBLE_ARROW),
            )
        }
    return pointerHoverIcon(icon)
}
