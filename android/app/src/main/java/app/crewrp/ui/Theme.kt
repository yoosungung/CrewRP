package app.crewrp.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

private val LightColors = lightColorScheme(
    primary = Color(0xFF0F5C5C),
    onPrimary = Color(0xFFFFFFFF),
    primaryContainer = Color(0xFFD3EBEA),
    onPrimaryContainer = Color(0xFF062E2E),
    secondary = Color(0xFF8A5A2B),
    onSecondary = Color(0xFFFFFFFF),
    secondaryContainer = Color(0xFFFFDDB8),
    onSecondaryContainer = Color(0xFF3D2610),
    background = Color(0xFFF7F4EF),
    onBackground = Color(0xFF1C1917),
    surface = Color(0xFFFFFCF8),
    onSurface = Color(0xFF1C1917),
    surfaceVariant = Color(0xFFE7E1D8),
    onSurfaceVariant = Color(0xFF5C564E),
    outline = Color(0xFFD6D0C8),
    error = Color(0xFFB42318),
    errorContainer = Color(0xFFFDE8E6),
    onErrorContainer = Color(0xFF7A1C14),
)

private val DarkColors = darkColorScheme(
    primary = Color(0xFF8FDBD8),
    onPrimary = Color(0xFF063232),
    primaryContainer = Color(0xFF0F4A4A),
    onPrimaryContainer = Color(0xFFD3EBEA),
    secondary = Color(0xFFF0C08A),
    onSecondary = Color(0xFF3D2610),
    secondaryContainer = Color(0xFF5C3E1E),
    onSecondaryContainer = Color(0xFFFFDDB8),
    background = Color(0xFF141211),
    onBackground = Color(0xFFF3EDE6),
    surface = Color(0xFF1C1917),
    onSurface = Color(0xFFF3EDE6),
    surfaceVariant = Color(0xFF2C2824),
    onSurfaceVariant = Color(0xFFC9C1B6),
    outline = Color(0xFF3F3A35),
    error = Color(0xFFFFB4AB),
    errorContainer = Color(0xFF5C1A14),
    onErrorContainer = Color(0xFFFFDAD6),
)

@Composable
fun CrewRPTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = if (isSystemInDarkTheme()) DarkColors else LightColors,
        content = content,
    )
}
