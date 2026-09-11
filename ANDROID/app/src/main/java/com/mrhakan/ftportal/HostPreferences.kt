package com.mrhakan.ftportal

import android.content.Context

object HostPreferences {
    private const val PREFS = "ftportal-host-preferences"
    private const val KEY_ALWAYS_ON = "always_on"
    private const val KEY_OVERLAY = "overlay_enabled"
    private const val KEY_SERVICE_RUNNING = "service_running"
    private const val KEY_BOUND_WEB_PORT = "bound_web_port"
    private const val KEY_APP_VERSION = "app_version"

    fun isAlwaysOn(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_ALWAYS_ON, false)

    fun setAlwaysOn(context: Context, enabled: Boolean) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY_ALWAYS_ON, enabled).apply()
    }

    fun isOverlayEnabled(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_OVERLAY, false)

    fun setOverlayEnabled(context: Context, enabled: Boolean) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY_OVERLAY, enabled).apply()
    }

    fun isServiceRunning(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_SERVICE_RUNNING, false)

    fun setServiceRunning(context: Context, running: Boolean) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY_SERVICE_RUNNING, running).apply()
    }

    fun boundWebPort(context: Context): Int =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getInt(KEY_BOUND_WEB_PORT, 0)

    fun setBoundWebPort(context: Context, port: Int) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putInt(KEY_BOUND_WEB_PORT, port).apply()
    }

    fun prepareForVersion(context: Context, versionCode: Int) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val previous = prefs.getInt(KEY_APP_VERSION, 0)
        if (previous == versionCode) return

        prefs.edit()
            .putInt(KEY_APP_VERSION, versionCode)
            .putBoolean(KEY_SERVICE_RUNNING, false)
            .putInt(KEY_BOUND_WEB_PORT, 0)
            .apply()
    }
}
