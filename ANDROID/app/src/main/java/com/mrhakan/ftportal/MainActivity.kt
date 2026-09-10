package com.mrhakan.ftportal

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.view.Gravity
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat

class MainActivity : ComponentActivity() {
    private lateinit var status: TextView
    private lateinit var shares: TextView

    private val picker = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@registerForActivityResult
        runCatching {
            contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        var name = "shared-file"
        var size = -1L
        val cursor: Cursor? = contentResolver.query(uri, null, null, null, null)
        cursor?.use {
            if (it.moveToFirst()) {
                val ni = it.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val si = it.getColumnIndex(OpenableColumns.SIZE)
                if (ni >= 0) name = it.getString(ni) ?: name
                if (si >= 0 && !it.isNull(si)) size = it.getLong(si)
            }
        }
        ShareRegistry.add(uri, name, contentResolver.getType(uri) ?: "application/octet-stream", size)
        startPortal()
        refresh()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestNotificationPermission()

        status = TextView(this).apply { textSize = 16f }
        shares = TextView(this).apply { textSize = 15f }
        val start = Button(this).apply {
            text = "Start host"
            setOnClickListener { startPortal() }
        }
        val add = Button(this).apply {
            text = "Share one-shot file"
            setOnClickListener { picker.launch(arrayOf("*/*")) }
        }
        val stop = Button(this).apply {
            text = "Stop host"
            setOnClickListener {
                stopService(Intent(this@MainActivity, PortalService::class.java))
                status.text = "Host stopped"
            }
        }
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(36, 54, 36, 36)
            addView(TextView(this@MainActivity).apply {
                text = "FTPortal · Android"
                textSize = 26f
            })
            addView(status)
            addView(start)
            addView(add)
            addView(stop)
            addView(shares)
        }
        setContentView(layout)
        startPortal()
        refresh()
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    private fun startPortal() {
        ContextCompat.startForegroundService(this, Intent(this, PortalService::class.java))
        refresh()
    }

    private fun refresh() {
        val urls = NetworkUrls.urls(PortalService.PORT)
        status.text = if (urls.isEmpty()) {
            "Host is starting. Connect this phone to Wi-Fi/hotspot."
        } else {
            "Open on the same network:\n" + urls.joinToString("\n") + "\nBonjour/NSD: FTPortal._http._tcp"
        }
        val list = ShareRegistry.all()
        shares.text = if (list.isEmpty()) {
            "\nNo pending shares. Files are never copied into FTPortal storage."
        } else {
            "\nPending one-shot shares:\n" + list.joinToString("\n") { "• ${it.name}" }
        }
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 40)
        }
    }
}
