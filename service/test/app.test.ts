import { test, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { chmod, mkdir, mkdtemp, readFile, stat, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { buildApp } from "../src/app.ts";
import { loadConfig } from "../src/config.ts";
import { APPENDONLY_SCOPE, GoogleOAuth } from "../src/google.ts";
import { PairingStore } from "../src/pairing.ts";
import { DeviceStore } from "../src/store.ts";
import type { FastifyInstance } from "fastify";

// Fake Google token endpoint. It records requests and answers according to the
// scenario configured by each test. It does NOT implement PKCE checks itself;
// tests assert the verifier openid-client sent matches the challenge in the auth URL.
interface TokenCall {
  url: string;
  params: URLSearchParams;
}
let calls: TokenCall[];
let tokenResponder: (params: URLSearchParams) => { status: number; body: unknown };
// When set, token-endpoint responses wait for this promise (to interleave requests).
let tokenGate: Promise<void> | undefined;

const fakeFetch = async (input: string | URL | Request, init?: RequestInit) => {
  const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
  const params = new URLSearchParams(String(init?.body ?? ""));
  calls.push({ url, params });
  if (url === "https://oauth2.googleapis.com/revoke") return new Response(null, { status: 200 });
  if (tokenGate) await tokenGate;
  const { status, body } = tokenResponder(params);
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
};

const RT = "1//refresh-token-secret";
function okCodeExchange(params: URLSearchParams) {
  if (params.get("grant_type") === "authorization_code") {
    return {
      status: 200,
      body: { access_token: "ya29.first", token_type: "Bearer", expires_in: 3599, scope: APPENDONLY_SCOPE, refresh_token: RT },
    };
  }
  return { status: 200, body: { access_token: "ya29.refreshed", token_type: "Bearer", expires_in: 3599, scope: APPENDONLY_SCOPE } };
}

let dir: string;
let app: FastifyInstance;
let devices: DeviceStore;
let now: number;

beforeEach(async () => {
  calls = [];
  tokenGate = undefined;
  tokenResponder = okCodeExchange;
  dir = await mkdtemp(path.join(os.tmpdir(), "kgp-"));
  const config = loadConfig({
    PUBLIC_BASE_URL: "https://photos-pair.example.com",
    GOOGLE_CLIENT_ID: "cid.apps.googleusercontent.com",
    GOOGLE_CLIENT_SECRET: "server-only-secret",
    TOKEN_ENCRYPTION_KEY: Buffer.alloc(32, 7).toString("base64"),
    DATA_FILE: path.join(dir, "data", "devices.json"),
  });
  devices = new DeviceStore(config.dataFile, config.encryptionKey);
  await devices.load();
  now = Date.now();
  const pairings = new PairingStore(config.pairingTtlMs, () => now);
  const oauth = new GoogleOAuth({
    clientId: config.googleClientId,
    clientSecret: config.googleClientSecret,
    redirectUri: config.redirectUri,
    fetch: fakeFetch,
  });
  app = await buildApp({ config, oauth, devices, pairings });
});

afterEach(async () => {
  await app.close();
  await rm(dir, { recursive: true, force: true });
});

const COOKIE = "__Host-kgp_session";

async function createPairing() {
  const r = await app.inject({ method: "POST", url: "/api/pairings", payload: {} });
  assert.equal(r.statusCode, 201);
  return r.json() as { pairing_id: string; pair_url: string; poll_secret: string };
}

function cookieFrom(res: { headers: Record<string, unknown> }): string {
  const sc = res.headers["set-cookie"];
  const raw = Array.isArray(sc) ? sc[0] : String(sc);
  return raw.split(";")[0]!.split("=")[1]!;
}

async function openPage(id: string, sid?: string) {
  const r = await app.inject({ method: "GET", url: `/p/${id}`, cookies: sid ? { [COOKIE]: sid } : {} });
  const csrf = /name="csrf" value="([^"]+)"/.exec(r.body)?.[1];
  return { res: r, sid: sid ?? (r.headers["set-cookie"] ? cookieFrom(r) : undefined), csrf };
}

async function startOAuth(id: string, sid: string, csrf: string) {
  const r = await app.inject({
    method: "POST",
    url: `/p/${id}/start`,
    cookies: { [COOKIE]: sid },
    payload: `csrf=${encodeURIComponent(csrf)}`,
    headers: { "content-type": "application/x-www-form-urlencoded", origin: "https://photos-pair.example.com" },
  });
  return r;
}

function callback(query: string, sid?: string) {
  return app.inject({ method: "GET", url: `/oauth/callback?${query}`, cookies: sid ? { [COOKIE]: sid } : {} });
}

function poll(id: string, secret: string) {
  return app.inject({ method: "POST", url: `/api/pairings/${id}/poll`, headers: { authorization: `Bearer ${secret}` }, payload: {} });
}

function readerConfirm(id: string, secret: string, code: string) {
  return app.inject({
    method: "POST",
    url: `/api/pairings/${id}/confirm`,
    headers: { authorization: `Bearer ${secret}` },
    payload: { confirmation_code: code },
  });
}

async function phoneConfirm(id: string, sid: string) {
  const page = await openPage(id, sid);
  return app.inject({
    method: "POST",
    url: `/p/${id}/confirm`,
    cookies: { [COOKIE]: sid },
    payload: `csrf=${encodeURIComponent(page.csrf!)}`,
    headers: { "content-type": "application/x-www-form-urlencoded" },
  });
}

/** Runs the flow up to a staged OAuth result. */
async function authorize() {
  const pair = await createPairing();
  const page = await openPage(pair.pairing_id);
  const start = await startOAuth(pair.pairing_id, page.sid!, page.csrf!);
  assert.equal(start.statusCode, 303);
  const auth = new URL(start.headers.location as string);
  const state = auth.searchParams.get("state")!;
  const cb = await callback(`code=authcode&state=${state}&scope=${encodeURIComponent(APPENDONLY_SCOPE)}`, page.sid);
  return { pair, sid: page.sid!, auth, state, cb };
}

async function fullPair() {
  const a = await authorize();
  const code = (await poll(a.pair.pairing_id, a.pair.poll_secret)).json().confirmation_code as string;
  await phoneConfirm(a.pair.pairing_id, a.sid);
  const done = await readerConfirm(a.pair.pairing_id, a.pair.poll_secret, code);
  const device = done.json().device as { device_id: string; device_credential: string };
  return { ...a, code, device, bearer: `${device.device_id}.${device.device_credential}` };
}

test("QR URL carries only the public pairing locator, never the poll secret", async () => {
  const pair = await createPairing();
  assert.equal(pair.pair_url, `https://photos-pair.example.com/p/${pair.pairing_id}`);
  assert.ok(!pair.pair_url.includes(pair.poll_secret));
  assert.ok(Buffer.from(pair.poll_secret, "base64url").length >= 32);
});

test("full pairing: PKCE+state auth URL, both confirmations, credential delivered until ack, token vending", async () => {
  const a = await authorize();
  const p = a.auth.searchParams;
  assert.equal(a.auth.origin + a.auth.pathname, "https://accounts.google.com/o/oauth2/v2/auth");
  assert.equal(p.get("scope"), APPENDONLY_SCOPE);
  assert.equal(p.get("redirect_uri"), "https://photos-pair.example.com/oauth/callback");
  assert.equal(p.get("code_challenge_method"), "S256");
  assert.equal(p.get("access_type"), "offline");
  assert.equal(p.get("include_granted_scopes"), null);
  assert.equal(a.cb.statusCode, 303);

  const tokenCall = calls.find((c) => c.params.get("grant_type") === "authorization_code")!;
  const { createHash } = await import("node:crypto");
  const verifier = tokenCall.params.get("code_verifier")!;
  assert.equal(createHash("sha256").update(verifier).digest("base64url"), p.get("code_challenge"));
  assert.equal(tokenCall.params.get("client_secret"), "server-only-secret");

  const s1 = (await poll(a.pair.pairing_id, a.pair.poll_secret)).json();
  assert.equal(s1.status, "authorized");
  assert.match(s1.confirmation_code, /^\d{6}$/);
  const phonePage = await openPage(a.pair.pairing_id, a.sid);
  assert.ok(phonePage.res.body.includes(s1.confirmation_code));

  // Phone confirm alone releases nothing.
  assert.equal((await phoneConfirm(a.pair.pairing_id, a.sid)).statusCode, 303);
  const s2 = (await poll(a.pair.pairing_id, a.pair.poll_secret)).json();
  assert.equal(s2.status, "phone_confirmed");
  assert.equal(s2.device, undefined);

  const done = await readerConfirm(a.pair.pairing_id, a.pair.poll_secret, s1.confirmation_code);
  assert.equal(done.json().status, "complete");
  const dev = done.json().device;

  // Lost response: polling again yields the same credential until ack.
  const again = (await poll(a.pair.pairing_id, a.pair.poll_secret)).json();
  assert.deepEqual(again.device, dev);
  const ack = await app.inject({ method: "POST", url: `/api/pairings/${a.pair.pairing_id}/ack`, headers: { authorization: `Bearer ${a.pair.poll_secret}` } });
  assert.equal(ack.statusCode, 204);
  assert.equal((await poll(a.pair.pairing_id, a.pair.poll_secret)).statusCode, 401);

  const tok = await app.inject({ method: "POST", url: "/api/token", headers: { authorization: `Bearer ${dev.device_id}.${dev.device_credential}` } });
  assert.equal(tok.statusCode, 200);
  assert.equal(tok.json().access_token, "ya29.refreshed");
  assert.equal(tok.headers["cache-control"], "no-store");
  assert.ok(!JSON.stringify(tok.json()).includes(RT), "refresh token never leaves the service");
});

test("refresh token persisted encrypted with 0600 file and 0700 dir", async () => {
  await fullPair();
  const file = path.join(dir, "data", "devices.json");
  const raw = await readFile(file, "utf8");
  assert.ok(!raw.includes(RT));
  assert.equal((await stat(file)).mode & 0o777, 0o600);
  assert.equal((await stat(path.dirname(file))).mode & 0o777, 0o700);
});

test("device survives restart via encrypted store", async () => {
  const { device } = await fullPair();
  const cfgKey = Buffer.alloc(32, 7);
  const reloaded = new DeviceStore(path.join(dir, "data", "devices.json"), cfgKey);
  await reloaded.load();
  const rec = reloaded.get(device.device_id)!;
  assert.equal(reloaded.refreshToken(rec), RT);
  const wrong = new DeviceStore(path.join(dir, "data", "devices.json"), Buffer.alloc(32, 8));
  await wrong.load();
  assert.throws(() => wrong.refreshToken(wrong.get(device.device_id)!));
});

test("poll with wrong secret or unknown id is unauthorized; confirmation code hidden before OAuth", async () => {
  const pair = await createPairing();
  assert.equal((await poll(pair.pairing_id, "nope")).statusCode, 401);
  assert.equal((await poll("A".repeat(22), pair.poll_secret)).statusCode, 401);
  const w = (await poll(pair.pairing_id, pair.poll_secret)).json();
  assert.equal(w.status, "waiting");
  assert.equal(w.confirmation_code, undefined);
  assert.equal((await readerConfirm(pair.pairing_id, pair.poll_secret, "123456")).statusCode, 409);
});

test("GET pairing page has no side effects; only the claiming browser sees the code", async () => {
  const pair = await createPairing();
  // A link previewer / scanner fetching the page does not claim it.
  await openPage(pair.pairing_id);
  const victim = await openPage(pair.pairing_id);
  const start = await startOAuth(pair.pairing_id, victim.sid!, victim.csrf!);
  assert.equal(start.statusCode, 303);
  const attacker = await openPage(pair.pairing_id);
  assert.equal(attacker.res.statusCode, 409);
  const state = new URL(start.headers.location as string).searchParams.get("state")!;
  await callback(`code=c&state=${state}`, victim.sid);
  const code = (await poll(pair.pairing_id, pair.poll_secret)).json().confirmation_code;
  const other = await openPage(pair.pairing_id);
  assert.equal(other.res.statusCode, 409);
  assert.ok(!other.res.body.includes(code));
});

test("start requires valid CSRF token bound to browser session and same origin", async () => {
  const pair = await createPairing();
  const page = await openPage(pair.pairing_id);
  assert.equal((await startOAuth(pair.pairing_id, page.sid!, "forged")).statusCode, 403);
  const other = await openPage(pair.pairing_id);
  assert.equal((await startOAuth(pair.pairing_id, other.sid!, page.csrf!)).statusCode, 403);
  const crossOrigin = await app.inject({
    method: "POST",
    url: `/p/${pair.pairing_id}/start`,
    cookies: { [COOKIE]: page.sid! },
    payload: `csrf=${encodeURIComponent(page.csrf!)}`,
    headers: { "content-type": "application/x-www-form-urlencoded", origin: "https://evil.example" },
  });
  assert.equal(crossOrigin.statusCode, 403);
});

test("callback: state replay rejected, wrong browser rejected, unknown state rejected", async () => {
  const a = await authorize();
  const replay = await callback(`code=authcode&state=${a.state}`, a.sid);
  assert.equal(replay.statusCode, 400);
  assert.equal(calls.filter((c) => c.params.get("grant_type") === "authorization_code").length, 1);

  const pair = await createPairing();
  const page = await openPage(pair.pairing_id);
  const start = await startOAuth(pair.pairing_id, page.sid!, page.csrf!);
  const state = new URL(start.headers.location as string).searchParams.get("state")!;
  const otherBrowser = await callback(`code=x&state=${state}`, "B".repeat(43));
  assert.equal(otherBrowser.statusCode, 403);
  assert.equal((await poll(pair.pairing_id, pair.poll_secret)).statusCode, 401, "pairing destroyed");

  assert.equal((await callback("code=x&state=unknown")).statusCode, 400);
});

test("callback: granted scope must be exactly appendonly; missing refresh token fails closed", async () => {
  for (const scope of ["openid", `${APPENDONLY_SCOPE} https://www.googleapis.com/auth/photoslibrary.readonly`]) {
    tokenResponder = () => ({ status: 200, body: { access_token: "a", token_type: "Bearer", expires_in: 10, scope, refresh_token: "r" } });
    const a = await authorize();
    assert.equal(a.cb.statusCode, 400, scope);
    assert.equal((await poll(a.pair.pairing_id, a.pair.poll_secret)).statusCode, 401);
  }

  tokenResponder = () => ({ status: 200, body: { access_token: "a", token_type: "Bearer", expires_in: 10, scope: APPENDONLY_SCOPE } });
  const b = await authorize();
  assert.equal(b.cb.statusCode, 400);

  const c = await (async () => {
    const pair = await createPairing();
    const page = await openPage(pair.pairing_id);
    const start = await startOAuth(pair.pairing_id, page.sid!, page.csrf!);
    const state = new URL(start.headers.location as string).searchParams.get("state")!;
    return callback(`error=access_denied&state=${state}`, page.sid);
  })();
  assert.equal(c.statusCode, 400);
});

test("reader confirmation: mismatch counted, lockout after 5 attempts", async () => {
  const a = await authorize();
  const code = (await poll(a.pair.pairing_id, a.pair.poll_secret)).json().confirmation_code as string;
  const wrong = code === "000000" ? "111111" : "000000";
  for (let i = 0; i < 4; i++) assert.equal((await readerConfirm(a.pair.pairing_id, a.pair.poll_secret, wrong)).statusCode, 400);
  assert.equal((await readerConfirm(a.pair.pairing_id, a.pair.poll_secret, wrong)).statusCode, 410);
  assert.equal((await readerConfirm(a.pair.pairing_id, a.pair.poll_secret, code)).statusCode, 401);
});

test("reader confirmation alone does not release credentials", async () => {
  const a = await authorize();
  const code = (await poll(a.pair.pairing_id, a.pair.poll_secret)).json().confirmation_code;
  const r = (await readerConfirm(a.pair.pairing_id, a.pair.poll_secret, code)).json();
  assert.equal(r.status, "reader_confirmed");
  assert.equal(r.device, undefined);
});

test("expired pairing returns 410 and cannot be completed", async () => {
  const a = await authorize();
  now += 11 * 60 * 1000;
  assert.equal((await poll(a.pair.pairing_id, a.pair.poll_secret)).statusCode, 410);
  assert.equal((await openPage(a.pair.pairing_id)).res.statusCode, 404);
});

test("token endpoint: bad credential 401, invalid_grant deletes device and reports reauth_required, upstream error 502", async () => {
  const { bearer, device } = await fullPair();
  const bad = await app.inject({ method: "POST", url: "/api/token", headers: { authorization: `Bearer ${device.device_id}.wrong` } });
  assert.equal(bad.statusCode, 401);
  assert.equal(bad.json().error, "unauthorized");

  tokenResponder = () => ({ status: 500, body: { error: "server_error" } });
  const up = await app.inject({ method: "POST", url: "/api/token", headers: { authorization: `Bearer ${bearer}` } });
  assert.equal(up.statusCode, 502);
  assert.ok(devices.get(device.device_id));

  tokenResponder = () => ({ status: 400, body: { error: "invalid_grant", error_description: "Token has been expired or revoked." } });
  const re = await app.inject({ method: "POST", url: "/api/token", headers: { authorization: `Bearer ${bearer}` } });
  assert.equal(re.statusCode, 401);
  assert.equal(re.json().error, "reauth_required");
  assert.equal(devices.get(device.device_id), undefined);
  tokenResponder = okCodeExchange;
  const after = await app.inject({ method: "POST", url: "/api/token", headers: { authorization: `Bearer ${bearer}` } });
  assert.equal(after.json().error, "unauthorized");
});

test("token endpoint: refresh granting extra scopes is refused (no token, device requires re-pair)", async () => {
  const { bearer, device } = await fullPair();
  tokenResponder = () => ({
    status: 200,
    body: { access_token: "ya29.wide", token_type: "Bearer", expires_in: 3599, scope: `${APPENDONLY_SCOPE} https://www.googleapis.com/auth/photoslibrary` },
  });
  const r = await app.inject({ method: "POST", url: "/api/token", headers: { authorization: `Bearer ${bearer}` } });
  assert.equal(r.statusCode, 401);
  assert.ok(!r.body.includes("ya29.wide"));
  assert.equal(devices.get(device.device_id), undefined);
});

test("unpair deletes device, revokes at Google, credential stops working", async () => {
  const { bearer, device } = await fullPair();
  const del = await app.inject({ method: "DELETE", url: "/api/device", headers: { authorization: `Bearer ${bearer}` } });
  assert.equal(del.statusCode, 204);
  const revoke = calls.find((c) => c.url === "https://oauth2.googleapis.com/revoke")!;
  assert.equal(revoke.params.get("token"), RT);
  assert.equal(devices.get(device.device_id), undefined);
  assert.equal((await readFile(path.join(dir, "data", "devices.json"), "utf8")).includes(device.device_id), false);
  const tok = await app.inject({ method: "POST", url: "/api/token", headers: { authorization: `Bearer ${bearer}` } });
  assert.equal(tok.statusCode, 401);
});

function holdTokenEndpoint(): () => void {
  let release!: () => void;
  tokenGate = new Promise((r) => (release = r));
  return () => {
    tokenGate = undefined;
    release();
  };
}

async function until(pred: () => boolean) {
  for (let i = 0; i < 1000 && !pred(); i++) await new Promise((r) => setImmediate(r));
  assert.ok(pred(), "condition not reached");
}

const tokenCalls = (grant: string) => calls.filter((c) => c.params.get("grant_type") === grant).length;

test("race: pairing expires while code exchange is in flight -> nothing staged, new grant revoked", async () => {
  const pair = await createPairing();
  const page = await openPage(pair.pairing_id);
  const start = await startOAuth(pair.pairing_id, page.sid!, page.csrf!);
  const state = new URL(start.headers.location as string).searchParams.get("state")!;
  const release = holdTokenEndpoint();
  const cbPromise = callback(`code=c&state=${state}`, page.sid);
  await until(() => tokenCalls("authorization_code") === 1);
  now += 11 * 60 * 1000; // expire while Google has not answered yet
  release();
  const cb = await cbPromise;
  assert.equal(cb.statusCode, 410);
  const revoke = calls.find((c) => c.url.endsWith("/revoke"));
  assert.equal(revoke?.params.get("token"), RT, "late refresh token revoked");
  assert.equal((await poll(pair.pairing_id, pair.poll_secret)).statusCode, 410);
});

test("race: unpair during in-flight refresh -> no access token returned, device not resurrected", async () => {
  const { bearer, device } = await fullPair();
  tokenResponder = () => ({
    status: 200,
    body: { access_token: "ya29.late", token_type: "Bearer", expires_in: 3599, scope: APPENDONLY_SCOPE, refresh_token: "1//rotated" },
  });
  const release = holdTokenEndpoint();
  const tokPromise = app.inject({ method: "POST", url: "/api/token", headers: { authorization: `Bearer ${bearer}` } });
  await until(() => tokenCalls("refresh_token") === 1);
  const del = await app.inject({ method: "DELETE", url: "/api/device", headers: { authorization: `Bearer ${bearer}` } });
  assert.equal(del.statusCode, 204);
  release();
  const tok = await tokPromise;
  assert.equal(tok.statusCode, 401);
  assert.ok(!tok.body.includes("ya29.late"));
  assert.equal(devices.get(device.device_id), undefined);
  assert.ok(!(await readFile(path.join(dir, "data", "devices.json"), "utf8")).includes(device.device_id));
});

test("store write failure: unpair returns 500, record retained in memory and on disk, retry succeeds", async () => {
  const { bearer, device } = await fullPair();
  const dataDir = path.join(dir, "data");
  await chmod(dataDir, 0o500); // make temp-file creation fail
  try {
    const del = await app.inject({ method: "DELETE", url: "/api/device", headers: { authorization: `Bearer ${bearer}` } });
    assert.equal(del.statusCode, 500);
    assert.ok(devices.get(device.device_id), "memory unchanged");
    assert.ok((await readFile(path.join(dataDir, "devices.json"), "utf8")).includes(device.device_id), "disk unchanged");
    assert.equal(calls.some((c) => c.url.endsWith("/revoke")), false, "no revoke before durable delete");
  } finally {
    await chmod(dataDir, 0o700);
  }
  const retry = await app.inject({ method: "DELETE", url: "/api/device", headers: { authorization: `Bearer ${bearer}` } });
  assert.equal(retry.statusCode, 204);
});

test("store refuses a group/world accessible data directory instead of chmod-ing it", async () => {
  const shared = path.join(dir, "shared");
  await mkdir(shared, { mode: 0o755 });
  await chmod(shared, 0o755);
  const s = new DeviceStore(path.join(shared, "devices.json"), Buffer.alloc(32));
  await assert.rejects(() => s.load(), /group\/world/);
  assert.equal((await stat(shared)).mode & 0o777, 0o755);
});

test("security headers and body limit", async () => {
  const pair = await createPairing();
  const page = await openPage(pair.pairing_id);
  assert.match(String(page.res.headers["content-security-policy"]), /frame-ancestors 'none'/);
  assert.equal(page.res.headers["x-frame-options"], "DENY");
  assert.equal(page.res.headers["referrer-policy"], "no-referrer");
  const sc = String(page.res.headers["set-cookie"]);
  assert.match(sc, /HttpOnly/);
  assert.match(sc, /Secure/);
  assert.match(sc, /SameSite=Lax/);
  const big = await app.inject({ method: "POST", url: "/api/pairings", payload: { x: "a".repeat(20_000) } });
  assert.equal(big.statusCode, 413);
});

test("config refuses non-https public URL outside explicit loopback dev mode", () => {
  const base = {
    GOOGLE_CLIENT_ID: "c",
    GOOGLE_CLIENT_SECRET: "s",
    TOKEN_ENCRYPTION_KEY: Buffer.alloc(32).toString("base64"),
  };
  assert.throws(() => loadConfig({ ...base, PUBLIC_BASE_URL: "http://pair.example.com" }));
  assert.throws(() => loadConfig({ ...base, PUBLIC_BASE_URL: "http://localhost:8787" }));
  assert.throws(() => loadConfig({ ...base, PUBLIC_BASE_URL: "https://x.example", TOKEN_ENCRYPTION_KEY: "short" }));
  assert.throws(() => loadConfig({ ...base, PUBLIC_BASE_URL: "https://user:pw@x.example" }), /credentials/);
  const dev = loadConfig({ ...base, PUBLIC_BASE_URL: "http://localhost:8787", ALLOW_INSECURE_LOOPBACK: "1" });
  assert.equal(dev.redirectUri, "http://localhost:8787/oauth/callback");
});
