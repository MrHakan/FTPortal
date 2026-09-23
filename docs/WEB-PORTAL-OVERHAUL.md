# Web dashboard and lobby integration

The FTPHAKAN dashboard supplied the device-card and transfer-panel vocabulary.
The FTPortal PowerShell edition already implements a more advanced version of
that workflow, including sessions, private/public targets, QR onboarding and a
multi-bearer network supervisor. Do not replace it with the older FTPHAKAN script.

The Windows, Android and iOS browser hosts now serve one offline dashboard and
lobby view from `WEB/portal.html`, styled after the classic FTPHAKAN dashboard
and PowerShell lobby. The original header, invitation panel, device cards,
file queue, transfer table and two-step lobby have been restored where the
native backends support them. The offline QR library in `WEB/qr.js` provides an
address code; it does **not** contain Wi-Fi credentials or perform auto-login.
The iOS bundled copies are under `IOS/Resources/`; `node --test
WEB/tests/portal.test.mjs` verifies byte-for-byte parity. Windows embeds both
assets in its single-file executable; Android packages them from `WEB` as
assets. Each host retains its previous embedded page as a packaging fallback.

| Browser route | Contract |
| --- | --- |
| `/`, `/dashboard` | Shared file dashboard |
| `/lobby` | Active address and native-lobby status; no Wi-Fi credentials are exposed |
| `/qr.js` | Offline QR library for Invite and Lobby |
| `/api/portal` | `{platform,alias,maxUploadBytes,lobbyActive,files,addresses}` |
| `/api/state`, `/upload`, `/download/{id}` | Existing browser compatibility routes, unchanged |
| `/api/ftportal/v1/*`, `/api/ftportal/v2/*` | Native compatibility routes, unchanged |

The address list is obtained from the currently active runtime topology, and
Android uses the successfully bound port (80 or 8080). Windows omits ignored
virtual adapters; Android excludes VPN-like adapters from advertised URLs.
Native peer admission rules are unchanged. The webpage does not claim that a
browser session is a discovered native peer or that an unauthenticated browser
upload can target a private recipient. It only lists the current host; native
Nearby remains the route for device-to-device private offers.

## Remaining parity work

- A shared authenticated browser identity/targeting protocol is required before
  exposing FTPHAKAN-style public/private device cards and persistent inboxes
  across *different* hosts. Do not copy FTPHAKAN's fixed default password.
- PowerShell's Wi-Fi Direct, captive DNS, QR enrollment and multi-bearer
  failover require platform-specific equivalents. iOS cannot reliably host
  indefinitely in the background, and its browser upload is limited to 32 MiB
  by the current in-memory parser. Never present these as working everywhere.
- Add real-device tests for Wi-Fi to hotspot/LAN transitions, browser uploads,
  one-shot cancellation/retry, and each platform's packaged HTML resource.

The portal is plain HTTP for trusted local networks. No end-to-end encryption
or Internet exposure is implied.
