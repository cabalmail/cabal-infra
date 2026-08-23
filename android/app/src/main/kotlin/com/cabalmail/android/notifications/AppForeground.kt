package com.cabalmail.android.notifications

import android.app.Activity
import android.app.Application
import android.os.Bundle
import java.util.concurrent.atomic.AtomicInteger

/**
 * Process-wide foreground tracker, registered from Application.onCreate.
 * The messaging service consults it off the main thread, which is why this
 * is a started-activity counter rather than ProcessLifecycleOwner (whose
 * state is main-thread-bound).
 */
object AppForeground : Application.ActivityLifecycleCallbacks {
    private val started = AtomicInteger(0)

    /** True while any activity is started (visible or focused). */
    val isForeground: Boolean
        get() = started.get() > 0

    override fun onActivityStarted(activity: Activity) {
        started.incrementAndGet()
    }

    override fun onActivityStopped(activity: Activity) {
        started.decrementAndGet()
    }

    override fun onActivityCreated(
        activity: Activity,
        savedInstanceState: Bundle?,
    ) = Unit

    override fun onActivityResumed(activity: Activity) = Unit

    override fun onActivityPaused(activity: Activity) = Unit

    override fun onActivitySaveInstanceState(
        activity: Activity,
        outState: Bundle,
    ) = Unit

    override fun onActivityDestroyed(activity: Activity) = Unit
}
