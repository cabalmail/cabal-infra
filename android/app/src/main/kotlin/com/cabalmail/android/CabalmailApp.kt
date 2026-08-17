package com.cabalmail.android

import android.app.Application

/** Application entry point; owns the app-wide dependency graph. */
class CabalmailApp : Application() {
    val container: AppContainer by lazy { AppContainer(this) }
}
