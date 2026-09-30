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

## UI, performance and transfer reliability overhaul

The classic palette, panels, invite QR and two-step lobby remain the design
reference. The dashboard now places sending and receiving side by side on desktop
and stacks them on smaller screens. Mobile transfer rows keep Download visible
without requiring a horizontal swipe. Search filters before rendering; Show more
adds 100 rows at a time. Keyboard file selection, visible focus, accessible names,
progress values and reduced-motion styling are supported.

Browser queues are capped at 200 files and deduplicated by name, size and modified
time. The current host limit is shown before sending. Each successful JSON
receipt releases its File/Blob reference immediately; only metadata for the last
100 receipts remains in the tab. Failed or cancelled entries stay selectable for
retry. Cancel queue aborts the current HTTP request and stops the remaining batch.
A host may already have saved a file when an acknowledgement is lost: retries
are explicit, and the page tells the user to check the host first. There is no
automatic upload replay. Idle network requests settle after 60 seconds; after the
browser finishes sending, the host has up to 120 seconds to acknowledge saving.

Only one portal refresh is allowed at a time. Normal refreshes occur four seconds
after completion, hidden tabs use 15 seconds, and connection failures back off to
30 seconds. An eight-second deadline bounds a stalled metadata request. Unchanged
rows, queue controls and device cards keep their DOM nodes and focus. Address QR
codes are generated only where visible. Multiple network addresses can be chosen
in the lobby; the selected address survives refreshes while it is available.

Windows has four native panels with actions next to the relevant list, copy-link
and QR/lobby shortcuts, and an expandable network detail section. Refreshes retain
selected file, lobby and offer identities, including when their row indices change.
Maintenance runs cannot overlap and shutdown cancels discovery/active transfers.
Direct peer receives now honor the global Cancel command and reject excess bytes
before writing them. Incoming offers cannot be accepted twice while a receive is
running. Background discovery occurs at most every 30 seconds unless requested
or the network changes. Unreachable v2 listeners are probed once; v1 fallback is
used for 404/405 responses. Discovery responses are limited to 256 KiB and 900 ms,
including the response body. Network snapshots are invalidated on change events,
with a one-second cache lifetime as a fallback.

Windows browser uploads stream directly into a single .part file, with bounded
buffers, two concurrent upload slots and an 8 GiB per-file limit. Exactly one file
per multipart request is accepted, including an empty file. A complete multipart
boundary is required before the file is published. Failures/cancellation remove
the partial file. Final name allocation is serialized so simultaneous same-name
uploads keep both receipts. A failure to deliver the response cannot delete an
already saved file. History uses an indeterminate total while a browser upload is
streaming because Content-Length includes the multipart envelope.

Static HTML/QR assets are cached by the native hosts. Android skips rebuilding
unchanged shares, offers and history, stops its UI ticker when the activity is
paused, and still updates consumed browser shares when it resumes. iOS avoids
publishing unchanged arrays, refreshes only in the foreground, offers multiple
file selection and a native invite link, and bases its status on actual listener
readiness. Its request accumulator now appends to one Data buffer and parses the
header once, avoiding repeated full-body copies. The 32 MiB browser limit remains.

### Regression checks

- `node --test WEB/tests/portal.test.mjs`: offline assets and contract parity,
  safe filenames, stable DOM nodes, pagination/search, queue limits, retry,
  cancellation, deadlines, offline recovery and bounded receipts.
- `npm ci --prefix WEB --ignore-scripts`,
  `WEB/node_modules/.bin/playwright install --with-deps chromium`, then
  `node WEB/tests/browser-smoke.mjs`: actual desktop/mobile browser layout,
  QR rendering under the host CSP, uploads, cancellation, search, selected
  addresses and keyboard file selection. `FTPORTAL_CHROMIUM` can select an
  installed Chromium executable for local checks.
- On Windows: `dotnet run --project WINDOWS/tests/Smoke/FTPortal.Smoke.csproj
  -c Release -r win-x64 -p:SelfContained=false -p:PublishSingleFile=false`:
  actual Kestrel uploads/downloads, empty and oversized uploads, malformed and
  multiple-part rejection, collision handling, cancellation cleanup, stable
  selections, local admission, HEAD and claim/release/consume behavior. State and
  received files are isolated in a temporary directory.

All these checks run in CI before a collective release. Real-device hotspot/VPN,
Android power management and iOS background-window testing remain manual checks.
