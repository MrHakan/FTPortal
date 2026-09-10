# FTPortal

FTPortal is a local-first, multi-platform file-transfer host. The same idea is shipped in four platform folders so a laptop, Windows PC, Android phone or iPhone can temporarily host files for devices on the same local network.

## Editions

| Folder | Runtime | Host behavior |
|---|---|---|
| `POWERSHELL/` | PowerShell 5.1+ | Original full Windows implementation, preserved with Wi-Fi Direct / hotspot / station / LAN / Bluetooth transport logic and WebRTC fallback. |
| `ANDROID/` | Native Kotlin APK | Foreground-service host for the connected local network. Files stream directly from Android Storage Access Framework URIs; pending URI metadata survives normal process/service restarts. |
| `IOS/` | Native SwiftUI | Local-network host using Network.framework + Bonjour. Files stream directly from security-scoped URLs for the current app session. |
| `WINDOWS/` | .NET 8 WinForms EXE | Native dashboard, background tray mode, Wi-Fi → LAN → hotspot advertisement preference, Mobile Hotspot fallback, Kestrel host and `ftphakan.local` mDNS responder. Pending source-path metadata survives app restarts. |

## One-shot transfer rule

Android, iOS and Windows use one-shot shares. Selecting a file creates share metadata only; FTPortal never creates a second persistent copy of the source file.

A download now atomically claims its share before streaming. While that transfer is active, a second client cannot claim the same one-shot link. A completed response consumes the share. If a client disconnects or the transfer fails, the claim is released so the owner can retry. `HEAD`/non-download probes do not consume a share.

Removing or clearing a share removes only FTPortal's metadata/access grant. FTPortal does **not** delete the user's original file.

## Build + collective releases

`.github/workflows/multiplatform-release.yml` builds all four editions in parallel. A push to `main`, a `v*` tag, or a manual workflow run produces one GitHub Release containing:

- `FTPortal-PowerShell.zip`
- `FTPortal-Android.apk`
- `FTPortal-iOS-unsigned.ipa`
- `FTPortal-Windows-x64.zip`

Build jobs use read-only repository permissions; only the final release job receives `contents: write`. The workflow uses current official GitHub/Gradle/Android setup actions and verifies all four expected assets before publishing with the GitHub CLI.

The Android artifact is intentionally sideload-oriented and debug-signed by CI. The iOS artifact is intentionally unsigned because GitHub Actions cannot possess an Apple Distribution identity unless repository signing secrets are configured. Configure private signing credentials before store distribution.

## Network model

FTPortal is designed for **trusted local networks**. It does not expose a cloud relay and it does not currently provide user authentication for peers on the same reachable network. Do not run the host on an untrusted/public network if the pending files are sensitive.

Mobile editions publish an HTTP service to their current local interface and Bonjour/NSD service discovery. Windows listens on local interfaces while selecting the preferred address in this order: Wi-Fi, wired LAN, then Windows Mobile Hotspot. If port 80 is unavailable it falls back to 8080 and then 8787.

The native HTTP hosts send `no-store`, MIME-sniffing, referrer and content-security headers. Download filenames use encoded `filename*` metadata rather than injecting the raw filename into an HTTP header.

For the mature PowerShell feature set and its transport/security details, see [`POWERSHELL/README.md`](POWERSHELL/README.md).
