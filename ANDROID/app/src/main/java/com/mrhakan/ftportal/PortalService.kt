package com.mrhakan.ftportal

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.IBinder
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.WindowManager
import android.widget.TextView
import androidx.core.app.NotificationCompat
import fi.iki.elonen.NanoHTTPD

class PortalService : Service() {
    companion object {
        const val PORT = 8080
        const val ACTION_STOP = "com.mrhakan.ftportal.STOP_HOST"
        const val ACTION_REFRESH = "com.mrhakan.ftportal.REFRESH_HOST"
        private const val CHANNEL = "ftportal-host"
        private const val NOTIFICATION_ID = 41
        private const val TAG = "FTPortalService"
    }

    private var legacyServer: PortalServer? = null
    private var peerServer: PortalServer? = null
    private var nsd: NsdManager? = null
    private var registration: NsdManager.RegistrationListener? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var overlayView: TextView? = null
    private var overlayManager: WindowManager? = null

    override fun onCreate() {
        super.onCreate()
        ShareRegistry.initialize(applicationContext)
        TransferCenter.initialize(applicationContext)
        HostPreferences.setServiceRunning(applicationContext, true)
        createChannel()
        startForeground(NOTIFICATION_ID, buildNotification())

        runCatching {
            legacyServer = PortalServer(applicationContext, PORT).also {
                it.start(NanoHTTPD.SOCKET_READ_TIMEOUT, false)
            }
        }.onFailure {
            Log.e(TAG, "Unable to start legacy local host", it)
            stopSelf()
            return
        }

        runCatching {
            peerServer = PortalServer(applicationContext, PeerProtocol.PEER_PORT).also {
                it.start(NanoHTTPD.SOCKET_READ_TIMEOUT, false)
            }
        }.onFailure {
            Log.w(TAG, "Peer protocol port unavailable; legacy web host remains active", it)
        }

        registerNsd()
        syncAlwaysOnResources()
        syncOverlay()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            HostPreferences.setAlwaysOn(applicationContext, false)
            stopSelf()
            return START_NOT_STICKY
        }

        syncAlwaysOnResources()
        syncOverlay()
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, buildNotification())
        return if (HostPreferences.isAlwaysOn(applicationContext)) START_STICKY else START_NOT_STICKY
    }

    override fun onDestroy() {
        removeOverlay()
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        registration?.let { listener ->
            runCatching { nsd?.unregisterService(listener) }
                .onFailure { Log.w(TAG, "NSD unregister failed", it) }
        }
        registration = null
        nsd = null
        peerServer?.stop()
        peerServer = null
        legacyServer?.stop()
        legacyServer = null
        HostPreferences.setServiceRunning(applicationContext, false)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createChannel() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "FTPortal background host", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Keeps FTPortal available for local-network transfers"
                setShowBadge(false)
            }
        )
    }

    private fun buildNotification(): android.app.Notification {
        val openIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val stopIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, PortalService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val alwaysOn = HostPreferences.isAlwaysOn(applicationContext)
        val active = TransferCenter.active().size
        val text = when {
            active > 0 -> "$active active transfer${if (active == 1) "" else "s"} · local host online"
            alwaysOn -> "Always-on · web host + native peer lobby online"
            else -> "Web host + native peer lobby online"
        }

        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_ftportal)
            .setContentTitle("FTPortal is running")
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(openIntent)
            .addAction(R.drawable.ic_stat_ftportal, "Stop", stopIntent)
            .build()
    }

    private fun syncAlwaysOnResources() {
        val shouldHold = HostPreferences.isAlwaysOn(applicationContext)
        if (shouldHold && wakeLock?.isHeld != true) {
            val manager = getSystemService(PowerManager::class.java)
            wakeLock = manager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "FTPortal:AlwaysOnHost").apply {
                setReferenceCounted(false)
                acquire()
            }
        } else if (!shouldHold && wakeLock?.isHeld == true) {
            wakeLock?.release()
            wakeLock = null
        }
    }

    private fun syncOverlay() {
        val shouldShow = HostPreferences.isAlwaysOn(applicationContext) &&
            HostPreferences.isOverlayEnabled(applicationContext) &&
            Settings.canDrawOverlays(this)
        if (!shouldShow) {
            removeOverlay()
            return
        }
        if (overlayView != null) return

        val manager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        overlayManager = manager
        val bubble = TextView(this).apply {
            text = "FT"
            gravity = Gravity.CENTER
            setTextColor(Color.WHITE)
            textSize = 14f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            includeFontPadding = false
            elevation = dp(10).toFloat()
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.rgb(79, 70, 229))
                setStroke(dp(2), Color.argb(100, 255, 255, 255))
            }
            setOnClickListener {
                val intent = Intent(this@PortalService, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                startActivity(intent)
            }
        }
        val params = WindowManager.LayoutParams(
            dp(56),
            dp(56),
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.END
            x = dp(12)
            y = dp(88)
        }
        runCatching { manager.addView(bubble, params) }
            .onSuccess { overlayView = bubble }
            .onFailure { Log.w(TAG, "Could not show FTPortal overlay", it) }
    }

    private fun removeOverlay() {
        val view = overlayView ?: return
        runCatching { overlayManager?.removeView(view) }
        overlayView = null
        overlayManager = null
    }

    private fun registerNsd() {
        val manager = getSystemService(Context.NSD_SERVICE) as NsdManager
        nsd = manager
        val info = NsdServiceInfo().apply {
            serviceName = "FTPortal-${PeerIdentity.alias().take(28)}"
            serviceType = "_ftportal._tcp."
            port = PeerProtocol.PEER_PORT
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(serviceInfo: NsdServiceInfo) {
                Log.i(TAG, "Peer NSD registered as ${serviceInfo.serviceName}")
            }

            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "Peer NSD registration failed: $errorCode")
            }

            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) = Unit

            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "NSD unregistration failed: $errorCode")
            }
        }
        registration = listener
        manager.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()
}
