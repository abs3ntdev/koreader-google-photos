import Fastify, { type FastifyInstance, type FastifyReply, type FastifyRequest } from "fastify";
import cookie from "@fastify/cookie";
import formbody from "@fastify/formbody";
import rateLimit from "@fastify/rate-limit";
import * as client from "openid-client";
import type { Config } from "./config.ts";
import { GoogleOAuth, OAuthError } from "./google.ts";
import { MAX_MISMATCHES, PairingStore, type Pairing } from "./pairing.ts";
import { hmac, randomToken, safeEqual, sha256 } from "./secrets.ts";
import { DeviceStore } from "./store.ts";
import * as pages from "./pages.ts";

export interface AppDeps {
  config: Config;
  oauth: GoogleOAuth;
  devices: DeviceStore;
  pairings: PairingStore;
  logger?: boolean;
}

const ID_RE = /^[A-Za-z0-9_-]{16,64}$/;
const CODE_RE = /^\d{6}$/;

function bearer(req: FastifyRequest): string | undefined {
  const h = req.headers.authorization;
  if (!h || !h.startsWith("Bearer ")) return undefined;
  const v = h.slice(7).trim();
  return v.length > 0 && v.length <= 256 ? v : undefined;
}

function err(reply: FastifyReply, status: number, code: string) {
  return reply.code(status).send({ error: code });
}

export async function buildApp(deps: AppDeps): Promise<FastifyInstance> {
  const { config, oauth, devices, pairings } = deps;
  const app = Fastify({
    bodyLimit: 16 * 1024,
    trustProxy: config.trustProxy,
    logger: deps.logger
      ? {
          // Log only method and route pattern: never query strings (OAuth code/state),
          // headers (bearer credentials, cookies) or bodies.
          serializers: {
            req: (r: { method: string; routeOptions?: { url?: string } }) => ({
              method: r.method,
              url: r.routeOptions?.url ?? "",
            }),
            res: (r: { statusCode: number }) => ({ statusCode: r.statusCode }),
          },
        }
      : false,
  });

  await app.register(cookie);
  await app.register(formbody, { bodyLimit: 4096 });
  await app.register(rateLimit, { global: true, max: 120, timeWindow: "1 minute" });

  app.addHook("onSend", async (_req, reply, payload) => {
    reply.header("Cache-Control", "no-store");
    reply.header("Pragma", "no-cache");
    // no-referrer also makes browser form POSTs send Origin: null, failing CSRF.
    // same-origin retains our origin while withholding pairing URLs from Google.
    reply.header("Referrer-Policy", "same-origin");
    reply.header("X-Content-Type-Options", "nosniff");
    reply.header("X-Frame-Options", "DENY");
    reply.header(
      "Content-Security-Policy",
      "default-src 'none'; style-src 'unsafe-inline'; form-action 'self' https://accounts.google.com; frame-ancestors 'none'; base-uri 'none'",
    );
    if (config.secureCookies) reply.header("Strict-Transport-Security", "max-age=31536000");
    return payload;
  });

  app.setErrorHandler((e: { statusCode?: number }, _req, reply) => {
    const status = e.statusCode && e.statusCode >= 400 && e.statusCode < 500 ? e.statusCode : 500;
    const code = status === 413 ? "body_too_large" : status === 429 ? "rate_limited" : status < 500 ? "bad_request" : "internal";
    if (status >= 500) app.log.error({ kind: "unhandled" }, "internal error");
    return err(reply, status, code);
  });

  const cookieOpts = {
    path: "/",
    httpOnly: true,
    secure: config.secureCookies,
    sameSite: "lax" as const,
    maxAge: Math.ceil(config.pairingTtlMs / 1000) + 300,
  };

  function browserSession(req: FastifyRequest, reply: FastifyReply): string {
    const existing = req.cookies[config.cookieName];
    if (existing && ID_RE.test(existing)) return existing;
    const sid = randomToken(32);
    reply.setCookie(config.cookieName, sid, cookieOpts);
    return sid;
  }

  const csrfFor = (sid: string, pairId: string) => hmac(config.csrfKey, "csrf", sid, pairId);

  function checkCsrf(req: FastifyRequest, pairId: string): string | undefined {
    const sid = req.cookies[config.cookieName];
    const body = req.body as Record<string, unknown> | undefined;
    const token = typeof body?.csrf === "string" ? body.csrf : "";
    if (!sid || !ID_RE.test(sid) || !safeEqual(token, csrfFor(sid, pairId))) return undefined;
    const origin = req.headers.origin;
    if (origin !== undefined && origin !== config.publicBaseUrl.origin) return undefined;
    return sid;
  }

  const html = (reply: FastifyReply, status: number, body: string) =>
    reply.code(status).type("text/html; charset=utf-8").send(body);

  // ---------------------------------------------------------------- reader API

  app.post("/api/pairings", { config: { rateLimit: { max: 10, timeWindow: "1 minute" } } }, async (_req, reply) => {
    const created = pairings.create();
    if (!created) return err(reply, 503, "busy");
    const { pairing, pollSecret } = created;
    return reply.code(201).send({
      pairing_id: pairing.id,
      pair_url: new URL(`/p/${pairing.id}`, config.publicBaseUrl).toString(),
      poll_secret: pollSecret,
      expires_in: Math.floor(config.pairingTtlMs / 1000),
      poll_interval: 3,
    });
  });

  function readerAuth(req: FastifyRequest, reply: FastifyReply): Pairing | undefined {
    const id = (req.params as { id: string }).id;
    if (!ID_RE.test(id)) {
      err(reply, 404, "not_found");
      return undefined;
    }
    const r = pairings.authReader(id, bearer(req));
    if (r === "expired") {
      err(reply, 410, "expired");
      return undefined;
    }
    if (!r) {
      // Same response for unknown id and wrong secret: no oracle.
      err(reply, 401, "unauthorized");
      return undefined;
    }
    return r;
  }

  function readerView(p: Pairing) {
    const expires_in = Math.max(0, Math.floor((p.expiresAt - Date.now()) / 1000));
    switch (p.status) {
      case "waiting":
      case "oauth_pending":
      case "exchanging":
        return { status: "waiting", expires_in };
      case "authorized":
      case "finalizing": {
        const status = p.readerConfirmed ? "reader_confirmed" : p.phoneConfirmed ? "phone_confirmed" : "authorized";
        return { status, expires_in, confirmation_code: p.code };
      }
      case "complete":
        return {
          status: "complete",
          expires_in,
          device: { device_id: p.device!.deviceId, device_credential: p.device!.credential },
        };
    }
  }

  async function maybeFinalize(p: Pairing): Promise<void> {
    if (p.status !== "authorized" || !p.phoneConfirmed || !p.readerConfirmed || !p.staged) return;
    p.status = "finalizing";
    const deviceId = randomToken(16);
    const credential = randomToken(32);
    const staged = p.staged;
    try {
      await devices.add(deviceId, sha256(credential), staged.refreshToken, staged.scope);
    } catch {
      app.log.error({ kind: "store_write_failed" }, "device store write failed");
      p.status = "authorized";
      throw new Error("store");
    }
    if (!pairings.isLive(p)) {
      // Pairing expired or was destroyed during the write: do not leave an orphan credential.
      await devices.remove(deviceId).catch(() => app.log.error({ kind: "store_write_failed" }, "orphan cleanup failed"));
      return;
    }
    p.staged = undefined;
    p.device = { deviceId, credential };
    p.status = "complete";
  }

  app.post("/api/pairings/:id/poll", { config: { rateLimit: { max: 60, timeWindow: "1 minute" } } }, async (req, reply) => {
    const p = readerAuth(req, reply);
    if (!p) return reply;
    // Both sides already consented but a previous finalize failed (e.g. transient
    // store write error): retry it here so the flow can complete.
    try {
      await maybeFinalize(p);
    } catch {
      return err(reply, 500, "internal");
    }
    return reply.send(readerView(p));
  });

  app.post("/api/pairings/:id/confirm", { config: { rateLimit: { max: 20, timeWindow: "1 minute" } } }, async (req, reply) => {
    const p = readerAuth(req, reply);
    if (!p) return reply;
    const code = (req.body as { confirmation_code?: unknown } | undefined)?.confirmation_code;
    if (typeof code !== "string" || !CODE_RE.test(code)) return err(reply, 400, "bad_request");
    if (p.status !== "authorized" || !p.code) return err(reply, 409, "not_ready");
    if (!safeEqual(code, p.code)) {
      p.mismatches += 1;
      if (p.mismatches >= MAX_MISMATCHES) {
        pairings.destroy(p);
        return err(reply, 410, "expired");
      }
      return err(reply, 400, "code_mismatch");
    }
    p.readerConfirmed = true;
    try {
      await maybeFinalize(p);
    } catch {
      return err(reply, 500, "internal");
    }
    return reply.send(readerView(p));
  });

  app.post("/api/pairings/:id/ack", async (req, reply) => {
    const p = readerAuth(req, reply);
    if (!p) return reply;
    if (p.status !== "complete") return err(reply, 409, "not_ready");
    pairings.destroy(p);
    return reply.code(204).send();
  });

  async function deviceAuth(req: FastifyRequest, reply: FastifyReply) {
    const b = bearer(req);
    const dot = b?.indexOf(".") ?? -1;
    if (!b || dot < 1) return void err(reply, 401, "unauthorized");
    const rec = devices.get(b.slice(0, dot));
    if (!rec || !safeEqual(sha256(b.slice(dot + 1)), rec.credentialHash)) return void err(reply, 401, "unauthorized");
    return rec;
  }

  app.post("/api/token", { config: { rateLimit: { max: 30, timeWindow: "1 minute" } } }, async (req, reply) => {
    const rec = await deviceAuth(req, reply);
    if (!rec) return reply;
    let result;
    try {
      result = await oauth.refresh(devices.refreshToken(rec));
    } catch (e) {
      if (e instanceof OAuthError && (e.kind === "invalid_grant" || e.kind === "scope")) {
        await devices.remove(rec.deviceId).catch(() => app.log.error({ kind: "store_write_failed" }, "remove failed"));
        return err(reply, 401, "reauth_required");
      }
      app.log.warn({ kind: "refresh_failed" }, "token refresh failed");
      return err(reply, 502, "upstream_error");
    }
    // Unpaired while refreshing: do not hand out a token or resurrect the record.
    if (devices.get(rec.deviceId)?.credentialHash !== rec.credentialHash) return err(reply, 401, "unauthorized");
    if (result.rotatedRefreshToken) {
      try {
        await devices.rotate(rec.deviceId, result.rotatedRefreshToken);
      } catch {
        app.log.error({ kind: "store_write_failed" }, "rotate failed");
        return err(reply, 500, "internal");
      }
    }
    return reply.send({
      access_token: result.accessToken,
      expires_in: result.expiresIn,
      token_type: "Bearer",
      scope: result.scope,
    });
  });

  app.delete("/api/device", async (req, reply) => {
    const rec = await deviceAuth(req, reply);
    if (!rec) return reply;
    const rt = devices.refreshToken(rec);
    try {
      await devices.remove(rec.deviceId);
    } catch {
      // Record retained on disk and in memory: the client can retry the unpair.
      app.log.error({ kind: "store_write_failed" }, "remove failed");
      return err(reply, 500, "internal");
    }
    await oauth.revoke(rt);
    return reply.code(204).send();
  });

  // ------------------------------------------------------------- phone pages

  app.get("/p/:id", async (req, reply) => {
    const id = (req.params as { id: string }).id;
    const p = ID_RE.test(id) ? pairings.get(id) : undefined;
    if (!p) return html(reply, 404, pages.expired());
    const sid = browserSession(req, reply);
    const csrf = csrfFor(sid, id);
    if (p.claimantHash && !pairings.isClaimant(p, sid)) return html(reply, 409, pages.claimed());
    switch (p.status) {
      case "waiting":
      case "oauth_pending":
        return html(reply, 200, pages.start(id, csrf, p.status === "oauth_pending"));
      case "exchanging":
        return html(reply, 200, pages.message("Finishing sign-in", "Reload this page in a moment."));
      case "authorized":
      case "finalizing":
        return html(reply, 200, p.phoneConfirmed ? pages.done() : pages.confirm(id, csrf, p.code!));
      case "complete":
        return html(reply, 200, pages.done());
    }
  });

  app.post("/p/:id/start", { config: { rateLimit: { max: 10, timeWindow: "1 minute" } } }, async (req, reply) => {
    const id = (req.params as { id: string }).id;
    const p = ID_RE.test(id) ? pairings.get(id) : undefined;
    if (!p) return html(reply, 404, pages.expired());
    const sid = checkCsrf(req, id);
    if (!sid) return html(reply, 403, pages.message("Request rejected", "Open the link from the QR code again."));
    if (p.claimantHash && !pairings.isClaimant(p, sid)) return html(reply, 409, pages.claimed());
    if (p.status !== "waiting" && p.status !== "oauth_pending") {
      return html(reply, 409, pages.message("Already signed in", "Return to the previous page."));
    }
    if (p.oauthState) pairings.takeState(p.oauthState); // invalidate any earlier attempt
    const state = client.randomState();
    const verifier = client.randomPKCECodeVerifier();
    const challenge = await client.calculatePKCECodeChallenge(verifier);
    pairings.claim(p, sid, state, verifier);
    return reply.redirect(oauth.authorizationUrl(state, challenge).toString(), 303);
  });

  app.get("/oauth/callback", { config: { rateLimit: { max: 20, timeWindow: "1 minute" } } }, async (req, reply) => {
    const q = req.query as Record<string, unknown>;
    const state = typeof q.state === "string" ? q.state : "";
    const p = state ? pairings.takeState(state) : undefined;
    if (!p || p.status !== "oauth_pending") return html(reply, 400, pages.expired());
    const sid = req.cookies[config.cookieName];
    if (!pairings.isClaimant(p, sid)) {
      // Callback delivered to a different browser than the one that started sign-in.
      pairings.destroy(p);
      return html(reply, 403, pages.message("Sign-in rejected", "This sign-in did not start in this browser. Restart pairing on the reader."));
    }
    const verifier = p.pkceVerifier!;
    p.status = "exchanging";
    const rawQuery = req.url.includes("?") ? req.url.slice(req.url.indexOf("?")) : "";
    let result;
    try {
      result = await oauth.exchange(rawQuery, state, verifier);
    } catch (e) {
      pairings.destroy(p);
      const kind = e instanceof OAuthError ? e.kind : "upstream";
      app.log.warn({ kind: `callback_${kind}` }, "oauth callback failed");
      const detail =
        kind === "scope"
          ? "Photos upload permission was not granted. Restart pairing and allow access."
          : kind === "no_refresh_token"
            ? "Google did not return offline access. Remove the app's access in your Google account and retry."
            : "Sign-in failed or was cancelled. Restart pairing on the reader.";
      return html(reply, 400, pages.message("Sign-in failed", detail));
    }
    if (!pairings.isLive(p) || p.status !== "exchanging") {
      await oauth.revoke(result.refreshToken);
      return html(reply, 410, pages.expired());
    }
    pairings.stage(p, result.refreshToken, result.scope);
    return reply.redirect(`/p/${p.id}`, 303);
  });

  app.post("/p/:id/confirm", async (req, reply) => {
    const id = (req.params as { id: string }).id;
    const p = ID_RE.test(id) ? pairings.get(id) : undefined;
    if (!p) return html(reply, 404, pages.expired());
    const sid = checkCsrf(req, id);
    if (!sid || !pairings.isClaimant(p, sid)) return html(reply, 403, pages.claimed());
    if (p.status !== "authorized") return html(reply, 409, pages.message("Nothing to confirm", "Return to the reader."));
    p.phoneConfirmed = true;
    try {
      await maybeFinalize(p);
    } catch {
      return html(reply, 500, pages.message("Error", "Could not save pairing. Try again."));
    }
    return reply.redirect(`/p/${id}`, 303);
  });

  app.get("/healthz", async (_req, reply) => reply.send({ ok: true }));

  return app;
}
