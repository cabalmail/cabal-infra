package com.cabalmail.android

import android.app.Application

/**
 * Application entry point. Auth initialization (configured programmatically
 * from the fetched `config.json`, not a checked-in configuration file) lands
 * here in Phase 3.
 */
class CabalmailApp : Application()
