// Exercises the production entry point over real loopback HTTP, without calling Google.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { once } from "node:events";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
const temp = await mkdtemp(path.join(process.env.JCODE_SCRATCH_DIR || tmpdir(), "photos-http-smoke-"));
const publicOrigin = "http://127.0.0.1:8787";
let logs = "";
const child = spawn(process.execPath, ["src/server.ts"], {
  cwd: path.join(root, "service"),
  env: {
    ...process.env,
    HOST: "127.0.0.1",
    PORT: "0",
    PUBLIC_BASE_URL: publicOrigin,
    ALLOW_INSECURE_LOOPBACK: "1",
    GOOGLE_CLIENT_ID: "smoke-client.apps.googleusercontent.com",
    GOOGLE_CLIENT_SECRET: "smoke-client-secret-not-a-real-secret",
    TOKEN_ENCRYPTION_KEY: randomBytes(32).toString("base64"),
    DATA_FILE: path.join(temp, "data", "devices.json"),
    TRUST_PROXY: "0",
    PAIRING_TTL_SECONDS: "600",
  },
  stdio: ["ignore", "pipe", "pipe"],
});
const exited = once(child, "exit");
const timeout = setTimeout(() => child.kill("SIGKILL"), 30_000);
let resolveAddress;
let rejectAddress;
const address = new Promise((resolve, reject) => {
  resolveAddress = resolve;
  rejectAddress = reject;
});
function collect(chunk) {
  logs += chunk.toString();
  const match = logs.match(/Server listening at (http:\/\/127\.0\.0\.1:\d+)/);
  if (match) resolveAddress(match[1]);
}
child.stdout.on("data", collect);
child.stderr.on("data", collect);
child.once("error", rejectAddress);
child.once("exit", (code) => rejectAddress(new Error(`Service exited before startup (${code})`)));

try {
  const origin = await address;
  const request = (route, options = {}) => fetch(new URL(route, origin), {
    ...options,
    redirect: "manual",
    signal: AbortSignal.timeout(5000),
  });
  const health = await request("/healthz");
  assert.equal(health.status, 200);
  assert.deepEqual(await health.json(), { ok: true });

  const created = await request("/api/pairings", {
    method: "POST", headers: { "Content-Type": "application/json" }, body: "{}",
  });
  assert.equal(created.status, 201);
  assert.equal(created.headers.get("cache-control"), "no-store");
  const pair = await created.json();
  assert.equal(pair.pair_url, `${publicOrigin}/p/${pair.pairing_id}`);
  assert.ok(pair.poll_secret.length >= 43);
  assert.ok(!pair.pair_url.includes(pair.poll_secret));
  const pollPath = `/api/pairings/${pair.pairing_id}/poll`;
  assert.equal((await request(pollPath, { method: "POST" })).status, 401);
  const poll = await request(pollPath, {
    method: "POST", headers: { Authorization: `Bearer ${pair.poll_secret}` },
  });
  assert.equal(poll.status, 200);
  assert.equal((await poll.json()).status, "waiting");

  const page = await request(`/p/${pair.pairing_id}`);
  assert.equal(page.status, 200);
  assert.equal(page.headers.get("referrer-policy"), "same-origin");
  assert.equal(page.headers.get("x-frame-options"), "DENY");
  const cookie = page.headers.get("set-cookie");
  assert.ok(cookie?.includes("HttpOnly"));
  const html = await page.text();
  assert.ok(!html.includes(pair.poll_secret));
  const csrf = html.match(/name="csrf"\s+value="([^"]+)"/)?.[1];
  assert.ok(csrf, "Phone page must expose its form CSRF token");
  const startOptions = {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
      Cookie: cookie.split(";")[0],
      Origin: publicOrigin,
      Referer: `${publicOrigin}/p/${pair.pairing_id}`,
    },
    body: new URLSearchParams({ csrf }).toString(),
  };
  for (const rejectedOrigin of ["https://attacker.invalid", "null"]) {
    const headers = { ...startOptions.headers, Origin: rejectedOrigin };
    delete headers.Referer;
    assert.equal((await request(`/p/${pair.pairing_id}/start`, {
      ...startOptions, headers,
    })).status, 403);
  }
  const started = await request(`/p/${pair.pairing_id}/start`, startOptions);
  assert.equal(started.status, 303);
  const google = new URL(started.headers.get("location"));
  assert.equal(google.origin, "https://accounts.google.com");
  assert.equal(google.searchParams.get("redirect_uri"), `${publicOrigin}/oauth/callback`);
  assert.equal(google.searchParams.get("code_challenge_method"), "S256");
  assert.equal(google.searchParams.get("scope"), "https://www.googleapis.com/auth/photoslibrary.appendonly");
  assert.ok(google.searchParams.get("state"));

  const marker = "smoke-query-value-must-not-be-logged";
  assert.equal((await request(`/oauth/callback?state=unknown&code=${marker}`)).status, 400);
  assert.equal((await request("/api/token", { method: "POST" })).status, 401);
  assert.equal((await request("/api/pairings", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ oversized: "x".repeat(20_000) }),
  })).status, 413);

  child.kill("SIGTERM");
  await exited;
  assert.ok(!logs.includes(marker), "OAuth query values must not appear in production logs");
  assert.ok(!logs.includes(pair.poll_secret), "Polling credentials must not appear in production logs");
  console.log("Production HTTP smoke passed: startup, pairing, auth guards, phone form, PKCE redirect, body limit, log redaction.");
  console.log("No Google account was contacted. Live Google OAuth and KOReader hardware remain separate acceptance checks.");
} finally {
  if (child.exitCode === null && child.signalCode === null) {
    child.kill("SIGTERM");
    await exited;
  }
  clearTimeout(timeout);
  await rm(temp, { recursive: true, force: true });
}
