package com.cabalmail.android

import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.nativeKeyCode
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.lifecycle.viewmodel.compose.viewModel
import com.cabalmail.android.navigation.CabalmailNavHost
import com.cabalmail.android.ui.auth.AuthPhase
import com.cabalmail.android.ui.auth.SignInScreen
import com.cabalmail.android.ui.auth.SignInUiState
import com.cabalmail.android.ui.auth.SignInViewModel
import com.cabalmail.android.ui.theme.CabalmailTheme
import com.cabalmail.android.ui.theme.resolvesDark

class MainActivity : ComponentActivity() {
    private val container: AppContainer get() = (application as CabalmailApp).container

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        // Share-target intake (plan §5.4). Only on a fresh create: a
        // configuration change redelivers the same intent, and the share
        // must compose exactly once.
        if (savedInstanceState == null) {
            container.shareIntake.offer(intent)
            container.openIntake.offer(intent)
        }
        setContent {
            val preferences by container.preferences.preferences.collectAsState()
            // System bars follow the resolved app theme, not just the platform
            // setting, so a forced Light theme gets dark status-bar icons.
            val dark = preferences.resolvesDark(isSystemInDarkTheme())
            DisposableEffect(dark) {
                val style =
                    if (dark) {
                        SystemBarStyle.dark(Color.TRANSPARENT)
                    } else {
                        SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT)
                    }
                enableEdgeToEdge(statusBarStyle = style, navigationBarStyle = style)
                onDispose {}
            }
            CabalmailTheme(preferences = preferences) {
                val viewModel: SignInViewModel =
                    viewModel(factory = SignInViewModel.factory(container))
                val state by viewModel.state.collectAsState()
                // Ctrl chords (plan §7.2): previewed at the root so they win
                // over whatever has focus; onKeyDown below covers the
                // nothing-focused case.
                Box(
                    modifier =
                        Modifier.onPreviewKeyEvent { event ->
                            event.type == KeyEventType.KeyDown &&
                                container.shortcuts.dispatch(
                                    keyCode = event.key.nativeKeyCode,
                                    ctrl = event.isCtrlPressed,
                                    shift = event.isShiftPressed,
                                )
                        },
                ) {
                    Root(state = state, viewModel = viewModel)
                }
            }
        }
    }

    @Composable
    private fun Root(
        state: SignInUiState,
        viewModel: SignInViewModel,
    ) {
        when (state.phase) {
            is AuthPhase.SignedIn ->
                CabalmailNavHost(
                    container = container,
                    onSignOut = viewModel::signOut,
                )

            else ->
                SignInScreen(
                    state = state,
                    onSignIn = viewModel::signIn,
                    onSubmitMfaCode = viewModel::submitMfaCode,
                )
        }
    }

    /** Fallback for chords when nothing in Compose holds focus. */
    override fun onKeyDown(
        keyCode: Int,
        event: KeyEvent,
    ): Boolean = container.shortcuts.dispatch(event) || super.onKeyDown(keyCode, event)

    /** `singleTop` relaunches (a share while already open) arrive here. */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        container.shareIntake.offer(intent)
        container.openIntake.offer(intent)
    }
}
