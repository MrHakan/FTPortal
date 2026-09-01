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
2. On the phone: scan the QR, tap *Join network*. No router, no internet, no existing Wi-Fi.
3. The portal opens by itself, already signed in. Transfer away.

One scan, no typing. If auto sign-in is off or the phone lands on the login page anyway, the
shared password is `hako123`.

The SSID is `FTPHAKAN-XXXX` and the passphrase is regenerated on every run — both are shown
in the console banner and on the Lobby page, and both are gone when the portal stops.

## Transports

Five ways to carry the portal. The chain is walked at startup and the first one up becomes
the **primary** — the one the QR and the banner advertise.

| # | Transport | Shares internet? | Notes |
|---|---|---|---|
| **A** | **Wi-Fi Direct autonomous GO** | **No** | Default. A closed island: clients get an address but no route out. Needs no connection profile, so it works with nothing plugged in. Leaves the machine's hotspot settings untouched. |
| B | Mobile Hotspot (`NetworkOperatorTetheringManager`) | **Yes** | Tethering *is* internet sharing — that is what the API does. Also borrows the saved hotspot SSID (see below). |
| C | **Station mode** — join a network we already know | n/a | For adapters that cannot be an AP at all. The portal joins a saved network in range (a phone's hotspot, the ship Wi-Fi) and serves from there. |
| D | **Local network (LAN)** | n/a | Raises nothing. Serves over the infrastructure network this machine already belongs to — typically the wired LAN. Fastest path where one already exists. |
| E | **Bluetooth PAN** | n/a | Off by default. ~3 Mbps measured: fine for a photo or a form, useless for anything large. Windows will not raise a PAN unattended, so pairing stays manual — the portal only binds once the adapter carries an address. |

Both self-AP paths land on `192.168.137.1/24`, get DHCP from ICS, and **neither needs admin
rights**. Swap the order with `$Global:ApPrefer = 'hotspot'`, or rewrite it outright with
`$Global:BearerOrder`.

### MultiConnect — several transports at once

With `$Global:MultiConnect = $true` (the default) the chain does not stop at the first
success. Everything that *can* come up is left running, and the listener binds every
interface, so a phone on the Wi-Fi Direct group and a laptop on the ship LAN reach the same
portal and see each other in the same device list.

What keeps that from opening the portal to the whole ship is `Test-AllowedClient`: a request
is admitted only if its source address falls inside an **active transport's** subnet. Stop a
transport and its subnet is shut out on the next connection, with no rebind.

### Which network the LAN transport picks

"The LAN" means the infrastructure network this machine belongs to — the one with a gateway,
a DHCP server, and the other people on it. That is not the same as "the wireless one", so the
choice is made from what Windows already knows rather than from the media type:

| Signal | Weight |
|---|---|
| `IPv4Connectivity = Internet` | +8 |
| `NetworkCategory = DomainAuthenticated` / `Private` | +4 / +3 |
| Has a default gateway | +2 |
| Wired | +1 |
| Profile name matches `DIRECT-*` | **−10** |

The last row matters more than it looks. A `DIRECT-*` profile is a printer, TV or camera
advertising its own Wi-Fi Direct group: you get an address and no other device on it. On the
ship laptop the Ethernet port was on `advspring.local` (domain, internet) while the Wi-Fi radio
was associated with a Canon printer — and an earlier "wireless first" rule picked the printer.

The card shows the **network** name, not the adapter name: `advspring.local`, not `Ethernet 2`.

The transport then admits *every* local subnet the host sits on, not only the one it
advertises — a host wired to Ethernet while the phones are on the site Wi-Fi would otherwise
serve one and silently lock out the other.

### Failover

A supervisor thread polls every transport every 3 seconds. When the carrying one dies it
promotes the next from the chain and **tells every signed-in device** — the message arrives as
a toast plus the notification sound, and the Lobby page redraws its QR for the new network
rather than leaving a code on screen that joins something that is gone.

The run keeps **one SSID and one passphrase** across the whole chain, so a hotspot →
Wi-Fi Direct failover does not invalidate a QR a phone already scanned.

### Switching by hand

The host screen gets a **Network** button in the dashboard header listing every transport with
its state. *Make primary* moves the portal; *Stop* closes one way in. Both are host-only —
`Test-HostRequest` accepts loopback and the portal's own bearer addresses, which a remote
client cannot forge as a source. A phone on the same AP is admitted to the portal but is not
the host and never sees the panel.

Requests do not act inline: they go into a mailbox that the supervisor thread drains, because
the WinRT access-point objects belong to that thread and nowhere else. The answer comes back
as a notice on the next poll.

> The portal refuses to stop the last remaining transport — there would be no way left to
> undo it.

Measured with Wi-Fi Direct up: DHCP is served on `192.168.137.1:67`, but the AP interface has
`Forwarding: Disabled` and tethering stays `Off` — addresses are handed out, nothing is routed.

> **Your hotspot settings are borrowed, then given back.** `ConfigureAccessPointAsync`
> overwrites the machine's saved Mobile Hotspot SSID and passphrase permanently — the change
> is not scoped to our process. If path B is used, the originals are parked in
> `ap-restore.json` and put back on exit, including after `StopPortal.vbs` kills the process.
> Path A never touches them at all.

### The hotspot idle timeout

Windows powers the Mobile Hotspot down after exactly 5 minutes with no client attached —
measured, not theoretical. You start the portal, walk to the other device, and the network is
gone. Wi-Fi Direct showed no such timeout.

Three things now stand against it, and **only the host, through the portal, may close a
transport**:

1. If the portal happens to be running elevated it clears `PeerlessTimeoutEnabled` under
   `HKLM\SYSTEM\CurrentControlSet\Services\icssvc\Settings` and restores the old value on
   exit. This is the real fix, and it is the one that needs admin.
2. Otherwise the supervisor re-raises the AP within ~3 s of noticing it went down. A bound
   `TcpListener` survives the gap — verified — so nothing needs rebinding.
3. A transport the host closes on purpose is **remembered as closed**. The periodic re-arm
   that brings failed transports back would otherwise restore it a minute later, which would
   make the Stop button look broken.

The old watchdog asked `GetInternetConnectionProfile()` first and gave up when it came back
`null` — which is exactly the no-internet case this tool exists for, and the reason the AP
still vanished at the 5-minute mark. The saved tethering manager needs no profile lookup at
all; the profile scan is now only a fallback, and it accepts any profile that owns an adapter.

### Station mode notes

Station mode uses `netsh wlan connect` against an already-saved profile, which needs no
elevation — the WinRT `Windows.Devices.WiFi` route was avoided because it demands a
location-capability consent prompt a background script cannot answer. Name preferred networks
with `$Global:StationPrefer = @('MT ADVANTAGE','my-phone')`.

Two rules keep failover from making things worse:

- **The network this machine is already on wins outright.** Re-associating drops every
  connection for several seconds, and failover is meant to keep the portal reachable, not to
  move the host somewhere else.
- **`DIRECT-*` profiles are skipped** unless named in `StationPrefer`. Those are Wi-Fi Direct
  groups belonging to a printer, a TV or a camera: joining one gets an address and no other
  device, so it looks like success, is useless, and costs the host whatever real network it
  was on.

On someone else's network the portal is a guest, so the captive portal and auto sign-in both
switch themselves off — hijacking DNS there would break every other device on that network,
and handing out free sessions would expose the portal to strangers. The same applies to the
local-network transport.

## One QR

With `$Global:CaptivePortal = $true` (the default) the portal answers **every** DNS lookup with
its own address and redirects any request whose `Host` is not ours. That is exactly what an OS
connectivity probe does after joining a network:

| OS | Probe | Wants |
|---|---|---|
| Android | `connectivitycheck.gstatic.com/generate_204` | `204` |
| iOS | `captive.apple.com/hotspot-detect.html` | body containing `Success` |
| Windows | `www.msftconnecttest.com/connecttest.txt` | `Microsoft Connect Test` |

They get a redirect instead, conclude they are behind a sign-in page, and **open the portal by
themselves**. So the Lobby shows one QR: scan, join, done. The second QR stays on the page,
dimmed, for the odd build that suppresses the sign-in sheet.

Two things make that one scan land you *inside* the portal rather than on a password box:

- The redirect carries a **per-run sign-in key** (`?k=…`), so the phone arrives already signed
  in. It is only ever issued on a network the portal raised itself, where the random WPA2
  passphrase already gated entry — never in station mode. Turn it off with
  `$Global:AutoLogin = $false` and the shared password comes back.
- The portal prefers **port 80**, so the address is `http://192.168.137.1/` with no `:8080`.
  A shorter string is a lower-density QR, which phone cameras lock onto faster. If something
  else already owns port 80 it falls back to 8080 and says so.

The trade-off is deliberate: the phone will report *no internet* on this network, which from
its point of view is the truth. Binding UDP/53 needs no elevation on Windows, and ICS was
measured not to hold that port on either bearer. If the bind does fail, the portal says so on
startup and the Lobby keeps showing both QRs rather than promising something it cannot do.

## Features

| Area | What you get |
|---|---|
| **Own network** | The host raises its own AP — no router, no existing Wi-Fi, no internet. |
| **MultiConnect** | Several transports carry the portal at once; devices on any of them share one device list. |
| **Failover** | A transport dies, the portal moves to the next one and announces it to every signed-in device. |
| **Transport switching** | Host-screen **Network** panel: make any transport primary, or close one. Only the host can. |
| **Lobby QR** | Join QR on the *host* screen, where it has to be: the phone can't reach the dashboard before it's on the network. |
| **True P2P** | Files to a single device go over a WebRTC DataChannel, browser to browser. The server brokers the handshake and never sees a byte. Falls back to the server relay in 8 s if the direct link doesn't come up. |
| **Device-to-device** | Every signed-in device shows up as a card. Click one to send privately, or pick **Everyone (Public)** to broadcast. |
| **Bundles** | Uploading more than one file automatically groups them into a single package. The receiver sees one row, can expand it into a folder tree, and downloads everything as one ZIP (folder structure preserved). |
| **Folder upload** | Drag a whole folder into the drop zone (or use *select a folder*) — relative paths are kept. |
| **No limits** | No file-size limit, no session expiry. |
| **Fast** | Streaming multipart parser writes network → disk in 256 KB chunks (no RAM buffering), boundary scanning runs in embedded C#, and the client uploads 3 files in parallel with live speed + ETA. |
| **Invite QR** | Offline-embedded QR code (no CDN) so phones connect with one scan. |
| **Quick text** | Send a note or link as text to any target — handy for URLs and one-liners. |
| **Notifications** | Bell toggle in the header. Sound on **both** directions — a rising two-note tone when something arrives, a falling one when your own send completes — plus a browser notification while the tab is hidden, and an audible alert on a transport failover. The toggle is remembered per device; turning it on plays the tone once, which is also what unlocks audio in the browser. |
| **Text preview** | Small text files (`.txt`, `.md`, `.json`, ...) open in an inline viewer with one-click copy — no download needed for notes and links. |
| **Restart-safe** | Transfers *and* sessions persist in `.meta/`; restarting the server keeps history and nobody gets logged out. |
| **Stable identity** | Re-logging in from the same device adopts your previous identity — your inbox follows you, and stale device cards don't pile up. |
| **Concurrent** | 32-worker runspace pool; several devices can upload/download simultaneously without blocking each other. |

## Security model

- **Only active transports are admitted** — the listener binds every interface (so a transport can come and go without rebinding under live uploads), and every connection is then checked against the subnets of the transports actually running. With only the self-AP up that is `192.168.137.0/24` and nothing else; a wired LAN is invisible unless the local-network transport is deliberately switched on.
- **Transport controls are host-only** — `/api/bearer` accepts loopback and the portal's own bearer addresses, which a remote client cannot forge as a source address. A phone on the same AP is signed in but cannot move or close a transport, and never sees the panel.
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
| `$Global:Port` | `80` | Preferred TCP port; needs no admin on Windows |
| `$Global:PortFallback` | `8080` | Used when something already owns port 80 |
| `$Global:ShareFolder` | `C:\SharedTransfer` | Where uploaded files are stored |
| `$Global:MaxThreads` | `32` | Concurrent request workers |
| `$Global:DeviceTTL` | 5 min | How recently a device must be seen to count as *online* |
| `$Global:SelfAp` | `$true` | Raise our own access point at startup. `$false` keeps the automatic chain off the radio entirely — including the periodic re-arm |
| `$Global:ApPrefer` | `wifidirect` | Which AP path leads; `hotspot` to prefer tethering instead |
| `$Global:BearerOrder` | `wifidirect, hotspot, station, lan` | The full fallback chain, in order |
| `$Global:MultiConnect` | `$true` | Keep every transport that comes up running, and accept clients from all of them |
| `$Global:StationFallback` | `$true` | Join a known network when no AP path works |
| `$Global:StationPrefer` | `@()` | SSIDs to try first in station mode; also the only way to allow a `DIRECT-*` profile |
| `$Global:LanBearer` | `$true` | Allow serving over the already-connected network |
| `$Global:BluetoothPan` | `$false` | Allow the Bluetooth PAN transport (~3 Mbps) |
| `$Global:HotspotKeepAlive` | `$true` | Fight the 5-minute idle shutdown; only the host may close a transport |
| `$Global:SuperviseMs` | `3000` | How often transports are health-checked |
| `$Global:AutoLogin` | `$true` | One-scan sign-in on our own network |
| `$Global:ApSsid` | `FTPHAKAN` | SSID prefix; a 4-hex suffix is appended per run |
| `$Global:CaptivePortal` | `$true` | Own DNS + redirect, so one QR is enough |
| `$Global:P2P` | `$true` | Offer the direct browser-to-browser path |

## HTTP endpoints

| Route | Method | Purpose |
|---|---|---|
| `/` | GET/POST | Login page / password submit |
| `/dashboard` | GET | Main UI |
| `/api/state?ns=<seq>` | GET | Devices + transfers JSON (polled every 4 s). `ns` is the highest notice sequence this client has already shown |
| `/api/bearers` | GET | Transport list + `isHost` |
| `/api/bearer` | POST | `op=switch\|start\|stop`, `kind=wifidirect\|hotspot\|station\|lan\|bluetooth`. Host only; queued for the supervisor, answered as a notice |
| `/upload?target=<pubId\|public>&bundle=<id>` | POST | Streaming multipart upload |
| `/download?id=<transferId>` | GET | Single-file download |
| `/api/zip` | POST | Bulk ZIP (`id=` repeated and/or `bundle=`) |
| `/api/delete` | POST | Delete own transfer (`id=`) or bundle (`bundle=`) |
| `/api/nick` | POST | Rename device |
| `/api/peek?id=<transferId>` | GET | Inline text preview (small text files) |
| `/lobby` | GET | Host-screen join page (join QR + portal QR, and a button into the portal). Host only. |
| `/api/lobby` | GET | Live transport state for the lobby: device count, SSID/passphrase, URL, sign-in key, transport list, warnings. Host only — this is what lets the QR redraw itself after a failover. |
| `/rtc/signal` | POST | WebRTC handshake relay (`to=`, `kind=offer\|answer\|ice\|bye`, `data=`) |
| `/qr.js` | GET | Embedded QR library |
| `/logout` | GET | End session |

`/api/state` also carries a `signals[]` mailbox (drained on read), a `p2p` flag, the
`bearers[]` list, `isHost`, and a `notices[]` feed with `noticeSeq` — that is how a failover
reaches every device without a websocket.

## Tests

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
powershell -ExecutionPolicy Bypass -File .\tests\Run-IsolationTests.ps1
```

78 + 10 cases, no radio and no listening socket required. `Run-Tests.ps1` parses the portal,
lifts every function out via the AST and evaluates those, so the server never starts; routes
are exercised for real over a `MemoryStream`. **Everything that reaches a radio is mocked at
script scope**, and one test asserts those mocks are still in place — an earlier version
mocked inside the test bodies, one test forgot, and the suite raised an actual Wi-Fi Direct
access point that outlived the run.

`Run-IsolationTests.ps1` is structural: the portal runs code in three runspaces, and the two
that get an explicit `InitialSessionState` will fail at request time — not parse time — if a
function calls a helper nobody added to the list. It walks the call graph from each listed
entry point and proves the closure, for functions and for every `$Global:` they touch.

## Files

| File | Purpose |
|---|---|
| `LocalFilePortal.ps1` | The portal itself |
| `StartPortalHidden.vbs` | Launch hidden in the background (writes `portal.pid`) |
| `StopPortal.vbs` | Kill the portal **and** shut the access point down |
| `StopAccessPoint.ps1` | Hotspot teardown on its own; safe to run any time |
| `tests/Run-Tests.ps1` | Behavioural suite — registry, client filter, routes, fallback chain |
| `tests/Run-IsolationTests.ps1` | Runspace session-state closure checks |

## Requirements

- Windows with PowerShell 5.1+ (no modules, no admin)
- A Wi-Fi adapter — the portal supplies the network itself, so nothing needs to be connected
- First run: allow the Windows Firewall prompt for **Private networks**

## Known limits

- **Broadcast goes through the server.** P2P is used only for a single named target; sending to *Everyone* would need N connections, and the relay already does that well.
- **Direct arrivals live in the tab.** P2P files land in a *Direct Inbox* panel and are held in browser memory — save them before closing the page. Large files and iOS are better served by the relay, which streams to disk.
- **Client isolation** on some access points blocks device-to-device traffic. Windows ICS does not isolate by default; if a direct link never comes up, the relay takes over automatically.
- **Bluetooth PAN is manual and slow.** Windows will not bring a PAN up unattended: the phone must be paired and then told to join from its own Bluetooth settings. The portal only binds once that has happened, and at ~3 Mbps it is a transport for a photo, not for a folder.
- **A failover breaks live transfers.** Devices are told and can retry, but an upload in flight when the carrier changes does not resume by itself.
- **Switching transports drops the devices on the old one** unless MultiConnect kept it running. That is why the notice says to rejoin from the lobby, and why the lobby redraws its QR.

## Credits

- QR rendering: [qrcode.js](https://github.com/davidshimjs/qrcodejs) (MIT), embedded for offline use.
