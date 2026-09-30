# Security notes and threat model

## Secrets and where they live

| Secret | Where | Notes |
|---|---|---|
| Google client secret | broker env only | never in the plugin, never logged |
| Refresh token | broker data file, AES-256-GCM (AAD = device_id) | key from `TOKEN_ENCRYPTION_KEY` |
| Poll secret (256-bit) | reader memory during pairing | only its SHA-256 is stored; never in QR/URL |
| Device credential (256-bit) | reader settings | broker stores SHA-256 only |
| Access token (about 1 h) | reader memory | scope appendonly |
| Browser session cookie | phone | `__Host-`, HttpOnly, Secure, SameSite=Lax |

## Threats considered

- **Someone else scans or sees the QR.** The QR holds only a locator. Whoever claims the pairing first (by explicitly tapping sign-in) owns it. Any other browser gets "already in use", and the real user restarts pairing.
- **Account substitution** (an attacker signs in with their own account to capture your uploads, or makes you approve theirs). The 6-digit code is shown only to the claiming browser after OAuth completes. Both the phone and the reader must confirm, and the page warns the user to confirm only if the codes match on the device in front of them. Five wrong reader attempts destroy the pairing.
- **Link previewers / QR scanners prefetching.** GET has no side effects.
- **CSRF / login CSRF.** Forms carry an HMAC CSRF token bound to the session and pairing, and the `Origin` is checked. The OAuth `state` is single-use and bound to the claiming session cookie. A callback in any other browser destroys the pairing.
- **Replay.** State is removed on first use. Codes are single-use via PKCE and Google. After ack the pairing is gone, and expired pairings are removed on access.
- **Lost delivery.** The credential is returned repeatedly to the poll-secret holder until ack or expiry. It is never exposed to anyone else.
- **Races.** Status transitions are synchronous before each await (`exchanging`, `finalizing`). After an await, liveness is rechecked. A token from a late exchange is revoked. Device records created for a pairing that died are removed. Refresh never resurrects a deleted device.
- **Storage.** Mutations are serialized: 0600 temp file, fsync, then rename. The rename is the commit point, after which memory is updated. Failures before the rename leave both memory and disk unchanged, and the client gets a 500 it can retry (for example, a failed unpair keeps the record). The directory fsync after the rename is best effort. If it fails, a warning is logged and crash durability of that last write is unknown, so use a filesystem that supports directory fsync (ext4, xfs, btrfs). The data dir must already be 0700 and owned by the service user. The service refuses to start otherwise and never chmods an existing directory.
- **Logging.** The Fastify logger only records method, route pattern and status code.
- **Transport.** The broker refuses non-HTTPS public URLs outside explicit loopback dev mode. The plugin enforces TLS peer and hostname verification itself, because KOReader's default LuaSec path uses `verify="none"`. See the plugin docs.
- **Abuse.** Per-IP rate limits apply, with at most 1000 concurrent pairings, and bodies are capped.

## Residual risks

- Anyone who compromises the broker host plus its env gets refresh tokens (append-only Photos access) for all paired accounts.
- A stolen reader credential lets an attacker add media to the victim's library until the device is unpaired. It cannot read or delete anything.
- In-memory pairing state is lost on restart. Users just pair again.
- Rate limits are per process and per IP. Behind a proxy, `TRUST_PROXY=1` is required and must be safe.
