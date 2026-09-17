package com.cabalmail.android.ui.theme

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Star
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.res.painterResource
import com.cabalmail.android.R

/**
 * The glyph for a star that toggles a state (favorite, flag): filled when
 * [on], the hollow `ic_star_border` when off, so the state reads by shape
 * and not by tint alone (#1612, as the reader's flag button does since
 * #1607). `material-icons-core` ships no hollow star — its
 * `Icons.Outlined.Star` is the same solid glyph as `Icons.Filled.Star` — so
 * a toggle must never pick between those two.
 */
@Composable
internal fun starTogglePainter(on: Boolean): Painter =
    if (on) rememberVectorPainter(Icons.Filled.Star) else painterResource(R.drawable.ic_star_border)
