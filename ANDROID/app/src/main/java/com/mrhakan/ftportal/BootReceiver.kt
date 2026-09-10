package com.mrhakan.ftportal

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED && action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        if (!HostPreferences.isAlwaysOn(context)) return

        runCatching {
            ContextCompat.startForegroundService(
                context,
                Intent(context, PortalService::class.java).setAction(PortalService.ACTION_REFRESH)
            )
        }
    }
}
