package com.cabalmail.android

import android.app.Application
import android.os.StrictMode
import com.cabalmail.android.notifications.AppForeground
import com.cabalmail.android.notifications.Push

/** Application entry point; owns the app-wide dependency graph. */
class CabalmailApp : Application() {
    val container: AppContainer by lazy { AppContainer(this) }

    override fun onCreate() {
        super.onCreate()
        // Foreground tracking for push (suppress the banner while the user
        // is looking at the app), and the manual Firebase init — a no-op on
        // builds without the cabalmail.fcm* gradle properties.
        registerActivityLifecycleCallbacks(AppForeground)
        Push.initialize(this)
        if (BuildConfig.DEBUG) {
            // Plan §7.6: catch disk / network work on the main thread while
            // developing. Logged, never fatal — the point is to notice.
            StrictMode.setThreadPolicy(
                StrictMode.ThreadPolicy
                    .Builder()
                    .detectDiskReads()
                    .detectDiskWrites()
                    .detectNetwork()
                    .penaltyLog()
                    .build(),
            )
            StrictMode.setVmPolicy(
                StrictMode.VmPolicy
                    .Builder()
                    .detectLeakedClosableObjects()
                    .penaltyLog()
                    .build(),
            )
        }
    }
}
