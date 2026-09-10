package com.mrhakan.ftportal

import android.Manifest
import android.app.AlertDialog
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.view.Gravity
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat

class MainActivity : ComponentActivity() {
    private lateinit var status: TextView
    private lateinit var shares: TextView

    private val picker = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@registerForActivityResult

        val persisted = runCatching {
            contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }.isSuccess
        if (!persisted) {
            Toast.makeText(this, "This provider may not keep the share available after a restart.", Toast.LENGTH_LONG).show()
        }

        var name = "shared-file"
        var size = -1L
        val cursor: Cursor? = contentResolver.query(uri, null, null, null, null)
        cursor?.use {
            if (it.moveToFirst()) {
                val nameIndex = it.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeIndex = it.getColumnIndex(OpenableColumns.SIZE)
                if (nameIndex >= 0) name = it.getString(nameIndex) ?: name
                if (sizeIndex >= 0 && !it.isNull(sizeIndex)) size = it.getLong(sizeIndex)
            }
        }

        ShareRegistry.add(uri, name, contentResolver.getType(uri) ?: "application/octet-stream", size)
        startPortal()
        refresh()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ShareRegistry.initialize(applicationContext)
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
        val clear = Button(this).apply {
            text = "Clear pending shares"
            setOnClickListener {
                if (ShareRegistry.all().isEmpty()) return@setOnClickListener
                AlertDialog.Builder(this@MainActivity)
                    .setTitle("Clear pending shares?")
                    .setMessage("This removes FTPortal share links only. Original files are never deleted.")
                    .setNegativeButton("Cancel", null)
                    .setPositiveButton("Clear") { _, _ ->
                        ShareRegistry.clearPending()
                        refresh()
                    }
                    .show()
            }
        }
        val stop = Button(this).apply {
            text = "Stop host"
            setOnClickListener {
                stopService(Intent(this@MainActivity, PortalService::class.java))
                status.text = "Host stopped"
            }
        }

        val content = LinearLayout(this).apply {
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
            addView(clear)
            addView(stop)
            addView(shares)
        }
        setContentView(ScrollView(this).apply { addView(content) })

        startPortal()
        refresh()
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    private fun startPortal() {
        ContextCompat.startForegroundService(this, Intent(this, PortalService::class.java))
        status.text = "Host is starting…"
    }

    private fun refresh() {
        val urls = NetworkUrls.urls(PortalService.PORT)
        status.text = if (urls.isEmpty()) {
            "Connect this phone to Wi-Fi or a hotspot to host files."
        } else {
            "Open on the same network:\n" + urls.joinToString("\n") + "\nBonjour/NSD: FTPortal._http._tcp"
        }

        val list = ShareRegistry.all()
        shares.text = if (list.isEmpty()) {
            "\nNo pending shares. Files are never copied into FTPortal storage."
        } else {
            "\nPending one-shot shares:\n" + list.joinToString("\n") { file ->
                val sizeText = if (file.size >= 0) " · ${file.size} bytes" else ""
                "• ${file.name}$sizeText"
            }
        }
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 40)
        }
    }
}
