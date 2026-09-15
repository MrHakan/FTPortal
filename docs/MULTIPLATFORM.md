# FTPortal multi-platform architecture

## Shared contract

The native Android, iOS and Windows hosts intentionally keep a small interoperable contract:

- `GET /` renders a browser dashboard.
- `GET /api/state` lists currently shared one-shot files.
- `GET /download/<id>` streams one file and consumes its share record only after a completed stream.
- The source file remains untouched; FTPortal stores metadata only.
- All servers bind only for local-device use and should not be forwarded to the public Internet.

The original PowerShell edition remains feature-richer and keeps its existing API and WebRTC behavior.

## Android

The Android app starts `PortalService` as a foreground service of type `connectedDevice`. `NanoHTTPD` listens on TCP/8080. Android NSD advertises `_http._tcp.`. Files are referenced by Storage Access Framework content URIs and read via `ContentResolver` only when a peer requests them.

## iOS

The iOS app uses `NWListener` and Bonjour. Selected files remain security-scoped URLs. A custom streaming HTTP responder reads 256 KiB chunks from the source file. iOS does not permit a general-purpose third-party app to run an arbitrary local TCP server indefinitely after suspension; the app uses a background task to let an active transfer finish, but reliable hosting requires the app to remain active. This is an operating-system limitation, not a storage limitation.

## Windows

The Windows executable is a WinForms shell around an ASP.NET Core/Kestrel host. Closing the window hides it to the notification area; only **Exit FTPortal** from the tray menu actually terminates the server. The host binds all interfaces and continuously re-evaluates the preferred advertised address in this order:

1. Wi-Fi
2. Ethernet/LAN
3. Mobile Hotspot / virtual local adapter
4. Other operational private IPv4 interfaces

When no useful Wi-Fi/LAN interface exists, the dashboard and the transport supervisor can request Windows Mobile Hotspot through `NetworkOperatorTetheringManager`. Automatic attempts are serialized and backed off, and a manual stop temporarily suppresses automatic re-arming. Port 80 is preferred so the hostname works without an explicit port; 8080 and 8787 are fallback ports.

Windows HTTP and peer requests pass an active-bearer admission check before routing. Loopback is allowed for local diagnostics; remote clients must be private IPv4 addresses on a current, non-VPN subnet. Virtual host-only adapters are excluded unless Windows identifies them as a Wi-Fi Direct or Mobile Hotspot transport. Discovery uses the adapter's subnet mask where the host count is bounded, and falls back to a bounded `/24` probe for very large networks.

The native Windows dashboard tracks active send/receive byte counts, smoothed throughput, estimated progress and a bounded metadata-only history. A cancellation releases the one-shot claim and removes any `.part` destination; a successful stream consumes the share only after the response is flushed.
