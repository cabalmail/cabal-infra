package com.cabalmail.android

import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.lifecycle.viewmodel.compose.viewModel
import com.cabalmail.android.navigation.CabalmailNavHost
import com.cabalmail.android.ui.auth.AuthPhase
import com.cabalmail.android.ui.auth.SignInScreen
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
        }
    }

    /** `singleTop` relaunches (a share while already open) arrive here. */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        container.shareIntake.offer(intent)
    }
}
