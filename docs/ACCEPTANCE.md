# Acceptance evidence and remaining constraints

## Real startup attempt, 2026-09-30

The production startup command was attempted with the actual current environment,
without dummy credentials or a substituted OAuth provider:

```text
$ npm --prefix service start
> node src/server.ts
config error: missing required env PUBLIC_BASE_URL
exit code: 2
```

Presence-only checks, which did not print any secret values, confirmed that
`PUBLIC_BASE_URL`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, and
`TOKEN_ENCRYPTION_KEY` were unset and `service/.env` did not exist. Startup
correctly refused to run without its required configuration. This is a blocked
live acceptance attempt, not a successful pairing or deployment.

No KOReader launcher was found on the current PATH. The upstream source checkout
used for API research contains `reader.lua`, but not a built `luajit` runtime.
No physical reader or deployed HTTPS broker was supplied for this task. Therefore
the packaged plugin has not been launched in the real KOReader host, and the
phone-to-reader-to-Google workflow has not been observed end to end.

## Observed local results

| Requirement | Executed check and observed result | Boundary not yet verified |
|---|---|---|
| Broker startup and phone pairing routes | A separate production `server.ts` process, with explicitly dummy configuration, passed real loopback HTTP requests for health, pairing creation, authenticated polling, CSRF checks, and the Google authorization redirect | Real Google login, consent, callback and a phone browser |
| Pairing, credential lifecycle and persistence | 22 service tests passed, including disk-write failure recovery, both confirmations, lost delivery, expiry, and refresh/unpair races | Google token endpoints in these tests are substituted |
| Plugin menu, upload and retry behavior | 54 Lua tests passed, including loading `main.lua`, menu wiring, persisted create intent, ambiguous-result handling, and credential-origin binding | KOReader host/UI boundaries and Google responses are stubbed |
| Secure reader HTTPS | 9 checks passed against real local TLS servers using the production HTTP/TLS modules and isolated LuaSocket/LuaSec builds. Wrong-host and untrusted certificates were rejected before application bytes, and redirects did not leak credentials | The physical reader's bundled libraries, CA discovery and network |
| Installable artifact | `make package` passed. ZIP integrity passed and all 13 extracted Lua files matched the source files byte-for-byte | Installation and launch on a physical reader |
| Images arriving in the user's Google Photos album | Not executed | Requires the user's configured OAuth project, consent, HTTPS broker and reader |

The artifact verified in this run is `dist/googlephotos.koplugin.zip`, SHA-256:

```text
264ce87b323f805398d8855cb608449e4d210dd35bcc74a8e8f9bc5ba8e3191a
```

The local checks establish an integrated, tested implementation, not delivery of
the live backup outcome. No Google account was connected, no image was uploaded
to Google, and no service was deployed. Follow the real setup and first-live
acceptance checklist in [the README](../README.md) to close those remaining
requirements. Do not replace that acceptance run with the dummy-config smoke
test or the mocked Google tests.
