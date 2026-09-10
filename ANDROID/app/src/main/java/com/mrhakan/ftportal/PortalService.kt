package com.mrhakan.ftportal

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import fi.iki.elonen.NanoHTTPD

class PortalService : Service() {
    companion object {
        const val PORT = 8080
        private const val CHANNEL = "ftportal-host"
        private const val TAG = "FTPortalService"
    }

    private var server: PortalServer? = null
    private var nsd: NsdManager? = null
    private var registration: NsdManager.RegistrationListener? = null

    override fun onCreate() {
        super.onCreate()
        ShareRegistry.initialize(applicationContext)
        createChannel()
        val openIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val notification = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("FTPortal host is running")
            .setContentText("Serving one-shot files on the local network")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(openIntent)
            .build()
        startForeground(41, notification)

        runCatching {
            PortalServer(applicationContext, PORT).also {
                it.start(NanoHTTPD.SOCKET_READ_TIMEOUT, false)
                server = it
            }
            registerNsd()
        }.onFailure {
            Log.e(TAG, "Unable to start local host", it)
            stopSelf()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onDestroy() {
        registration?.let { listener ->
            runCatching { nsd?.unregisterService(listener) }
                .onFailure { Log.w(TAG, "NSD unregister failed", it) }
        }
        registration = null
        nsd = null
        server?.stop()
        server = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createChannel() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "FTPortal Host", NotificationManager.IMPORTANCE_LOW)
        )
    }

    private fun registerNsd() {
        val manager = getSystemService(Context.NSD_SERVICE) as NsdManager
        nsd = manager
        val info = NsdServiceInfo().apply {
            serviceName = "FTPortal"
            serviceType = "_http._tcp."
            port = PORT
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(serviceInfo: NsdServiceInfo) {
                Log.i(TAG, "NSD registered as ${serviceInfo.serviceName}")
            }

            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "NSD registration failed: $errorCode")
            }

            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) = Unit

            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "NSD unregistration failed: $errorCode")
            }
        }
        registration = listener
        manager.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
    }
}
