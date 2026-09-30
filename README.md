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

We chose Google's [web-server OAuth flow](https://developers.google.com/identity/protocols/oauth2/web-server) for phone-to-reader pairing, because the phone browser does the sign-in and the reader has no usable browser. That flow's confidential client secret must stay server-side, so it is **never shipped in the plugin**. This is our architecture choice, not a blanket Google requirement. Google also supports [installed-app clients](https://developers.google.com/identity/protocols/oauth2/native-app), which would be a different design with different trade-offs. The consequences:

- The **broker keeps the refresh token server-side**. It is encrypted at rest with AES-256-GCM, bound to a random `device_id`, and only the SHA-256 hash of the device credential is stored.
- The reader holds only `device_id` + `device_credential`. With them it can ask the broker for a **short-lived Google access token** (about 1 h). The access token is what uploads use. Image bytes never pass through the broker.
- **Ongoing dependency:** if the broker is down, the reader cannot get new access tokens, so it cannot upload. This is by design. The alternatives we considered and why we did not choose them:
  - Google's [limited-input device flow](https://developers.google.com/identity/protocols/oauth2/limited-input-device#allowedscopes) only allows a fixed list of scopes, and Photos Library scopes are not on it.
  - An installed-app client running on the reader would need the reader itself to complete a browser redirect.
  - Handing the web client's refresh token to the reader would put a long-lived credential on the device, and using it would still need the server-side secret.

## Pairing flow (summary)

1. On the reader: Tools → Google Photos → **Link Google account**. The plugin calls `POST /api/pairings`. It gets a public `pair_url` and a private 256-bit `poll_secret`. Only the `pair_url` goes into the QR code.
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

- **Testing mode = 7-day tokens.** While the consent screen publishing status is *Testing*, Google expires refresh tokens after 7 days for these scopes. After that, `/api/token` returns `reauth_required` and you must pair again. To avoid this, switch the app to *In production*. See Google's [refresh token expiration](https://developers.google.com/identity/protocols/oauth2#expiration) docs.
- **Verification.** `photoslibrary.appendonly` is classified by Google as a *sensitive* (not *restricted*) scope. Publicly available production apps that request sensitive scopes generally need OAuth app verification. Exceptions exist, for example personal-use apps and apps in Testing with listed test users. Unverified apps show an "unverified app" screen and are subject to user caps. Restricted-scope security assessments are not expected for this scope. Google's rules change, so check [OAuth app verification](https://support.google.com/cloud/answer/13463073) and the [unverified apps](https://support.google.com/cloud/answer/7454865) pages before sharing a deployment.
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

For local end-to-end tests, your phone cannot reach `localhost`. Complete the Google sign-in in a desktop browser at the pair URL instead. The reader (or the KOReader emulator) must also be able to reach the broker. The plugin accepts **only `https://` broker URLs**, with no loopback exception, so a plain-HTTP local broker cannot be paired from KOReader. For an end-to-end test from the reader, put the broker behind HTTPS with a certificate that the device's CA bundle trusts. Plain-HTTP local mode is for exercising the broker and phone pages only.

Checks (the Makefile runs both suites):

```sh
make check            # service typecheck + tests, Lua specs, and loopback smoke test
make smoke            # only: start real server.ts on loopback with dummy OAuth env, exercise HTTP routes (no Google calls)
make package          # runs check, then builds dist/googlephotos.koplugin.zip (plugin dir at archive root, specs excluded)
cd service && npm run check   # service only: tsc + node --test
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
2. Restart KOReader, then open Tools → Google Photos → **Broker server URL** and enter your `https://host[:port]` broker origin.
3. Tap **Link Google account** and scan the QR code. Sign in on your phone, check that the reader and phone show the same code, then confirm on both (**Codes match** on the reader).
4. Upload with either option:
   - **Upload screenshots folder** uploads from KOReader's screenshot directory.
   - **Upload a folder…** lets you pick any folder.
   Both look at one folder level only (not recursive) and skip files that are already handled.

Other menu items:

- **Resolve uncertain uploads**: for files where the connection dropped while Google was creating the item. Check the album, then mark them as uploaded or queue them again (which may duplicate).
- **Status**: shows the current link and upload state.
- **Unlink this device**: deletes the device on the broker. Upload history is kept, and if the unlink fails the credential is kept so you can retry.
- **Relink Google account**: appears in place of Link once paired.

## Validation performed so far

| Check | What it exercises | Real vs stubbed |
|---|---|---|
| `cd service && npm run check`: typecheck + 21 tests | All broker routes in-process: pairing, CSRF, state/PKCE, claimant binding, dual confirmation, re-delivery until ack, expiry, replay, exact scope, refresh errors, unpair, store failure, and races (expiry during code exchange, unpair during refresh) | Real routes and real openid-client. **Google's token endpoints are a fake injected fetch** |
| `make smoke` | The real `server.ts` process over loopback HTTP: startup, health, pairing, polling auth, phone CSRF and OAuth redirect, log redaction, body limit | Real process. Dummy OAuth env, no Google calls |
| Plugin TLS verifier: 9 cases | The plugin's production HTTP/TLS code on isolated LuaSec/LuaSocket builds, against local servers signed by a test CA. Cases: trusted host match, wrong host, untrusted CA, missing CA bundle, wildcard depth, SNI, no redirect following, no credential or body leakage (checked server-side) | Real TLS stack. Hostnames mapped to loopback. Not KOReader's bundled build, not device hardware |
| Lua plugin specs (`make check`) | Plugin core logic | Count is reported with the plugin |

**Not yet validated:** real Google OAuth or the Photos API, a real e-reader, a deployed HTTPS broker. See the acceptance checklist below.

## First live acceptance checklist (not yet performed)

None of this has been run against real Google or a real device yet. Run through it once after your first deployment:

1. Create a real Google Cloud Web client (see [Google Cloud setup](#google-cloud-setup)) and deploy the broker over HTTPS. `https://<host>/healthz` should return `{"ok":true}`.
2. Link from the reader (**Link Google account**): scan the QR, sign in on your phone, and check that the **same 6-digit code** appears on the phone and the reader. Confirm on both.
3. Put two disposable PNG/JPEG images in the screenshot folder and run **Upload screenshots folder**. Both should appear in the app-created album in Google Photos.
4. Run **Upload screenshots folder** again. No new uploads should happen.
5. Turn Wi-Fi off, or stop the broker, and add an image. Attempt an upload. It should fail cleanly: local files untouched, the ledger shows the image as pending or failed, and a later retry uploads it.
6. Restart the broker process. The reader should still get tokens and upload without re-pairing.
7. **Unlink this device**. After that, token requests with the old credential are rejected, and the reader should require pairing again.

This only verifies manual, append-only uploads. The plugin does not do full sync and never deletes anything, locally or in Google Photos.

## Limitations

- Upload is manual (**Upload screenshots folder** / **Upload a folder…**), scans one folder level only, and has no background sync. Wi-Fi is only turned on through KOReader's normal network prompt.
- Local files are never deleted.
- Upload is at-least-once, not exactly-once. If `batchCreate` times out after Google has created the item, the item is marked *uncertain*. A retry can produce a duplicate in the album. The plugin shows these rather than hiding them.
- The broker is required for every upload session (see the architecture decision above).
- Not validated live: no real Google account, real device or deployed broker was used during development. OAuth is exercised in tests against a fake token endpoint injected into openid-client. The first live pairing may surface Google console configuration issues.
- TLS hostname verification in Lua depends on the LuaSec build KOReader ships. The plugin fails closed if it cannot verify, so it may refuse to work on unusual builds.
