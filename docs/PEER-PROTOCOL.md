# FTPortal Peer Protocol v1

FTPortal Peer Protocol v1 is the native app-to-app discovery and one-shot transfer layer used by the Android, iOS and Windows editions.

It intentionally lives beside the existing browser host instead of replacing it. A browser continues to open the normal FTPortal address and use the legacy dashboard/download flow. Native apps use a dedicated peer port and can discover active lobbies from their main screen.

## Transport

- Protocol identifier: `ftportal/1`
- Peer TCP port: `47171`
- Transport: local-network HTTP in v1
- Discovery scope: directly connected IPv4 LAN/hotspot subnet
- Discovery request: `GET /api/ftportal/v1/info`
- Native one-shot transfer: `GET /api/ftportal/v1/download/<fileId>`

The peer port is fixed even when the Windows browser host falls back between ports 80, 8080 and 8787. This makes native discovery deterministic.

## Lobby model

A device automatically exposes an active lobby when it has at least one pending one-shot share. No extra copy of the source file is created.

Native clients scan their directly connected `/24` IPv4 subnet in bounded parallel batches and probe TCP 47171. Responses are deduplicated by the stable per-installation `deviceId`. The local device ignores its own response.

`GET /api/ftportal/v1/info` returns JSON shaped like:

```json
{
  "protocol": "ftportal/1",
  "deviceId": "b62d...",
  "lobbyId": "lobby-b62d...",
  "alias": "Hakan-PC",
  "platform": "Windows",
  "peerPort": 47171,
  "legacyPort": 8080,
  "lobbyActive": true,
  "fileCount": 2,
  "files": [
    {
      "id": "8c70...",
      "name": "report.pdf",
      "size": 120034,
      "mime": "application/pdf"
    }
  ]
}
```

The `lobbyId` is currently stable for the installation and identifies the host lobby. A future protocol revision can make lobby IDs ephemeral without changing the stable device identity.

## Join and transfer flow

1. Device A selects one or more files in FTPortal.
2. Device A's `lobbyActive` becomes `true` and its files appear in `/info`.
3. Device B scans the LAN and shows Device A in **Lobbies**.
4. The user joins Device A's lobby and chooses a file.
5. Device B requests `/api/ftportal/v1/download/<fileId>` from Device A on TCP 47171.
6. Device A atomically claims the one-shot share so a second peer cannot take the same link concurrently.
7. The source file is streamed directly from its original location.
8. A completed transfer consumes the share. A failed/interrupted transfer releases the claim so it can be retried.

Android writes the incoming stream directly to the destination selected with the system document picker. Windows writes to a temporary `.part` file beside the chosen destination and atomically replaces the destination only after the full receive succeeds. iOS uses a temporary system file for the native receive and presents the system Share Sheet; the FTPortal temp directory is removed when that sheet completes.

## Browser fallback

The existing browser endpoints remain available on the legacy host port:

- `GET /`
- `GET /api/state`
- `GET /download/<fileId>`

A browser does not participate in peer discovery and does not need to understand `ftportal/1`.

## Platform status

| Edition | Peer discovery | Native lobby UI | Native receive | Legacy web host |
|---|---:|---:|---:|---:|
| Android | Yes | Yes | Yes | Yes |
| iOS | Yes | Yes | Yes | Yes |
| Windows | Yes | Yes | Yes | Yes |
| PowerShell | No (v1) | Existing PowerShell lobby | Existing PowerShell flow | Yes |

PowerShell intentionally remains on its mature existing session/router architecture in v1 instead of duplicating a second native-peer stack inside the monolithic script.

## Security and v2 direction

Peer v1 is for trusted local networks. It has no TLS identity, pairing PIN or authenticated peer session. Do not expose TCP 47171 or the browser host to the public Internet.

The protocol is versioned so a later `ftportal/2` can add TLS fingerprints, PIN/pairing, explicit prepare/accept/ack transfer sessions, push transfers, checksums and richer discovery while retaining v1 browser fallback compatibility.
