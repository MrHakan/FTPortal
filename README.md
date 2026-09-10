# FTPortal

FTPortal is a local-first, multi-platform file-transfer host. The same idea is shipped in four platform folders so a laptop, Windows PC, Android phone or iPhone can temporarily host files for devices on the same local network.

## Editions

| Folder | Runtime | Host behavior |
|---|---|---|
| `POWERSHELL/` | PowerShell 5.1+ | Original full Windows implementation, preserved with Wi-Fi Direct / hotspot / station / LAN / Bluetooth transport logic and WebRTC fallback. |
| `ANDROID/` | Native Kotlin APK | Foreground-service host for the connected local network. Files are streamed directly from Android Storage Access Framework URIs and are never copied into FTPortal storage. |
| `IOS/` | Native SwiftUI | Local-network host using Network.framework + Bonjour. Files are streamed from security-scoped URLs without creating an FTPortal copy. |
| `WINDOWS/` | .NET 8 WinForms EXE | Native dashboard, background tray mode, Wi-Fi → LAN → hotspot advertisement preference, Mobile Hotspot fallback, Kestrel host and `ftphakan.local` mDNS responder. |

## One-shot transfer rule

Android, iOS and Windows use one-shot shares. Selecting a file creates a temporary share record only. The server opens the original file when a peer downloads it, streams it to the socket, and removes the share record after the full response completes. FTPortal does **not** delete the user's original file and does not create a second persistent copy.

## Build + collective releases

`.github/workflows/multiplatform-release.yml` builds all four editions in parallel. A push to `main`, a `v*` tag, or a manual workflow run produces one GitHub Release containing:

- `FTPortal-PowerShell.zip`
- `FTPortal-Android.apk`
- `FTPortal-iOS-unsigned.ipa`
- `FTPortal-Windows-x64.zip`

The iOS artifact is intentionally unsigned because GitHub Actions cannot possess an Apple Distribution identity unless repository signing secrets are configured. It can be signed by the developer's Apple account / CI signing setup later.

## Network model

FTPortal is designed for trusted local networks only. It does not expose a cloud relay. Mobile editions publish an HTTP service to their current local interface and Bonjour/NSD service discovery. Windows listens on all local interfaces while selecting the preferred address in this order: Wi-Fi, wired LAN, then Windows Mobile Hotspot. If port 80 is unavailable it falls back to 8080 and then 8787.

For the mature PowerShell feature set and its transport/security details, see [`POWERSHELL/README.md`](POWERSHELL/README.md).
