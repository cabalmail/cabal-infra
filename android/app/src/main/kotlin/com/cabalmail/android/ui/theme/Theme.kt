package com.cabalmail.android.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.cabalmail.android.R
import com.cabalmail.kit.settings.Accent
import com.cabalmail.kit.settings.AppPreferences
import com.cabalmail.kit.settings.AppTheme
import com.cabalmail.kit.settings.Density
import com.cabalmail.kit.settings.DisposeAction

/**
 * Row density (plan §6.3 "Density"): the vertical padding list rows use.
 * Provided by [CabalmailTheme] from the synced preference.
 */
val LocalRowPadding = staticCompositionLocalOf { 10.dp }

/** True when the "Dispose action" preference targets Trash (labels follow it). */
val LocalDisposeToTrash = staticCompositionLocalOf { false }

/** The dispose affordance's label: purge inside Trash, else the preference's target. */
@Composable
fun disposeLabelRes(isTrashFolder: Boolean): Int =
    when {
        isTrashFolder -> R.string.purge
        LocalDisposeToTrash.current -> R.string.dispose_to_trash
        else -> R.string.archive
    }

fun Density.rowPadding(): Dp =
    when (this) {
        Density.COMPACT -> 6.dp
        Density.NORMAL -> 10.dp
        Density.ROOMY -> 16.dp
    }

/**
 * Seed colours for the shared accent palette (web + Apple). Used when the
 * "Dynamic color" preference is off; Material You wins otherwise.
 */
private fun Accent.seed(): Color =
    when (this) {
        Accent.INK -> Color(0xFF1F2A44)
        Accent.OXBLOOD -> Color(0xFF6B1F2A)
        Accent.FOREST -> Color(0xFF1F5B3A)
        Accent.AZURE -> Color(0xFF1B5E9E)
        Accent.AMBER -> Color(0xFFB0651B)
        Accent.PLUM -> Color(0xFF5B2A6B)
    }

private fun accentScheme(
    accent: Accent,
    dark: Boolean,
): ColorScheme {
    val seed = accent.seed()
    // A restrained hand-rolled scheme: the seed carries primary, the rest
    // stays neutral so every accent reads as one system.
    return if (dark) {
        darkColorScheme(
            primary = seed.lighten(0.45f),
            onPrimary = Color(0xFF10141A),
            primaryContainer = seed.darken(0.25f),
            onPrimaryContainer = seed.lighten(0.75f),
            secondary = seed.lighten(0.3f),
            secondaryContainer = seed.darken(0.4f),
            onSecondaryContainer = seed.lighten(0.7f),
            tertiary = seed.lighten(0.55f),
        )
    } else {
        lightColorScheme(
            primary = seed,
            onPrimary = Color.White,
            primaryContainer = seed.lighten(0.8f),
            onPrimaryContainer = seed.darken(0.5f),
            secondary = seed.darken(0.15f),
            secondaryContainer = seed.lighten(0.85f),
            onSecondaryContainer = seed.darken(0.5f),
            tertiary = seed.darken(0.3f),
        )
    }
}

private fun Color.lighten(amount: Float): Color =
    Color(
        red = red + (1f - red) * amount,
        green = green + (1f - green) * amount,
        blue = blue + (1f - blue) * amount,
        alpha = alpha,
    )

private fun Color.darken(amount: Float): Color =
    Color(red = red * (1f - amount), green = green * (1f - amount), blue = blue * (1f - amount), alpha = alpha)

/** Whether the theme preference resolves to dark, given the platform's answer. */
fun AppPreferences.resolvesDark(systemDark: Boolean): Boolean =
    when (theme) {
        AppTheme.SYSTEM -> systemDark
        AppTheme.LIGHT -> false
        AppTheme.DARK -> true
    }

/**
 * Material 3 theme driven by [preferences] (plan §6.3 "Appearance"): the
 * theme mode (System defers to the platform), Material You dynamic colour
 * when enabled (API 31 floor guarantees it), else the shared accent seed;
 * and the row density via [LocalRowPadding].
 */
@Composable
fun CabalmailTheme(
    preferences: AppPreferences = AppPreferences(),
    content: @Composable () -> Unit,
) {
    val darkTheme = preferences.resolvesDark(isSystemInDarkTheme())
    val context = LocalContext.current
    val colorScheme =
        when {
            preferences.dynamicColor && darkTheme -> dynamicDarkColorScheme(context)
            preferences.dynamicColor -> dynamicLightColorScheme(context)
            else -> accentScheme(preferences.accent, darkTheme)
        }
    CompositionLocalProvider(
        LocalRowPadding provides preferences.density.rowPadding(),
        LocalDisposeToTrash provides (preferences.disposeAction == DisposeAction.TRASH),
    ) {
        MaterialTheme(
            colorScheme = colorScheme,
            content = content,
        )
    }
}
