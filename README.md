# FTPortal

FTPortal is a local-first, multi-platform file-transfer host. The same idea is shipped in four platform folders so a laptop, Windows PC, Android phone or iPhone can temporarily host files for devices on the same local network.

## Editions

| Folder | Runtime | Host behavior |
|---|---|---|
| `POWERSHELL/` | PowerShell 5.1+ | Original full Windows implementation, preserved with Wi-Fi Direct / hotspot / station / LAN / Bluetooth transport logic and WebRTC fallback. |
| `ANDROID/` | Native Kotlin APK | Foreground-service host, native lobby discovery and direct peer receive. Files stream from Android Storage Access Framework URIs without an FTPortal source copy. |
| `IOS/` | Native SwiftUI | Local-network host, native lobby discovery and direct peer receive using Network.framework + URLSession. |
| `WINDOWS/` | .NET 8 WinForms EXE | Native dashboard, tray mode, Wi-Fi → LAN → hotspot preference, Mobile Hotspot fallback, Kestrel web host, native lobby discovery and `ftphakan.local` mDNS responder. |

## FTPortal Peer Protocol v1

Android, iOS and Windows now speak `ftportal/1` directly to each other.

When a native app has at least one pending one-shot file it becomes an active **lobby**. Other FTPortal apps on the same local IPv4 subnet scan a fixed native peer port (`47171`), list discovered lobbies on the main screen and can join them without manually entering an IP address.

Native protocol endpoints:

- `GET /api/ftportal/v1/info` — device identity, platform, lobby state and file manifest.
- `GET /api/ftportal/v1/download/<fileId>` — native one-shot peer stream.

Windows keeps its browser host on the normal fallback sequence (80 → 8080 → 8787), while its peer protocol always uses 47171. Android and iOS keep their existing browser host on 8080 and also expose the native peer listener on 47171.

See [`docs/PEER-PROTOCOL.md`](docs/PEER-PROTOCOL.md) for the protocol contract and current security model.

## One-shot transfer rule

Selecting a file creates share metadata only; FTPortal never creates a second persistent copy of the source file.

A download atomically claims its share before streaming. While that transfer is active, a second client cannot claim the same one-shot link. A completed response consumes the share. If a client disconnects or the transfer fails, the claim is released so the owner can retry. Browser `HEAD` probes do not consume a share.

Removing or clearing a share removes only FTPortal's metadata/access grant. FTPortal does **not** delete the user's original file.

## Browser fallback

Web browsers do not need the peer protocol. They continue to use the old FTPortal flow:

- open the displayed local IP / `ftphakan.local` address,
- use the browser dashboard,
- download with the existing `/download/<id>` one-shot route.

The PowerShell edition also remains on its mature existing lobby/router flow in Peer Protocol v1 instead of duplicating a second native-peer implementation inside the monolithic script.

## Build + collective releases

`.github/workflows/multiplatform-release.yml` builds all four editions in parallel. A push to `main`, a `v*` tag, or a manual workflow run produces one GitHub Release containing:

- `FTPortal-PowerShell.zip`
- `FTPortal-Android.apk`
- `FTPortal-iOS-unsigned.ipa`
- `FTPortal-Windows-x64.zip`

Build jobs use read-only repository permissions; only the final release job receives `contents: write`. The workflow verifies all four expected assets before publishing the collective release.

The Android artifact is intentionally sideload-oriented and debug-signed by CI. The iOS artifact is intentionally unsigned because GitHub Actions cannot possess an Apple Distribution identity unless repository signing secrets are configured. Configure private signing credentials before store distribution.

## Network and security model

FTPortal is designed for **trusted local networks**. It does not expose a cloud relay and Peer Protocol v1 does not yet provide TLS peer identity, pairing PINs or authenticated sessions. Do not forward TCP 47171 or the browser host to the public Internet if files are sensitive.

The native HTTP hosts send `no-store`, MIME-sniffing, referrer and content-security headers. Download filenames use encoded `filename*` metadata rather than injecting raw filenames into HTTP headers.

For the mature PowerShell feature set and its transport/security details, see [`POWERSHELL/README.md`](POWERSHELL/README.md).
