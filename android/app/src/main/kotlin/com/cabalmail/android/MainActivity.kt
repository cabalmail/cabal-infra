package com.cabalmail.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.cabalmail.android.ui.HelloScreen
import com.cabalmail.android.ui.theme.CabalmailTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            CabalmailTheme {
                HelloScreen()
            }
        }
    }
}
