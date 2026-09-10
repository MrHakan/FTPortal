# FTPortal Peer Protocol

FTPortal Peer Protocol is the native app-to-app layer used by the Android, iOS and Windows editions. It lives **beside** the existing browser host rather than replacing it.

- Browsers keep using the legacy dashboard and `/download/<id>` routes.
- PowerShell keeps its mature existing session/lobby router.
- Native apps use TCP `47171` for discovery and direct transfer.
- `ftportal/2` is a backward-compatible overlay on `ftportal/1`; the original lobby → join → pull flow remains available.

## Versions

### `ftportal/1` — direct lobby pull

Endpoints:

- `GET /api/ftportal/v1/info`
- `GET /api/ftportal/v1/download/<fileId>`

A device with pending one-shot shares exposes an active lobby. Native clients scan directly connected IPv4 `/24` subnets, probe TCP `47171`, deduplicate devices by stable `deviceId`, show discovered lobbies and let the user pull a chosen file.

A v2 application still exposes these v1 endpoints and uses them for the existing manual receive flow.

### `ftportal/2` — optional offer / accept overlay

Endpoints:

- `GET /api/ftportal/v2/info`
- `POST /api/ftportal/v2/offers`
- `GET /api/ftportal/v2/transfers/<offerId>/<fileId>`

A v2 info document declares `compatible: ["ftportal/1"]` and capabilities including:

- `lobbies`
- `offers`
- `accept-decline`
- `bearer-token`
- `verification-code`

Discovery probes v2 first and automatically falls back to v1. A v1-only peer therefore remains fully usable, but the **Send my pending files** action is shown only for a peer that explicitly advertises the v2 `offers` capability.

## v1 lobby information

The information document contains the stable device identity, lobby identity, alias, platform, peer/legacy ports and pending file manifest. Example:

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

## v1 join and transfer flow

1. Device A selects one or more files.
2. Device A becomes an active lobby.
3. Device B discovers Device A and opens it from **Lobbies**.
4. Device B chooses a file.
5. Device B requests `/api/ftportal/v1/download/<fileId>`.
6. Device A atomically claims the one-shot share.
7. The source streams directly from its original location.
8. A complete transfer consumes the share; interruption releases the claim for retry.

This flow remains unchanged in v2 clients.

## v2 offer flow

v2 adds a sender-initiated UX without turning the receiver into an unauthenticated write target. The receiver still initiates the actual byte transfer **after explicit acceptance**.

1. Both devices discover each other through the normal lobby screen.
2. On a v2-capable lobby, the sender chooses **Send my pending files**.
3. The sender creates an ephemeral offer containing only its currently pending share metadata.
4. The sender generates:
   - a random 128-bit `offerId`,
   - a random 256-bit transfer token,
   - a six-digit human verification code,
   - an expiry approximately five minutes in the future.
5. The sender POSTs the offer to `/api/ftportal/v2/offers`.
6. The receiver shows the offer under **Incoming transfers** with **Accept** and **Decline** controls.
7. Both devices display the same verification code. Users can compare it when they want an extra confirmation that they are accepting the intended nearby offer.
8. Decline removes the local incoming offer without touching the sender's original files.
9. Accept asks the receiver for a destination (one destination folder for a multi-file offer).
10. The receiver downloads each file from `/api/ftportal/v2/transfers/<offerId>/<fileId>` using `Authorization: Bearer <token>`.
11. The sender verifies offer ID, expiry, token and file membership before claiming the one-shot source share.
12. Each successful file transfer consumes that share and removes it from the offer grant. Failed/interrupted files remain retryable until the offer expires or the source share is otherwise removed.

The offer itself is intentionally ephemeral and process-local. Restarting an app invalidates outstanding offers; normal persisted/pending share metadata remains governed by each platform's existing share registry.

## Offer request shape

A typical offer POST looks like:

```json
{
  "protocol": "ftportal/2",
  "offerId": "3a52f0b212aaf645b8a7701500141287",
  "senderDeviceId": "b62d...",
  "senderAlias": "Hakan-PC",
  "senderPlatform": "Windows",
  "peerPort": 47171,
  "token": "64-lowercase-hex-characters...",
  "verificationCode": "381204",
  "expiresAt": 1789075200000,
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

The receiving server derives the sender host from the TCP connection instead of trusting a host supplied in JSON. Offer bodies and manifest sizes are bounded.

## Platform receive behavior

- **Android:** Accept opens the system folder picker once. Offered files stream into that selected folder using Storage Access Framework / `DocumentFile`; incomplete output is deleted on failure.
- **iOS:** Offered files are received into an app-controlled temporary directory, size-checked, then exposed together through the system Share Sheet. FTPortal removes its temporary directory after the sheet completes.
- **Windows:** Accept opens one folder picker. Each incoming file is written to a unique `.part` file, size-checked, then renamed to its final filename. Existing filenames are not silently overwritten; a numbered filename is selected when needed.

## Browser fallback

Browser endpoints are unchanged:

- `GET /`
- `GET /api/state`
- `GET /download/<fileId>`

Browsers do not participate in v1/v2 discovery, incoming offers, bearer tokens or Accept/Decline. A browser user continues using the old FTPortal flow.

## Compatibility matrix

| Client / peer | Lobby discovery | Manual v1 pull | v2 Send / Accept | Browser fallback |
|---|---:|---:|---:|---:|
| v2 Android ↔ v2 iOS/Windows | Yes | Yes | Yes | Yes |
| v2 native ↔ v1 native | Yes, fallback | Yes | No | Yes |
| Native ↔ browser | N/A | N/A | No | Yes |
| Native ↔ PowerShell edition | Existing PowerShell/web flow | Existing flow | No | Yes |

## Security model

FTPortal Peer Protocol remains intended for **trusted local networks**.

v2 improves transfer authorization compared with an unscoped local URL:

- offers expire automatically,
- transfer tokens are random and scoped to one offer,
- only file IDs included in that offer can be fetched through its token,
- one-shot atomic claims still prevent concurrent consumption,
- a human-readable verification code is displayed on both devices,
- the receiver must explicitly Accept before bytes are fetched.

However, the bearer token is **authorization, not encryption**. v2 currently uses local HTTP and does not yet provide TLS confidentiality, cryptographic device identity or persistent trusted-device pairing. Anyone able to observe the local network traffic could potentially see unencrypted payloads or tokens. Do not expose TCP `47171` to the public Internet and do not treat the verification code as a cryptographic PAKE.

A later revision can add TLS fingerprints / certificate pinning, authenticated pairing and content checksums without removing the v1 fallback or browser surface.
