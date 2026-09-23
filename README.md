# FTPortal

FTPortal is a local-first, multi-platform file-transfer host. The same idea is shipped in four platform folders so a laptop, Windows PC, Android phone or iPhone can temporarily host files for devices on the same local network.

## Editions

| Folder | Runtime | Host behavior |
|---|---|---|
| `POWERSHELL/` | PowerShell 5.1+ | Original full Windows implementation, preserved with Wi-Fi Direct / hotspot / station / LAN / Bluetooth transport logic and WebRTC fallback. |
| `ANDROID/` | Native Kotlin APK | Foreground-service host, native lobby discovery, direct peer receive and optional v2 Send/Accept offers. Files stream from Android Storage Access Framework URIs without an FTPortal source copy. |
| `IOS/` | Native SwiftUI | Local-network host, native lobby discovery, direct peer receive and optional v2 Send/Accept offers using Network.framework + URLSession. |
| `WINDOWS/` | .NET 8 WinForms EXE | Native dashboard, tray mode, Wi-Fi → LAN → hotspot preference, Mobile Hotspot fallback, Kestrel web host, native lobby discovery, v2 Send/Accept offers and `ftphakan.local` mDNS responder. |

## FTPortal Peer Protocol

Android, iOS and Windows speak directly to each other on fixed TCP port `47171`.

### Existing `ftportal/1` flow stays intact

When a native app has at least one pending one-shot file it becomes an active **lobby**. Other FTPortal apps on the same local IPv4 subnet discover it, list it under **Lobbies**, join it and can pull an individual file directly.

The v1 endpoints remain available in current builds:

- `GET /api/ftportal/v1/info`
- `GET /api/ftportal/v1/download/<fileId>`

### `ftportal/2` adds optional sender offers

Current native builds advertise `ftportal/2` while remaining compatible with v1. A v2-capable lobby gets one additional action: **Send my pending files**.

The receiver sees the request under **Incoming transfers**, including the sender, offered files and a six-digit verification code, then explicitly chooses **Accept** or **Decline**. Accept chooses one destination and pulls the offered files using a short-lived, offer-scoped bearer token. Offers expire automatically after roughly five minutes.

This is deliberately an overlay rather than a replacement: users can keep using the original lobby → join → receive-selected-file flow exactly as before. v2 discovery also falls back to v1 automatically when the remote app has not been upgraded.

See [`docs/PEER-PROTOCOL.md`](docs/PEER-PROTOCOL.md) for the full contract, compatibility rules and security model.

## One-shot transfer rule

Selecting a file creates share metadata only; FTPortal never creates a second persistent copy of the source file.

A download atomically claims its share before streaming. While that transfer is active, a second client cannot claim the same one-shot link. A completed response consumes the share. If a client disconnects or the transfer fails, the claim is released so the owner can retry. Browser `HEAD` probes do not consume a share.

Removing or clearing a share removes only FTPortal's metadata/access grant. FTPortal does **not** delete the user's original file.

## Browser fallback

Web browsers do not need the peer protocol and are intentionally excluded from v2 offers. They continue to use the old FTPortal flow:

- open the displayed local IP / `ftphakan.local` address,
- use the browser dashboard,
- download with the existing `/download/<id>` one-shot route.

The PowerShell edition also remains on its mature existing lobby/router flow rather than duplicating the native v2 peer stack inside the monolithic script.

Windows, Android and iOS now share the same offline `/dashboard` and `/lobby`
browser views, visually aligned with the original FTPHAKAN dashboard and
PowerShell lobby. The lobby shows a local address QR, active bearer addresses
and native peer availability; the dashboard shows an invite QR, file queue,
one-shot transfers and browser uploads. The
webpage does not pretend to offer private recipient selection: use the native
Nearby view for discovery and v2 offers. PowerShell retains its more advanced
existing dashboard, sessions, QR enrollment and transport supervisor. See
[`docs/WEB-PORTAL-OVERHAUL.md`](docs/WEB-PORTAL-OVERHAUL.md) for the endpoint
contract, test command and remaining cross-platform parity work.

## Build + collective releases

`.github/workflows/multiplatform-release.yml` builds all four editions in parallel. Pull requests run the same platform build/test jobs without publishing a release. A push to `main`, a `v*` tag, or a manual workflow run produces one GitHub Release containing:

- `FTPortal-PowerShell.zip`
- `FTPortal-Android.apk`
- `FTPortal-iOS-unsigned.ipa`
- `FTPortal-Windows-x64.zip`

Build jobs use read-only repository permissions; only the final release job receives `contents: write`. The workflow verifies all four expected assets before publishing the collective release.

The Android artifact is intentionally sideload-oriented and debug-signed by CI. The iOS artifact is intentionally unsigned because GitHub Actions cannot possess an Apple Distribution identity unless repository signing secrets are configured. Configure private signing credentials before store distribution.

## Network and security model

FTPortal is designed for **trusted local networks**. It does not expose a cloud relay.

Peer Protocol v2 adds explicit Accept/Decline, expiring per-offer authorization tokens, file scoping and a human verification code. These controls prevent an ordinary v2 offer from becoming an unrestricted receive endpoint, but they do **not** encrypt the local connection. Native peer traffic still uses local HTTP; do not forward TCP `47171` or the browser host to the public Internet when files are sensitive.

The native HTTP hosts send `no-store`, MIME-sniffing, referrer and content-security headers. Windows, Android and iOS also perform a private-address/current-subnet admission check before routing HTTP or peer requests. Download filenames use encoded `filename*` metadata rather than injecting raw filenames into HTTP headers.

For the mature PowerShell feature set and its transport/security details, see [`POWERSHELL/README.md`](POWERSHELL/README.md).
