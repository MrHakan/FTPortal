package com.mrhakan.ftportal

import android.Manifest
import android.app.AlertDialog
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
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
    private lateinit var incomingContainer: LinearLayout
    private var pendingRemote: RemoteSelection? = null
    private var pendingIncomingOffer: IncomingPeerOffer? = null
    private var scanning = false
    private val handler = Handler(Looper.getMainLooper())
    private val incomingTicker = object : Runnable {
        override fun run() {
            refreshIncomingOffers()
            handler.postDelayed(this, 2_000)
        }
    }

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

    private val offerFolder = registerForActivityResult(ActivityResultContracts.OpenDocumentTree()) { treeUri ->
        val offer = pendingIncomingOffer
        pendingIncomingOffer = null
        if (treeUri == null || offer == null) return@registerForActivityResult

        runCatching {
            contentResolver.takePersistableUriPermission(
                treeUri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
        }
        Toast.makeText(this, "Receiving ${offer.files.size} file${if (offer.files.size == 1) "" else "s"}…", Toast.LENGTH_SHORT).show()
        PeerOfferReceiver.downloadAll(applicationContext, offer, treeUri) { report ->
            runOnUiThread {
                if (isFinishing || isDestroyed) return@runOnUiThread
                val message = when {
                    report.failures.isEmpty() -> "Received ${report.completed.size} file${if (report.completed.size == 1) "" else "s"}."
                    report.completed.isEmpty() -> "Transfer failed: ${report.failures.first()}"
                    else -> "Received ${report.completed.size}; ${report.failures.size} failed. Remaining files can be retried."
                }
                Toast.makeText(this, message, Toast.LENGTH_LONG).show()
                refresh()
                refreshLobbies()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ShareRegistry.initialize(applicationContext)
        requestNotificationPermission()

        status = TextView(this).apply { textSize = 16f }
        shares = TextView(this).apply { textSize = 15f }
        scanStatus = TextView(this).apply { textSize = 14f }
        lobbiesContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        incomingContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }

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
                text = "Incoming transfers"
                textSize = 22f
                setPadding(0, 32, 0, 4)
            })
            addView(TextView(this@MainActivity).apply {
                text = "FTPortal v2 offers wait for your explicit Accept or Decline."
                textSize = 14f
            })
            addView(incomingContainer)
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
        handler.post(incomingTicker)
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    override fun onDestroy() {
        handler.removeCallbacks(incomingTicker)
        super.onDestroy()
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
                "\nPeer protocol: ${PeerProtocol.VERSION} (v1 compatible) on TCP ${PeerProtocol.PEER_PORT}"
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
        refreshIncomingOffers()
    }

    private fun refreshIncomingOffers() {
        if (!::incomingContainer.isInitialized) return
        val offers = PeerOfferStore.incoming()
        incomingContainer.removeAllViews()
        if (offers.isEmpty()) {
            incomingContainer.addView(TextView(this).apply {
                text = "No incoming offers."
                textSize = 14f
            })
            return
        }
        offers.forEach { offer ->
            incomingContainer.addView(Button(this).apply {
                isAllCaps = false
                text = "${offer.senderAlias} (${offer.senderPlatform}) · ${offer.files.size} file${if (offer.files.size == 1) "" else "s"} · code ${offer.verificationCode}"
                setOnClickListener { showIncomingOffer(offer) }
            })
        }
    }

    private fun showIncomingOffer(offer: IncomingPeerOffer) {
        val fileLines = offer.files.joinToString("\n") { file ->
            "• ${file.name}${if (file.size >= 0) " · ${file.size} bytes" else ""}"
        }
        AlertDialog.Builder(this)
            .setTitle("Incoming from ${offer.senderAlias}")
            .setMessage(
                "Verification code: ${offer.verificationCode}\n\n$fileLines\n\n" +
                    "Accept chooses one destination folder, then FTPortal receives the offered files directly."
            )
            .setNegativeButton("Decline") { _, _ ->
                PeerOfferStore.decline(offer.offerId)
                refreshIncomingOffers()
            }
            .setPositiveButton("Accept") { _, _ ->
                pendingIncomingOffer = offer
                offerFolder.launch(null)
            }
            .show()
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
                val version = if (lobby.supportsOffers) "v2" else "v1"
                text = "Join · ${lobby.alias} (${lobby.platform}) · ${lobby.files.size} file${if (lobby.files.size == 1) "" else "s"} · $version"
                setOnClickListener { showLobby(lobby) }
            })
        }
    }

    private fun showLobby(lobby: PeerLobby) {
        val labels = lobby.files.map { file ->
            if (file.size >= 0) "${file.name} · ${file.size} bytes" else file.name
        }.toTypedArray()
        val builder = AlertDialog.Builder(this)
            .setTitle("${lobby.alias} · ${lobby.platform}")
            .setMessage("Choose a one-shot file to pull as before.${if (lobby.supportsOffers) " Or send all of your pending files as a v2 offer." else ""}")
            .setItems(labels) { _, index ->
                val file = lobby.files[index]
                pendingRemote = RemoteSelection(lobby, file)
                saveRemote.launch(safeFileName(file.name))
            }
            .setNegativeButton("Close", null)

        if (lobby.supportsOffers && ShareRegistry.all().isNotEmpty()) {
            builder.setNeutralButton("Send my files") { _, _ -> sendOffer(lobby) }
        }
        builder.show()
    }

    private fun sendOffer(lobby: PeerLobby) {
        val files = ShareRegistry.all()
        if (files.isEmpty()) {
            Toast.makeText(this, "Add at least one pending share first.", Toast.LENGTH_SHORT).show()
            return
        }
        Toast.makeText(this, "Sending offer to ${lobby.alias}…", Toast.LENGTH_SHORT).show()
        Thread {
            val result = runCatching { PeerOfferClient.send(applicationContext, lobby, files) }
            runOnUiThread {
                if (isFinishing || isDestroyed) return@runOnUiThread
                result.onSuccess { offer ->
                    AlertDialog.Builder(this)
                        .setTitle("Offer sent")
                        .setMessage(
                            "${lobby.alias} must accept the transfer.\n\nVerification code: ${offer.verificationCode}\n\n" +
                                "The code should match on both devices. The offer expires in 5 minutes."
                        )
                        .setPositiveButton("OK", null)
                        .show()
                }.onFailure { error ->
                    Toast.makeText(this, "Offer failed: ${error.message ?: "unknown error"}", Toast.LENGTH_LONG).show()
                }
            }
        }.start()
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
                        "${PeerProtocol.DOWNLOAD_PREFIX_V1}${selection.file.id}"
                )
                connection = (url.openConnection() as HttpURLConnection).apply {
                    requestMethod = "GET"
                    connectTimeout = 3000
                    readTimeout = 60_000
                    instanceFollowRedirects = false
                    useCaches = false
                    setRequestProperty("X-FTPortal-Client", PeerProtocol.VERSION_V1)
                }
                val code = connection.responseCode
                if (code != HttpURLConnection.HTTP_OK) error("Peer returned HTTP $code")

                val output = contentResolver.openOutputStream(destination, "w")
                    ?: error("Could not open the selected destination")
                var received = 0L
                connection.inputStream.use { input ->
                    output.use { out ->
                        val buffer = ByteArray(128 * 1024)
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            out.write(buffer, 0, count)
                            received += count
                        }
                        out.flush()
                    }
                }
                if (selection.file.size >= 0 && received != selection.file.size) {
                    error("Expected ${selection.file.size} bytes, received $received")
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
