package com.cabalmail.android.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext

/**
 * Material 3 theme seeded from the wallpaper (Material You). The API 31 floor
 * guarantees dynamic color is available, so there is no static fallback yet;
 * the Phase 6 "Dynamic color" setting introduces the shared Accent seed as the
 * alternative.
 */
@Composable
fun CabalmailTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    val context = LocalContext.current
    val colorScheme =
        if (darkTheme) {
            dynamicDarkColorScheme(context)
        } else {
            dynamicLightColorScheme(context)
        }
    MaterialTheme(
        colorScheme = colorScheme,
        content = content,
    )
}
