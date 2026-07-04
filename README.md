# Local File Portal

A **single-file PowerShell** web portal for fast device-to-device file transfer over Wi-Fi.
No installation, no admin rights, no external dependencies — just run one `.ps1` and every
device on the same Wi-Fi can exchange files through the browser.

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

1. The console prints the portal URL (e.g. `http://192.168.1.42:8080/`) and your default browser opens it automatically.
2. On another device (same Wi-Fi): open the URL — or click **Invite** in the dashboard and scan the QR code.
3. Sign in with the password (default `hako123`), pick a device name, transfer away.

## Features

| Area | What you get |
|---|---|
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

- **Wi-Fi only, LAN denied** — the server binds to the Wi-Fi adapter's IP only, and additionally rejects any client outside the Wi-Fi subnet. Wired/LAN interfaces never see the service. The script refuses to start without an active Wi-Fi connection.
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
| `/qr.js` | GET | Embedded QR library |
| `/logout` | GET | End session |

## Requirements

- Windows with PowerShell 5.1+ (no modules, no admin)
- An active Wi-Fi connection (or Windows Mobile Hotspot)
- First run: allow the Windows Firewall prompt for **Private networks**

## Credits

- QR rendering: [qrcode.js](https://github.com/davidshimjs/qrcodejs) (MIT), embedded for offline use.
