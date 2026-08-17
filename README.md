# Local File Portal

A **single-file PowerShell** web portal for fast device-to-device file transfer.
No installation, no admin rights, no external dependencies, **and no router** — the machine
running the portal raises its own access point, so phones join *it* and exchange files
through the browser. Where the browsers can manage it, the bytes go straight from device to
device and never touch the host's disk.

```
   __    ____    ____    ___    ____  _____  __    __
  / /   |  _ \  |  _ \  / _ \  |  _ \|_   _| \ \  / /
 | |    | | | | | |_) || | | | | |_) | | |    \ \/ /
 | |___ | |_| | |  __/ | |_| | |  _ <  | |     |  |
 |_____||____/  |_|     \___/  |_| \_\ |_|     |__|
```

## Quick Start

```powershell
powershell.exe -ExecutionPolicy Bypass -File LocalFilePortal.ps1
```

1. The portal raises its own Wi-Fi network and opens the **Lobby** page on the host screen.
2. On the phone: scan **QR 1** to join the network, then **QR 2** to open the portal.
   No router, no internet, no existing Wi-Fi involved.
3. Sign in with the password (default `hako123`), pick a device name, transfer away.

The SSID is `FTPHAKAN-XXXX` and the passphrase is regenerated on every run — both are shown
in the console banner and on the Lobby page.

## Bearers

The host becomes the network. Tried in order at startup:

| # | Bearer | Needs | Notes |
|---|---|---|---|
| A | Mobile Hotspot (`NetworkOperatorTetheringManager`) | a connection profile | Preferred. Windows supplies DHCP + DNS. Max 8 clients. |
| B | Wi-Fi Direct autonomous GO | nothing | Fallback when there is **no internet at all**. Phones see a normal WPA2 network. |
| — | An already-connected Wi-Fi | — | Used if both fail, or set `$Global:SelfAp = $false`. |

Both self-AP paths land on `192.168.137.1/24` and **neither needs admin rights**.

> **Idle timeout.** Windows powers the Mobile Hotspot down after ~5 minutes with no client
> attached — measured, not theoretical. The portal runs a watchdog that re-raises it, and a
> bound listener survives the gap, so you can start the portal and walk to the other device.
> To remove the timeout at the source instead, set `PeerlessTimeoutEnabled` to `0` under
> `HKLM\SYSTEM\CurrentControlSet\Services\icssvc\Settings` — that one *does* need admin.

## Features

| Area | What you get |
|---|---|
| **Own network** | The host raises its own AP — no router, no existing Wi-Fi, no internet. |
| **Lobby QR** | Join QR on the *host* screen, where it has to be: the phone can't reach the dashboard before it's on the network. |
| **True P2P** | Files to a single device go over a WebRTC DataChannel, browser to browser. The server brokers the handshake and never sees a byte. Falls back to the server relay in 8 s if the direct link doesn't come up. |
| **Device-to-device** | Every signed-in device shows up as a card. Click one to send privately, or pick **Everyone (Public)** to broadcast. |
| **Bundles** | Uploading more than one file automatically groups them into a single package. The receiver sees one row, can expand it into a folder tree, and downloads everything as one ZIP (folder structure preserved). |
| **Folder upload** | Drag a whole folder into the drop zone (or use *select a folder*) — relative paths are kept. |
| **No limits** | No file-size limit, no session expiry. |
| **Fast** | Streaming multipart parser writes network → disk in 256 KB chunks (no RAM buffering), boundary scanning runs in embedded C#, and the client uploads 3 files in parallel with live speed + ETA. |
| **Invite QR** | Offline-embedded QR code (no CDN) so phones connect with one scan. |
| **Quick text** | Send a note or link as text to any target — handy for URLs and one-liners. |
| **Notifications** | Optional sound + browser notification when a file arrives (bell toggle in the header). |
| **Text preview** | Small text files (`.txt`, `.md`, `.json`, ...) open in an inline viewer with one-click copy — no download needed for notes and links. |
| **Restart-safe** | Transfers *and* sessions persist in `.meta/`; restarting the server keeps history and nobody gets logged out. |
| **Stable identity** | Re-logging in from the same device adopts your previous identity — your inbox follows you, and stale device cards don't pile up. |
| **Concurrent** | 32-worker runspace pool; several devices can upload/download simultaneously without blocking each other. |

## Security model

- **Wi-Fi only, LAN denied** — the server binds to the Wi-Fi adapter's IP only, and additionally rejects any client outside the Wi-Fi subnet. Wired/LAN interfaces never see the service. With a self-AP up this narrows to `192.168.137.0/24`.
- **Fresh AP passphrase every run** — 10 random characters from a CSPRNG, never hard-coded. WPA2 encrypts the air link.
- **Direct transfers are end-to-end encrypted** — WebRTC mandates DTLS, so the server could not read a P2P payload even if it wanted to. It only ever sees offers, answers and ICE candidates.
- **Lobby is host-only** — `/lobby` shows the Wi-Fi passphrase, so it is served exclusively to the host's own IP.
- **Password-protected** — one shared password; sessions are HttpOnly cookies backed by 32-byte CSPRNG ids.
- **Targeted transfers stay private** — a file sent to a specific device can only be downloaded by the sender and that device (`403` otherwise).
- **Path traversal blocked** — uploaded filenames are sanitized per segment; `..`, absolute paths, and invalid characters are stripped.
- Intended for **trusted local networks**. Traffic is plain HTTP — do not expose the port to the internet.

## Configuration

Edit the settings block at the top of `LocalFilePortal.ps1`:

| Variable | Default | Meaning |
|---|---|---|
| `$Global:Password` | `hako123` | Shared sign-in password |
| `$Global:Port` | `8080` | TCP port (>1024 needs no admin) |
| `$Global:ShareFolder` | `C:\SharedTransfer` | Where uploaded files are stored |
| `$Global:MaxThreads` | `32` | Concurrent request workers |
| `$Global:DeviceTTL` | 5 min | How recently a device must be seen to count as *online* |
| `$Global:SelfAp` | `$true` | Raise our own access point at startup |
| `$Global:ApSsid` | `FTPHAKAN` | SSID prefix; a 4-hex suffix is appended per run |
| `$Global:P2P` | `$true` | Offer the direct browser-to-browser path |

## HTTP endpoints

| Route | Method | Purpose |
|---|---|---|
| `/` | GET/POST | Login page / password submit |
| `/dashboard` | GET | Main UI |
| `/api/state` | GET | Devices + transfers JSON (polled every 4 s) |
| `/upload?target=<pubId\|public>&bundle=<id>` | POST | Streaming multipart upload |
| `/download?id=<transferId>` | GET | Single-file download |
| `/api/zip` | POST | Bulk ZIP (`id=` repeated and/or `bundle=`) |
| `/api/delete` | POST | Delete own transfer (`id=`) or bundle (`bundle=`) |
| `/api/nick` | POST | Rename device |
| `/api/peek?id=<transferId>` | GET | Inline text preview (small text files) |
| `/lobby` | GET | Host-screen join page (join QR + portal QR). Host IP only. |
| `/api/lobby` | GET | Signed-in device count for the lobby. Host IP only. |
| `/rtc/signal` | POST | WebRTC handshake relay (`to=`, `kind=offer\|answer\|ice\|bye`, `data=`) |
| `/qr.js` | GET | Embedded QR library |
| `/logout` | GET | End session |

`/api/state` also carries a `signals[]` mailbox (drained on read) and a `p2p` flag.

## Files

| File | Purpose |
|---|---|
| `LocalFilePortal.ps1` | The portal itself |
| `StartPortalHidden.vbs` | Launch hidden in the background (writes `portal.pid`) |
| `StopPortal.vbs` | Kill the portal **and** shut the access point down |
| `StopAccessPoint.ps1` | Hotspot teardown on its own; safe to run any time |

## Requirements

- Windows with PowerShell 5.1+ (no modules, no admin)
- A Wi-Fi adapter — the portal supplies the network itself, so nothing needs to be connected
- First run: allow the Windows Firewall prompt for **Private networks**

## Known limits

- **Broadcast goes through the server.** P2P is used only for a single named target; sending to *Everyone* would need N connections, and the relay already does that well.
- **Direct arrivals live in the tab.** P2P files land in a *Direct Inbox* panel and are held in browser memory — save them before closing the page. Large files and iOS are better served by the relay, which streams to disk.
- **Client isolation** on some access points blocks device-to-device traffic. Windows ICS does not isolate by default; if a direct link never comes up, the relay takes over automatically.

## Credits

- QR rendering: [qrcode.js](https://github.com/davidshimjs/qrcodejs) (MIT), embedded for offline use.
