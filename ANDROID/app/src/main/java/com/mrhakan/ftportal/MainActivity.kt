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
import java.net.HttpURLConnection
import java.net.URL

private data class RemoteSelection(val lobby: PeerLobby, val file: PeerRemoteFile)

class MainActivity : ComponentActivity() {
    private lateinit var status: TextView
    private lateinit var shares: TextView
    private lateinit var scanStatus: TextView
    private lateinit var lobbiesContainer: LinearLayout
    private var pendingRemote: RemoteSelection? = null
    private var scanning = false

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
        refreshLobbies()
    }

    private val saveRemote = registerForActivityResult(ActivityResultContracts.CreateDocument("*/*")) { destination ->
        val selection = pendingRemote
        pendingRemote = null
        if (destination != null && selection != null) downloadRemote(selection, destination)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ShareRegistry.initialize(applicationContext)
        requestNotificationPermission()

        status = TextView(this).apply { textSize = 16f }
        shares = TextView(this).apply { textSize = 15f }
        scanStatus = TextView(this).apply { textSize = 14f }
        lobbiesContainer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }

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
                        refreshLobbies()
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
        val refreshPeers = Button(this).apply {
            text = "Refresh lobbies"
            setOnClickListener { refreshLobbies() }
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
            addView(TextView(this@MainActivity).apply {
                text = "Lobbies"
                textSize = 22f
                setPadding(0, 32, 0, 4)
            })
            addView(TextView(this@MainActivity).apply {
                text = "FTPortal apps on the same LAN appear here automatically. Web users keep using the address above."
                textSize = 14f
            })
            addView(refreshPeers)
            addView(scanStatus)
            addView(lobbiesContainer)
            addView(TextView(this@MainActivity).apply {
                text = "My one-shot shares"
                textSize = 20f
                setPadding(0, 28, 0, 4)
            })
            addView(shares)
        }
        setContentView(ScrollView(this).apply { addView(content) })

        startPortal()
        refresh()
        refreshLobbies()
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
            "Web fallback:\n" + urls.joinToString("\n") +
                "\nPeer protocol: ${PeerProtocol.VERSION} on TCP ${PeerProtocol.PEER_PORT}"
        }

        val list = ShareRegistry.all()
        shares.text = if (list.isEmpty()) {
            "\nNo pending shares. Add a file to make this device appear as a lobby."
        } else {
            "\nPending one-shot shares:\n" + list.joinToString("\n") { file ->
                val sizeText = if (file.size >= 0) " · ${file.size} bytes" else ""
                "• ${file.name}$sizeText"
            }
        }
    }

    private fun refreshLobbies() {
        if (scanning) return
        scanning = true
        scanStatus.text = "Scanning the local network…"
        PeerDiscovery.discover(applicationContext) { lobbies ->
            runOnUiThread {
                scanning = false
                if (isFinishing || isDestroyed) return@runOnUiThread
                renderLobbies(lobbies)
            }
        }
    }

    private fun renderLobbies(lobbies: List<PeerLobby>) {
        lobbiesContainer.removeAllViews()
        if (lobbies.isEmpty()) {
            scanStatus.text = "No active FTPortal lobbies found."
            return
        }

        scanStatus.text = "${lobbies.size} active ${if (lobbies.size == 1) "lobby" else "lobbies"} found."
        lobbies.forEach { lobby ->
            lobbiesContainer.addView(Button(this).apply {
                isAllCaps = false
                text = "Join · ${lobby.alias} (${lobby.platform}) · ${lobby.files.size} file${if (lobby.files.size == 1) "" else "s"}"
                setOnClickListener { showLobby(lobby) }
            })
        }
    }

    private fun showLobby(lobby: PeerLobby) {
        val labels = lobby.files.map { file ->
            if (file.size >= 0) "${file.name} · ${file.size} bytes" else file.name
        }.toTypedArray()
        AlertDialog.Builder(this)
            .setTitle("${lobby.alias} · ${lobby.platform}")
            .setMessage("Choose a one-shot file. FTPortal streams it directly from ${lobby.host}; the sender consumes the share after a complete transfer.")
            .setItems(labels) { _, index ->
                val file = lobby.files[index]
                pendingRemote = RemoteSelection(lobby, file)
                saveRemote.launch(safeFileName(file.name))
            }
            .setNegativeButton("Close", null)
            .show()
    }

    private fun downloadRemote(selection: RemoteSelection, destination: android.net.Uri) {
        Toast.makeText(this, "Receiving ${selection.file.name}…", Toast.LENGTH_SHORT).show()
        Thread {
            var connection: HttpURLConnection? = null
            var success = false
            var errorMessage: String? = null
            try {
                val url = URL(
                    "http://${selection.lobby.host}:${selection.lobby.peerPort}" +
                        "${PeerProtocol.DOWNLOAD_PREFIX}${selection.file.id}"
                )
                connection = (url.openConnection() as HttpURLConnection).apply {
                    requestMethod = "GET"
                    connectTimeout = 3000
                    readTimeout = 60_000
                    instanceFollowRedirects = false
                    useCaches = false
                    setRequestProperty("X-FTPortal-Client", PeerProtocol.VERSION)
                }
                val code = connection.responseCode
                if (code != HttpURLConnection.HTTP_OK) {
                    error("Peer returned HTTP $code")
                }

                val output = contentResolver.openOutputStream(destination, "w")
                    ?: error("Could not open the selected destination")
                connection.inputStream.use { input ->
                    output.use { out -> input.copyTo(out, 128 * 1024) }
                }
                success = true
            } catch (error: Exception) {
                errorMessage = error.message ?: error.javaClass.simpleName
                runCatching { contentResolver.delete(destination, null, null) }
            } finally {
                connection?.disconnect()
            }

            runOnUiThread {
                if (success) {
                    Toast.makeText(this, "Received ${selection.file.name}", Toast.LENGTH_LONG).show()
                } else {
                    Toast.makeText(this, "Transfer failed: ${errorMessage ?: "unknown error"}", Toast.LENGTH_LONG).show()
                }
                refreshLobbies()
            }
        }.start()
    }

    private fun safeFileName(name: String): String {
        val leaf = name.substringAfterLast('/').substringAfterLast('\\').trim()
        return leaf.replace(Regex("[\\r\\n]"), "_").ifBlank { "FTPortal-download" }
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 40)
        }
    }
}
