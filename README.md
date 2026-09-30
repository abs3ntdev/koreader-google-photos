# KOReader Google Photos uploader

This is a KOReader plugin plus a small OAuth broker service. Together they let an e-reader upload images (screenshots by default) into a Google Photos album. You pair the reader with your phone by scanning a QR code and confirming a matching code on both screens.

```
reader (koplugin) ──POST /api/pairings──▶ broker ◀──phone browser (QR link, Google sign-in)
reader ──/api/token (device credential)──▶ broker ──refresh──▶ Google OAuth
reader ──uploads + mediaItems:batchCreate (short-lived access token)──▶ photoslibrary.googleapis.com
```

- `service/` is the Node 24 TypeScript broker (Fastify, plus [openid-client](https://github.com/panva/openid-client) for OAuth).
- `plugin/googlephotos.koplugin/` is the KOReader plugin (Lua).
- `docs/SECURITY.md` covers the protocol and the threat model.

## Architecture decision: the broker stays in the loop

Google's web-server OAuth flow needs a client secret. For the Photos Library scope, Google only issues long-lived refresh tokens to confidential clients. The secret **must not ship in the plugin**, because anyone could extract it. So:

- The **broker keeps the refresh token server-side**. It is encrypted at rest with AES-256-GCM, bound to a random `device_id`, and only the SHA-256 hash of the device credential is stored.
- The reader holds only `device_id` + `device_credential`. With them it can ask the broker for a **short-lived Google access token** (about 1 h). The access token is what uploads use. Image bytes never pass through the broker.
- **Ongoing dependency:** if the broker is down, the reader cannot get new access tokens, so it cannot upload. This is by design. We considered alternatives:
  - Google's device-code flow ("TV and limited input") does not allow Photos Library scopes.
  - An installed-app client with PKCE would put a "secret" on the device.
  - Handing the refresh token to the reader would mean an extractable long-lived credential and would still need the client secret to use it.

## Pairing flow (summary)

1. On the reader: Tools → Google Photos → Pair. The plugin calls `POST /api/pairings`. It gets a public `pair_url` and a private 256-bit `poll_secret`. Only the `pair_url` goes into the QR code.
2. Scan the QR with your phone. The page has no side effects until you press **Sign in with Google**. That POST is CSRF-protected and claims the pairing for this phone browser only.
3. Google sign-in uses `state` + PKCE S256, `access_type=offline` and scope `photoslibrary.appendonly` only. The callback checks the state (single use), the browser cookie and the granted scope, then stages the tokens.
4. The phone and the reader both show the same 6-digit code. Only the browser that signed in sees the code. Confirm on **both**. Nothing is released until both have confirmed.
5. The reader gets its device credential on the next poll. It stores the credential, then calls `ack`. Until the ack, a lost response can be retried with the poll secret. Pairings expire after 10 minutes.

Full endpoint contract: [docs/PROTOCOL.md](docs/PROTOCOL.md).

## Google Cloud setup

1. In <https://console.cloud.google.com/>, create a project (or pick one).
2. **APIs & Services → Library**: enable **Photos Library API**.
3. **Google Auth Platform → Branding / Audience** (the OAuth consent screen):
   - User type: *External* (or *Internal* for a Workspace-only org).
   - Add yourself (and anyone else who will pair) under **Test users** while the app is in *Testing*.
4. **Data Access → Add scope**: `https://www.googleapis.com/auth/photoslibrary.appendonly`.
5. **Clients → Create client → Web application**:
   - Authorized redirect URI: exactly `https://<your-broker-host>/oauth/callback`. For local testing, use `http://localhost:8787/oauth/callback` (Google allows http only for localhost).
   - No JavaScript origins are needed.
   - Copy the client ID and secret into the broker's environment. **Never** put them in the plugin.

### Caveats (read these)

- **Testing mode = 7-day tokens.** While the consent screen publishing status is *Testing*, Google expires refresh tokens after 7 days for these scopes. After that, `/api/token` returns `reauth_required` and you must pair again. To avoid this, switch the app to *In production*.
- **Verification.** `photoslibrary.appendonly` is a sensitive scope. An app *In production* that is used by people other than the owner needs Google's OAuth app verification. A personal app (only you, under 100 users) can usually run unverified: users see an "unverified app" warning and can proceed. A public or shared deployment needs verification, and possibly a security assessment, per Google policy. Check the current Google rules before inviting others.
- **Photos Library API changes (2025).** Since 31 March 2025, Google restricts the Library API to app-created content. Apps can upload and create albums, and add to albums they created. They cannot read the user's wider library. This plugin only uses app-created albums and `appendonly`, which remain supported. Refs: <https://developers.google.com/photos/support/updates>.
- Google may limit how many refresh tokens a client can hold per user (older ones are silently invalidated). Re-pairing many times can therefore break older devices.
- **Unpair semantics.** Unpair deletes the broker's device record, and the reader's credential stops working immediately. The broker then calls Google's revoke endpoint on a best-effort basis. Google may revoke the whole grant for this client and account, so **other readers paired to the same Google account may also need re-pairing**. If the revoke fails, the grant stays listed in your Google Account's third-party access page. Remove it there. Access tokens already issued (up to about 1 h) stay usable until they expire.

## Running the broker locally

```sh
cd service
npm ci
cp .env.example .env   # edit it
# For local dev:
#   PUBLIC_BASE_URL=http://localhost:8787
#   ALLOW_INSECURE_LOOPBACK=1
#   TOKEN_ENCRYPTION_KEY=$(openssl rand -base64 32)
set -a; . ./.env; set +a
npm start
```

For local end-to-end tests, your phone cannot reach `localhost`. Complete the Google sign-in in a desktop browser at the pair URL instead. The reader (or the KOReader emulator) must also be able to reach the broker. The plugin refuses non-HTTPS broker URLs except loopback, so use the emulator on the same machine, or a real HTTPS deployment.

Checks (the Makefile runs both suites):

```sh
make check            # service typecheck + tests, and Lua specs
make package          # dist/googlephotos.koplugin.zip
cd service && npm run check   # service only
```

## HTTPS deployment (not performed; instructions only)

The broker listens on plain HTTP on `127.0.0.1:8787` and must sit behind a TLS-terminating reverse proxy. Example with Caddy:

```
photos-pair.example.com {
    reverse_proxy 127.0.0.1:8787
}
```

- Set `PUBLIC_BASE_URL=https://photos-pair.example.com` and `TRUST_PROXY=1`. Use `TRUST_PROXY=1` only when the proxy is the sole ingress, so that per-IP rate limits see real client IPs.
- The service **refuses to start** with a non-HTTPS `PUBLIC_BASE_URL`, unless the host is loopback and `ALLOW_INSECURE_LOOPBACK=1` is set.
- Run it as an unprivileged user (a systemd unit with `ProtectSystem=strict`, `ReadWritePaths=<data dir>`). The broker creates the data dir with mode `0700` and the store file with `0600`.
- Keep `TOKEN_ENCRYPTION_KEY` in a secret manager or a root-only `EnvironmentFile` (mode 0600). If you lose it, every device must re-pair. Rotating it currently means re-pairing too.
- Back up the data file only together with the protection level of the key.
- Run a single instance only. Pairing state is in memory, so do not load-balance across replicas.
- Logs contain only method, route pattern and status. They never include query strings, headers, tokens or bodies.

## Installing the plugin

1. `make package`, then copy the `googlephotos.koplugin` folder from the zip into KOReader's `plugins/` directory on the device.
2. Restart KOReader, then go to Tools → Google Photos → Settings → Broker URL. Enter your `https://` broker origin.
3. Pair, choose a folder (the default is KOReader's screenshot directory), then **Upload new images**.

See `plugin/googlephotos.koplugin/README` notes in the plugin's own docs for manifest, retry and uncertain-upload behavior.

## Limitations

- Upload is manual ("Upload new images"). There is no background sync. Wi-Fi is only turned on through KOReader's normal network prompt.
- Local files are never deleted.
- Upload is at-least-once, not exactly-once. If `batchCreate` times out after Google has created the item, the item is marked *uncertain*. A retry can produce a duplicate in the album. The plugin shows these rather than hiding them.
- The broker is required for every upload session (see the architecture decision above).
- Not validated live: no real Google account, real device or deployed broker was used during development. OAuth is exercised in tests against a fake token endpoint injected into openid-client. The first live pairing may surface Google console configuration issues.
- TLS hostname verification in Lua depends on the LuaSec build KOReader ships. The plugin fails closed if it cannot verify, so it may refuse to work on unusual builds.
