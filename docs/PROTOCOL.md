# Broker protocol (v1)

JSON bodies are UTF-8. Every response carries `Cache-Control: no-store`. Errors come back as `{"error":"<code>"}`. Request bodies are capped at 16 KiB, and HTML form posts at 4 KiB.

## Reader API

| Method and path | Auth | Body | Success | Errors |
|---|---|---|---|---|
| `POST /api/pairings` | none (rate-limited 10/min/IP) | `{}` | `201 {pairing_id, pair_url, poll_secret, expires_in, poll_interval}` | 503 busy |
| `POST /api/pairings/:id/poll` | `Bearer <poll_secret>` | `{}` | `200 {status, expires_in, confirmation_code?, device?}` | 401 unauthorized, 410 expired |
| `POST /api/pairings/:id/confirm` | `Bearer <poll_secret>` | `{"confirmation_code":"123456"}` | `200` same shape as poll | 400 code_mismatch / bad_request, 409 not_ready, 410 expired (after 5 mismatches), 500 |
| `POST /api/pairings/:id/ack` | `Bearer <poll_secret>` | none | `204` (pairing deleted) | 401, 409 not_ready, 410 |
| `POST /api/token` | `Bearer <device_id>.<device_credential>` | none | `200 {access_token, expires_in, token_type, scope}` | 401 unauthorized, 401 reauth_required (device deleted, re-pair), 502 upstream_error (retry later), 500 |
| `DELETE /api/device` | `Bearer <device_id>.<device_credential>` | none | `204` (record deleted, Google grant revoked best-effort) | 401, 500 (not deleted; retry) |

Poll `status` values:

- `waiting`: the phone has not finished Google sign-in.
- `authorized`: `confirmation_code` is present. Show it to the user and let them confirm.
- `phone_confirmed`: the phone has confirmed. The reader still needs to confirm.
- `reader_confirmed`: the reader has confirmed. The phone still needs to confirm.
- `complete`: `device: {device_id, device_credential}` is present. The same value is returned on every poll until `ack`. Persist it first, then call ack.

`pair_url` = `<PUBLIC_BASE_URL>/p/<pairing_id>`. It is the only value placed in the QR code.

## Phone pages (browser)

Pages use `Referrer-Policy: same-origin` in both the HTTP header and HTML meta tag. This allows same-origin form POSTs to retain their `Origin`, while withholding pairing URLs from cross-origin destinations such as Google. Do not use `no-referrer` here: browsers send `Origin: null` on navigation form POSTs under that policy, and the CSRF guard correctly rejects it. Null and foreign origins remain rejected even with a valid session cookie and CSRF token.

- `GET /p/:id` has no side effects. It sets an HttpOnly, Secure, SameSite=Lax `__Host-kgp_session` cookie and renders the page for the current state. After a pairing has been claimed, other sessions get 409 "already in use".
- `POST /p/:id/start` requires the CSRF token (an HMAC of the session and pairing) and a same-origin `Origin` if present. It claims the pairing for this session and 303s to Google.
- `GET /oauth/callback` requires a single-use `state` and the claiming session's cookie. It does the code exchange with the PKCE verifier. It requires the granted `photoslibrary.appendonly` scope and a refresh token.
- `POST /p/:id/confirm` requires the CSRF token and the claiming session. It records the phone-side confirmation.

## Google calls

- Authorization: `https://accounts.google.com/o/oauth2/v2/auth`, with `response_type=code`, `scope=https://www.googleapis.com/auth/photoslibrary.appendonly`, `state`, `code_challenge` (S256), `access_type=offline`, `prompt=consent select_account` and the configured `redirect_uri`. Ref: <https://developers.google.com/identity/protocols/oauth2/web-server>.
- Token / refresh: `https://oauth2.googleapis.com/token` (client_secret_post). Revoke: `https://oauth2.googleapis.com/revoke`.
- Reader uploads (outside the broker):
  - `POST https://photoslibrary.googleapis.com/v1/uploads` with headers `X-Goog-Upload-Protocol: raw` and `X-Goog-Upload-Content-Type`. It returns an upload token.
  - `POST /v1/mediaItems:batchCreate` with `albumId` + `newMediaItems[].simpleMediaItem.uploadToken` (at most 50).
  - `POST /v1/albums` to create the app album.
  - Refs: <https://developers.google.com/photos/library/guides/upload-media>, <https://developers.google.com/photos/library/reference/rest/v1/mediaItems/batchCreate>.
