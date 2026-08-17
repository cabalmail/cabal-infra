package com.cabalmail.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.lifecycle.viewmodel.compose.viewModel
import com.cabalmail.android.ui.auth.AuthPhase
import com.cabalmail.android.ui.auth.SignInScreen
import com.cabalmail.android.ui.auth.SignInViewModel
import com.cabalmail.android.ui.auth.SignedInScreen
import com.cabalmail.android.ui.theme.CabalmailTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val container = (application as CabalmailApp).container
        setContent {
            CabalmailTheme {
                val viewModel: SignInViewModel =
                    viewModel(factory = SignInViewModel.factory(container))
                val state by viewModel.state.collectAsState()
                when (val phase = state.phase) {
                    is AuthPhase.SignedIn ->
                        SignedInScreen(
                            username = phase.username,
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
}
