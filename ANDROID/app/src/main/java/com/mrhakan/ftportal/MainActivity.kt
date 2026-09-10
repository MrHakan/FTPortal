package com.mrhakan.ftportal

import android.Manifest
import android.app.AlertDialog
import android.content.ColorStateList
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.OpenableColumns
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import java.net.HttpURLConnection
import java.net.URL
import java.text.DateFormat
import java.util.Date
import kotlin.math.max

private data class RemoteSelection(val lobby: PeerLobby, val file: PeerRemoteFile)
private enum class PortalScreen { HOME, NEARBY, HISTORY }

private object UiColors {
    val background = Color.rgb(8, 12, 20)
    val surface = Color.rgb(18, 24, 38)
    val surfaceRaised = Color.rgb(26, 34, 52)
    val primary = Color.rgb(99, 102, 241)
    val primarySoft = Color.rgb(48, 51, 92)
    val text = Color.rgb(241, 245, 249)
    val muted = Color.rgb(148, 163, 184)
    val border = Color.rgb(51, 65, 85)
    val success = Color.rgb(74, 222, 128)
    val danger = Color.rgb(248, 113, 113)
}

class MainActivity : ComponentActivity() {
    private lateinit var statusText: TextView
    private lateinit var hostBadge: TextView
    private lateinit var sharesContainer: LinearLayout
    private lateinit var scanStatus: TextView
    private lateinit var lobbiesContainer: LinearLayout
    private lateinit var incomingContainer: LinearLayout
    private lateinit var activeContainer: LinearLayout
    private lateinit var activeCard: LinearLayout
    private lateinit var historyContainer: LinearLayout
    private lateinit var alwaysOnSwitch: Switch
    private lateinit var overlayButton: Button
    private lateinit var batteryButton: Button
    private lateinit var homeScreen: View
    private lateinit var nearbyScreen: View
    private lateinit var historyScreen: View
    private lateinit var navHome: Button
    private lateinit var navNearby: Button
    private lateinit var navHistory: Button

    private var pendingRemote: RemoteSelection? = null
    private var pendingIncomingOffer: IncomingPeerOffer? = null
    private var scanning = false
    private var currentScreen = PortalScreen.HOME
    private val handler = Handler(Looper.getMainLooper())

    private val uiTicker = object : Runnable {
        override fun run() {
            refreshIncomingOffers()
            renderActiveTransfers()
            refreshBackgroundControls()
            if (currentScreen == PortalScreen.HISTORY) renderHistory()
            handler.postDelayed(this, 1_000)
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

    private val batterySettings = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        requestOverlayPermission()
        refreshBackgroundControls()
    }

    private val overlaySettings = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        val granted = Settings.canDrawOverlays(this)
        HostPreferences.setOverlayEnabled(this, granted)
        refreshPortalService()
        refreshBackgroundControls()
        if (granted) Toast.makeText(this, "Floating FTPortal status enabled.", Toast.LENGTH_SHORT).show()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ShareRegistry.initialize(applicationContext)
        TransferCenter.initialize(applicationContext)
        requestNotificationPermission()

        window.statusBarColor = UiColors.background
        window.navigationBarColor = UiColors.background
        buildUi()
        startPortal()
        refresh()
        refreshLobbies()
        handler.post(uiTicker)
    }

    override fun onResume() {
        super.onResume()
        refresh()
        refreshBackgroundControls()
    }

    override fun onDestroy() {
        handler.removeCallbacks(uiTicker)
        super.onDestroy()
    }

    private fun buildUi() {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(UiColors.background)
        }
        root.addView(buildHeader())

        val contentHost = FrameLayout(this).apply { setBackgroundColor(UiColors.background) }
        homeScreen = buildHomeScreen()
        nearbyScreen = buildNearbyScreen()
        historyScreen = buildHistoryScreen()
        contentHost.addView(homeScreen)
        contentHost.addView(nearbyScreen)
        contentHost.addView(historyScreen)
        root.addView(contentHost, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        root.addView(buildNavigation())
        setContentView(root)
        showScreen(PortalScreen.HOME)
    }

    private fun buildHeader(): View {
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(20), dp(18), dp(20), dp(12))
            addView(TextView(this@MainActivity).apply {
                text = "⇄"
                gravity = Gravity.CENTER
                textSize = 23f
                setTextColor(Color.WHITE)
                setTypeface(typeface, Typeface.BOLD)
                background = rounded(UiColors.primary, radius = 16)
            }, LinearLayout.LayoutParams(dp(48), dp(48)))
            addView(LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(dp(12), 0, 0, 0)
                addView(label("FTPortal", 24f, UiColors.text, bold = true))
                addView(label("Direct local file transfer", 13f, UiColors.muted))
            }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            hostBadge = label("STARTING", 11f, UiColors.text, bold = true).apply {
                gravity = Gravity.CENTER
                setPadding(dp(10), dp(6), dp(10), dp(6))
                background = rounded(UiColors.primarySoft, radius = 999)
            }
            addView(hostBadge)
        }
    }

    private fun buildHomeScreen(): View {
        val content = verticalContent()

        val hero = card().apply {
            addView(label("Share without the cloud", 22f, UiColors.text, bold = true))
            addView(label("Pick a file once. Nearby FTPortal apps can join your lobby, while browsers can still use the web fallback.", 14f, UiColors.muted).apply {
                setPadding(0, dp(7), 0, dp(16))
            })
            addView(primaryButton("＋  Share a file") { picker.launch(arrayOf("*/*")) })
        }
        addCard(content, hero)

        activeCard = card().apply {
            addView(sectionTitle("Active transfer"))
            activeContainer = LinearLayout(this@MainActivity).apply { orientation = LinearLayout.VERTICAL }
            addView(activeContainer)
        }
        addCard(content, activeCard)

        val hostCard = card().apply {
            addView(sectionTitle("Host status"))
            statusText = label("Starting…", 14f, UiColors.muted).apply { setPadding(0, dp(7), 0, dp(12)) }
            addView(statusText)
            val row = LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                addView(secondaryButton("Start") { startPortal() }, LinearLayout.LayoutParams(0, dp(46), 1f).apply { marginEnd = dp(6) })
                addView(secondaryButton("Stop") { stopPortal() }, LinearLayout.LayoutParams(0, dp(46), 1f).apply { marginStart = dp(6) })
            }
            addView(row)
        }
        addCard(content, hostCard)

        val backgroundCard = card().apply {
            addView(sectionTitle("Always-on Android host"))
            addView(label("Termux-style mode keeps a foreground-service notification visible, restores the host after reboot, and asks Android to relax battery restrictions. A floating FT bubble is optional.", 13f, UiColors.muted).apply {
                setPadding(0, dp(6), 0, dp(12))
            })
            alwaysOnSwitch = Switch(this@MainActivity).apply {
                text = "Keep FTPortal running in background"
                textSize = 15f
                setTextColor(UiColors.text)
                buttonTintList = ColorStateList.valueOf(UiColors.primary)
                isChecked = HostPreferences.isAlwaysOn(this@MainActivity)
                setOnCheckedChangeListener { _, enabled ->
                    HostPreferences.setAlwaysOn(this@MainActivity, enabled)
                    if (enabled) {
                        startPortal()
                        requestBackgroundHostingPermissions()
                    } else {
                        refreshPortalService()
                    }
                    refreshBackgroundControls()
                }
            }
            addView(alwaysOnSwitch)
            batteryButton = secondaryButton("Battery optimization") { requestBatteryExemptionThenOverlay() }
            overlayButton = secondaryButton("Floating status") { toggleOverlayPermission() }
            addView(batteryButton, marginTop(dp(10)))
            addView(overlayButton, marginTop(dp(8)))
        }
        addCard(content, backgroundCard)

        val incomingCard = card().apply {
            addView(sectionTitle("Incoming transfers"))
            addView(label("v2 offers require Accept or Decline. Compare the six-digit code if you want to verify the sender.", 13f, UiColors.muted).apply {
                setPadding(0, dp(5), 0, dp(10))
            })
            incomingContainer = LinearLayout(this@MainActivity).apply { orientation = LinearLayout.VERTICAL }
            addView(incomingContainer)
        }
        addCard(content, incomingCard)

        val sharesCard = card().apply {
            val header = LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                addView(sectionTitle("My one-shot shares"), LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
                addView(textButton("Clear") {
                    if (ShareRegistry.all().isNotEmpty()) confirmClearShares()
                })
            }
            addView(header)
            sharesContainer = LinearLayout(this@MainActivity).apply { orientation = LinearLayout.VERTICAL }
            addView(sharesContainer)
        }
        addCard(content, sharesCard)

        return scroll(content)
    }

    private fun buildNearbyScreen(): View {
        val content = verticalContent()
        addCard(content, card().apply {
            addView(label("Nearby lobbies", 24f, UiColors.text, bold = true))
            addView(label("FTPortal scans the directly connected local network. v2 devices can receive offers; v1 devices still support the original pull flow.", 14f, UiColors.muted).apply {
                setPadding(0, dp(7), 0, dp(14))
            })
            addView(primaryButton("↻  Refresh nearby devices") { refreshLobbies() })
            scanStatus = label("Waiting to scan…", 13f, UiColors.muted).apply { setPadding(0, dp(12), 0, 0) }
            addView(scanStatus)
        })
        lobbiesContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        content.addView(lobbiesContainer)
        return scroll(content)
    }

    private fun buildHistoryScreen(): View {
        val content = verticalContent()
        addCard(content, card().apply {
            val row = LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                addView(LinearLayout(this@MainActivity).apply {
                    orientation = LinearLayout.VERTICAL
                    addView(label("Transfer history", 24f, UiColors.text, bold = true))
                    addView(label("Completed and failed sends/receives are stored locally on this device.", 13f, UiColors.muted))
                }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
                addView(textButton("Clear") {
                    TransferCenter.clearHistory(applicationContext)
                    renderHistory()
                })
            }
            addView(row)
        })
        historyContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        content.addView(historyContainer)
        return scroll(content)
    }

    private fun buildNavigation(): View {
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(dp(12), dp(8), dp(12), dp(10))
            background = GradientDrawable().apply {
                setColor(UiColors.surface)
                setStroke(dp(1), UiColors.border)
            }
            navHome = navButton("⌂\nHome") { showScreen(PortalScreen.HOME) }
            navNearby = navButton("◎\nNearby") { showScreen(PortalScreen.NEARBY) }
            navHistory = navButton("↺\nHistory") { showScreen(PortalScreen.HISTORY) }
            addView(navHome, LinearLayout.LayoutParams(0, dp(58), 1f))
            addView(navNearby, LinearLayout.LayoutParams(0, dp(58), 1f))
            addView(navHistory, LinearLayout.LayoutParams(0, dp(58), 1f))
        }
    }

    private fun showScreen(screen: PortalScreen) {
        currentScreen = screen
        homeScreen.visibility = if (screen == PortalScreen.HOME) View.VISIBLE else View.GONE
        nearbyScreen.visibility = if (screen == PortalScreen.NEARBY) View.VISIBLE else View.GONE
        historyScreen.visibility = if (screen == PortalScreen.HISTORY) View.VISIBLE else View.GONE
        listOf(navHome to PortalScreen.HOME, navNearby to PortalScreen.NEARBY, navHistory to PortalScreen.HISTORY).forEach { (button, target) ->
            button.setTextColor(if (target == screen) Color.WHITE else UiColors.muted)
            button.background = rounded(if (target == screen) UiColors.primarySoft else Color.TRANSPARENT, radius = 14)
        }
        if (screen == PortalScreen.HISTORY) renderHistory()
    }

    private fun refresh() {
        val running = HostPreferences.isServiceRunning(this)
        val urls = NetworkUrls.urls(PortalService.PORT)
        hostBadge.text = if (running) "ONLINE" else "OFFLINE"
        hostBadge.setTextColor(if (running) UiColors.success else UiColors.danger)
        statusText.text = when {
            !running -> "Host is stopped. Tap Start to expose your local lobby."
            urls.isEmpty() -> "Host is running, but this phone is not currently reachable on a Wi-Fi/hotspot IPv4 address."
            else -> "Web fallback:\n${urls.joinToString("\n")}\nNative peer: ${PeerProtocol.VERSION} · TCP ${PeerProtocol.PEER_PORT}"
        }
        renderShares()
        refreshIncomingOffers()
        renderActiveTransfers()
        refreshBackgroundControls()
    }

    private fun renderShares() {
        if (!::sharesContainer.isInitialized) return
        sharesContainer.removeAllViews()
        val files = ShareRegistry.all()
        if (files.isEmpty()) {
            sharesContainer.addView(emptyText("Nothing pending. Sharing a file makes this device visible as a lobby."))
            return
        }
        files.forEachIndexed { index, file ->
            if (index > 0) sharesContainer.addView(divider())
            sharesContainer.addView(fileRow(file.name, if (file.size >= 0) formatBytes(file.size) else "Streaming source", "⇧"))
        }
    }

    private fun renderActiveTransfers() {
        if (!::activeContainer.isInitialized) return
        val transfers = TransferCenter.active()
        activeCard.visibility = if (transfers.isEmpty()) View.GONE else View.VISIBLE
        activeContainer.removeAllViews()
        transfers.forEachIndexed { index, transfer ->
            if (index > 0) activeContainer.addView(divider())
            val block = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(0, dp(8), 0, dp(8))
                addView(label(transfer.fileName, 15f, UiColors.text, bold = true))
                addView(label("${if (transfer.direction == TransferDirection.RECEIVE) "Receiving from" else "Sending to"} ${transfer.peer}", 12f, UiColors.muted))
                val progress = ProgressBar(this@MainActivity, null, android.R.attr.progressBarStyleHorizontal).apply {
                    max = 100
                    progressTintList = ColorStateList.valueOf(UiColors.primary)
                    progressBackgroundTintList = ColorStateList.valueOf(UiColors.border)
                    isIndeterminate = transfer.progressPercent == null
                    transfer.progressPercent?.let { progress = it }
                }
                addView(progress, marginTop(dp(8)))
                val percent = transfer.progressPercent?.let { "$it%" } ?: "Streaming"
                val speed = if (transfer.bytesPerSecond > 1.0) formatSpeed(transfer.bytesPerSecond) else "measuring…"
                val eta = transfer.etaSeconds?.let { " · ETA ${formatDuration(it)}" } ?: ""
                addView(label("$percent · $speed$eta", 12f, UiColors.muted).apply { setPadding(0, dp(4), 0, 0) })
            }
            activeContainer.addView(block)
        }
    }

    private fun refreshIncomingOffers() {
        if (!::incomingContainer.isInitialized) return
        val offers = PeerOfferStore.incoming()
        incomingContainer.removeAllViews()
        if (offers.isEmpty()) {
            incomingContainer.addView(emptyText("No incoming offers."))
            return
        }
        offers.forEach { offer ->
            incomingContainer.addView(compactActionCard(
                title = offer.senderAlias,
                subtitle = "${offer.senderPlatform} · ${offer.files.size} file${if (offer.files.size == 1) "" else "s"} · code ${offer.verificationCode}",
                action = "Review"
            ) { showIncomingOffer(offer) }, marginTop(dp(7)))
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
            val version = if (lobby.supportsOffers) "v2 · offers" else "v1 · pull"
            lobbiesContainer.addView(compactActionCard(
                title = lobby.alias,
                subtitle = "${lobby.platform} · ${lobby.files.size} file${if (lobby.files.size == 1) "" else "s"} · $version · ${lobby.host}",
                action = "Join"
            ) { showLobby(lobby) }, cardMargins())
        }
    }

    private fun renderHistory() {
        if (!::historyContainer.isInitialized) return
        historyContainer.removeAllViews()
        val history = TransferCenter.history(applicationContext)
        if (history.isEmpty()) {
            addCard(historyContainer, card().apply { addView(emptyText("No transfers yet. Completed and failed native/web transfers will appear here.")) })
            return
        }
        history.forEach { entry ->
            val card = card().apply {
                val row = LinearLayout(this@MainActivity).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    addView(label(if (entry.direction == TransferDirection.RECEIVE) "↓" else "↑", 22f, if (entry.success) UiColors.success else UiColors.danger, bold = true), LinearLayout.LayoutParams(dp(34), ViewGroup.LayoutParams.WRAP_CONTENT))
                    addView(LinearLayout(this@MainActivity).apply {
                        orientation = LinearLayout.VERTICAL
                        addView(label(entry.fileName, 15f, UiColors.text, bold = true))
                        val direction = if (entry.direction == TransferDirection.RECEIVE) "Received from" else "Sent to"
                        addView(label("$direction ${entry.peer}", 12f, UiColors.muted))
                        val whenText = DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(Date(entry.finishedAt))
                        val size = formatBytes(max(entry.bytesTransferred, 0L))
                        addView(label("$size · $whenText${if (entry.success) "" else " · failed"}", 12f, UiColors.muted))
                        entry.detail?.takeIf { it.isNotBlank() && !entry.success }?.let {
                            addView(label(it, 11f, UiColors.danger).apply { setPadding(0, dp(3), 0, 0) })
                        }
                    }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
                }
                addView(row)
            }
            addCard(historyContainer, card)
        }
    }

    private fun refreshLobbies() {
        if (scanning) return
        scanning = true
        if (::scanStatus.isInitialized) scanStatus.text = "Scanning the local network…"
        PeerDiscovery.discover(applicationContext) { lobbies ->
            runOnUiThread {
                scanning = false
                if (isFinishing || isDestroyed) return@runOnUiThread
                renderLobbies(lobbies)
            }
        }
    }

    private fun showIncomingOffer(offer: IncomingPeerOffer) {
        val total = offer.files.filter { it.size >= 0 }.sumOf { it.size }
        val fileLines = offer.files.joinToString("\n") { file ->
            "• ${file.name}${if (file.size >= 0) " · ${formatBytes(file.size)}" else ""}"
        }
        AlertDialog.Builder(this)
            .setTitle("Incoming from ${offer.senderAlias}")
            .setMessage("Verification code: ${offer.verificationCode}\n${if (total > 0) "Total: ${formatBytes(total)}\n" else ""}\n$fileLines\n\nAccept chooses one destination folder and starts direct local transfer.")
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

    private fun showLobby(lobby: PeerLobby) {
        val labels = lobby.files.map { file ->
            if (file.size >= 0) "${file.name} · ${formatBytes(file.size)}" else file.name
        }.toTypedArray()
        val builder = AlertDialog.Builder(this)
            .setTitle("${lobby.alias} · ${lobby.platform}")
            .setMessage("Choose a one-shot file to receive.${if (lobby.supportsOffers) " You can also send all of your pending files as a v2 offer." else ""}")
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
                        .setMessage("${lobby.alias} must accept the transfer.\n\nVerification code: ${offer.verificationCode}\n\nThe code should match on both devices. The offer expires in 5 minutes.")
                        .setPositiveButton("OK", null)
                        .show()
                }.onFailure { error ->
                    Toast.makeText(this, "Offer failed: ${error.message ?: "unknown error"}", Toast.LENGTH_LONG).show()
                }
            }
        }.start()
    }

    private fun downloadRemote(selection: RemoteSelection, destination: Uri) {
        Thread {
            var connection: HttpURLConnection? = null
            val transferId = TransferCenter.begin(
                applicationContext,
                TransferDirection.RECEIVE,
                selection.file.name,
                selection.lobby.alias,
                selection.file.size
            )
            var settled = false
            var received = 0L
            var errorMessage: String? = null
            try {
                val url = URL("http://${selection.lobby.host}:${selection.lobby.peerPort}${PeerProtocol.DOWNLOAD_PREFIX_V1}${selection.file.id}")
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
                connection.inputStream.use { input ->
                    output.use { out ->
                        val buffer = ByteArray(128 * 1024)
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            out.write(buffer, 0, count)
                            received += count
                            TransferCenter.update(transferId, received)
                        }
                        out.flush()
                    }
                }
                if (selection.file.size >= 0 && received != selection.file.size) {
                    error("Expected ${selection.file.size} bytes, received $received")
                }
                TransferCenter.finish(applicationContext, transferId, true)
                settled = true
            } catch (error: Exception) {
                errorMessage = error.message ?: error.javaClass.simpleName
                runCatching { contentResolver.delete(destination, null, null) }
                TransferCenter.finish(applicationContext, transferId, false, errorMessage)
                settled = true
            } finally {
                if (!settled) TransferCenter.finish(applicationContext, transferId, false, "Transfer interrupted")
                connection?.disconnect()
            }

            runOnUiThread {
                Toast.makeText(
                    this,
                    if (errorMessage == null) "Received ${selection.file.name}" else "Transfer failed: $errorMessage",
                    Toast.LENGTH_LONG
                ).show()
                refresh()
                refreshLobbies()
            }
        }.start()
    }

    private fun startPortal() {
        ContextCompat.startForegroundService(this, Intent(this, PortalService::class.java))
        hostBadge.text = "STARTING"
        hostBadge.setTextColor(UiColors.muted)
        handler.postDelayed({ refresh() }, 500)
    }

    private fun stopPortal() {
        HostPreferences.setAlwaysOn(this, false)
        if (::alwaysOnSwitch.isInitialized) alwaysOnSwitch.isChecked = false
        stopService(Intent(this, PortalService::class.java))
        handler.postDelayed({ refresh() }, 250)
    }

    private fun refreshPortalService() {
        if (!HostPreferences.isServiceRunning(this) && !HostPreferences.isAlwaysOn(this)) return
        ContextCompat.startForegroundService(
            this,
            Intent(this, PortalService::class.java).setAction(PortalService.ACTION_REFRESH)
        )
    }

    private fun requestBackgroundHostingPermissions() {
        requestNotificationPermission()
        requestBatteryExemptionThenOverlay()
    }

    private fun requestBatteryExemptionThenOverlay() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            requestOverlayPermission()
            return
        }
        val power = getSystemService(PowerManager::class.java)
        if (power.isIgnoringBatteryOptimizations(packageName)) {
            requestOverlayPermission()
            return
        }
        val direct = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName"))
        runCatching { batterySettings.launch(direct) }.onFailure {
            batterySettings.launch(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
        }
    }

    private fun toggleOverlayPermission() {
        if (Settings.canDrawOverlays(this) && HostPreferences.isOverlayEnabled(this)) {
            HostPreferences.setOverlayEnabled(this, false)
            refreshPortalService()
            refreshBackgroundControls()
        } else {
            requestOverlayPermission()
        }
    }

    private fun requestOverlayPermission() {
        if (Settings.canDrawOverlays(this)) {
            HostPreferences.setOverlayEnabled(this, true)
            refreshPortalService()
            refreshBackgroundControls()
            return
        }
        overlaySettings.launch(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName")))
    }

    private fun refreshBackgroundControls() {
        if (!::alwaysOnSwitch.isInitialized) return
        val alwaysOn = HostPreferences.isAlwaysOn(this)
        if (alwaysOnSwitch.isChecked != alwaysOn) alwaysOnSwitch.isChecked = alwaysOn
        val power = getSystemService(PowerManager::class.java)
        val batteryOk = Build.VERSION.SDK_INT < Build.VERSION_CODES.M || power.isIgnoringBatteryOptimizations(packageName)
        batteryButton.text = if (batteryOk) "✓ Battery optimization relaxed" else "Allow background battery use"
        val overlayGranted = Settings.canDrawOverlays(this)
        val overlayEnabled = HostPreferences.isOverlayEnabled(this) && overlayGranted
        overlayButton.text = when {
            overlayEnabled -> "✓ Floating FT bubble enabled"
            overlayGranted -> "Enable floating FT bubble"
            else -> "Allow display over other apps"
        }
    }

    private fun confirmClearShares() {
        AlertDialog.Builder(this)
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

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 40)
        }
    }

    private fun safeFileName(name: String): String {
        val leaf = name.substringAfterLast('/').substringAfterLast('\\').trim()
        return leaf.replace(Regex("[\\r\\n]"), "_").ifBlank { "FTPortal-download" }
    }

    private fun formatBytes(bytes: Long): String {
        if (bytes < 1024) return "$bytes B"
        val kb = bytes / 1024.0
        if (kb < 1024) return "%.1f KB".format(kb)
        val mb = kb / 1024.0
        if (mb < 1024) return "%.1f MB".format(mb)
        return "%.2f GB".format(mb / 1024.0)
    }

    private fun formatSpeed(bytesPerSecond: Double): String {
        val mb = bytesPerSecond / (1024.0 * 1024.0)
        return if (mb >= 0.1) "%.2f MB/s".format(mb) else "%.0f KB/s".format(bytesPerSecond / 1024.0)
    }

    private fun formatDuration(seconds: Long): String = when {
        seconds < 60 -> "${seconds}s"
        seconds < 3600 -> "${seconds / 60}m ${seconds % 60}s"
        else -> "${seconds / 3600}h ${(seconds % 3600) / 60}m"
    }

    private fun scroll(content: View): ScrollView = ScrollView(this).apply {
        isFillViewport = true
        clipToPadding = false
        addView(content)
    }

    private fun verticalContent(): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(16), dp(8), dp(16), dp(20))
    }

    private fun card(): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(16), dp(16), dp(16), dp(16))
        background = rounded(UiColors.surface, UiColors.border, 20)
        elevation = dp(2).toFloat()
    }

    private fun compactActionCard(title: String, subtitle: String, action: String, onClick: () -> Unit): LinearLayout {
        return card().apply {
            val row = LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                addView(LinearLayout(this@MainActivity).apply {
                    orientation = LinearLayout.VERTICAL
                    addView(label(title, 16f, UiColors.text, bold = true))
                    addView(label(subtitle, 12f, UiColors.muted).apply { setPadding(0, dp(3), dp(8), 0) })
                }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
                addView(secondaryButton(action) { onClick() }, LinearLayout.LayoutParams(dp(82), dp(42)))
            }
            addView(row)
        }
    }

    private fun fileRow(title: String, subtitle: String, glyph: String): View {
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(9), 0, dp(9))
            addView(label(glyph, 20f, UiColors.primary, bold = true), LinearLayout.LayoutParams(dp(34), ViewGroup.LayoutParams.WRAP_CONTENT))
            addView(LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.VERTICAL
                addView(label(title, 15f, UiColors.text, bold = true))
                addView(label(subtitle, 12f, UiColors.muted))
            })
        }
    }

    private fun sectionTitle(text: String): TextView = label(text, 17f, UiColors.text, bold = true)

    private fun emptyText(text: String): TextView = label(text, 13f, UiColors.muted).apply {
        setPadding(0, dp(10), 0, dp(8))
    }

    private fun label(text: String, size: Float, color: Int, bold: Boolean = false): TextView = TextView(this).apply {
        this.text = text
        textSize = size
        setTextColor(color)
        if (bold) setTypeface(typeface, Typeface.BOLD)
        setLineSpacing(0f, 1.08f)
    }

    private fun primaryButton(text: String, onClick: () -> Unit): Button = Button(this).apply {
        isAllCaps = false
        this.text = text
        textSize = 16f
        setTextColor(Color.WHITE)
        setTypeface(typeface, Typeface.BOLD)
        background = rounded(UiColors.primary, radius = 16)
        stateListAnimator = null
        setOnClickListener { onClick() }
        minHeight = dp(52)
    }

    private fun secondaryButton(text: String, onClick: () -> Unit): Button = Button(this).apply {
        isAllCaps = false
        this.text = text
        textSize = 13f
        setTextColor(UiColors.text)
        background = rounded(UiColors.surfaceRaised, UiColors.border, 14)
        stateListAnimator = null
        setOnClickListener { onClick() }
        minHeight = dp(44)
    }

    private fun textButton(text: String, onClick: () -> Unit): Button = Button(this).apply {
        isAllCaps = false
        this.text = text
        textSize = 12f
        setTextColor(UiColors.primary)
        background = rounded(Color.TRANSPARENT, radius = 12)
        stateListAnimator = null
        setOnClickListener { onClick() }
        minWidth = 0
        minimumWidth = 0
    }

    private fun navButton(text: String, onClick: () -> Unit): Button = Button(this).apply {
        isAllCaps = false
        this.text = text
        textSize = 12f
        gravity = Gravity.CENTER
        setPadding(0, 0, 0, 0)
        setTextColor(UiColors.muted)
        background = rounded(Color.TRANSPARENT, radius = 14)
        stateListAnimator = null
        setOnClickListener { onClick() }
    }

    private fun divider(): View = View(this).apply {
        setBackgroundColor(UiColors.border)
        layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(1))
    }

    private fun addCard(parent: LinearLayout, view: View) {
        parent.addView(view, cardMargins())
    }

    private fun cardMargins(): LinearLayout.LayoutParams = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.WRAP_CONTENT
    ).apply {
        topMargin = dp(8)
        bottomMargin = dp(8)
    }

    private fun marginTop(value: Int): LinearLayout.LayoutParams = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.WRAP_CONTENT
    ).apply { topMargin = value }

    private fun rounded(fill: Int, stroke: Int? = null, radius: Int): GradientDrawable = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        setColor(fill)
        cornerRadius = dp(radius).toFloat()
        stroke?.let { setStroke(dp(1), it) }
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()
}
