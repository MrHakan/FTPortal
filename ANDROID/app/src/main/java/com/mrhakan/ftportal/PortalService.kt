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
import androidx.core.app.NotificationCompat
import fi.iki.elonen.NanoHTTPD

class PortalService : Service() {
    companion object {
        const val PORT = 8080
        private const val CHANNEL = "ftportal-host"
    }

    private var server: PortalServer? = null
    private var nsd: NsdManager? = null
    private var registration: NsdManager.RegistrationListener? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
        val openIntent = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val notification = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("FTPortal host is running")
            .setContentText("Serving one-shot files on the local network")
            .setOngoing(true)
            .setContentIntent(openIntent)
            .build()
        startForeground(41, notification)
        server = PortalServer(applicationContext, PORT).also { it.start(NanoHTTPD.SOCKET_READ_TIMEOUT, false) }
        registerNsd()
    }

    override fun onDestroy() {
        registration?.let { listener -> runCatching { nsd?.unregisterService(listener) } }
        server?.stop()
        server = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createChannel() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "FTPortal Host", NotificationManager.IMPORTANCE_LOW))
    }

    private fun registerNsd() {
        nsd = getSystemService(Context.NSD_SERVICE) as NsdManager
        val info = NsdServiceInfo().apply {
            serviceName = "FTPortal"
            serviceType = "_http._tcp."
            port = PORT
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(serviceInfo: NsdServiceInfo) = Unit
            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = Unit
            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) = Unit
            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = Unit
        }
        registration = listener
        nsd?.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
    }
}
