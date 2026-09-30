import { hkdfSync } from "node:crypto";
import path from "node:path";

export interface Config {
  publicBaseUrl: URL;
  redirectUri: string;
  googleClientId: string;
  googleClientSecret: string;
  encryptionKey: Buffer; // 32 bytes, AES-256-GCM for refresh tokens
  csrfKey: Buffer; // derived from encryptionKey
  dataFile: string;
  pairingTtlMs: number;
  host: string;
  port: number;
  trustProxy: boolean;
  secureCookies: boolean;
  cookieName: string;
}

const LOOPBACK = new Set(["localhost", "127.0.0.1", "[::1]"]);

export class ConfigError extends Error {}

function required(env: NodeJS.ProcessEnv, name: string): string {
  const v = env[name];
  if (!v || !v.trim()) throw new ConfigError(`missing required env ${name}`);
  return v.trim();
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const publicBaseUrl = new URL(required(env, "PUBLIC_BASE_URL"));
  const loopback = LOOPBACK.has(publicBaseUrl.hostname);
  const allowInsecure = env.ALLOW_INSECURE_LOOPBACK === "1";
  if (publicBaseUrl.protocol !== "https:") {
    if (!(publicBaseUrl.protocol === "http:" && loopback && allowInsecure)) {
      throw new ConfigError(
        "PUBLIC_BASE_URL must be https (plain http only allowed for loopback with ALLOW_INSECURE_LOOPBACK=1)",
      );
    }
  }
  if (publicBaseUrl.pathname !== "/" || publicBaseUrl.search || publicBaseUrl.hash || publicBaseUrl.username || publicBaseUrl.password) {
    throw new ConfigError("PUBLIC_BASE_URL must be an origin without credentials, path, query or fragment");
  }
  const keyB64 = required(env, "TOKEN_ENCRYPTION_KEY");
  const encryptionKey = Buffer.from(keyB64, "base64");
  if (encryptionKey.length !== 32) {
    throw new ConfigError("TOKEN_ENCRYPTION_KEY must be 32 bytes, base64 encoded (openssl rand -base64 32)");
  }
  const csrfKey = Buffer.from(hkdfSync("sha256", encryptionKey, Buffer.alloc(0), "kgp-csrf-v1", 32));
  const secure = publicBaseUrl.protocol === "https:";
  const ttlSec = Number(env.PAIRING_TTL_SECONDS ?? "600");
  if (!Number.isInteger(ttlSec) || ttlSec < 60 || ttlSec > 1800) {
    throw new ConfigError("PAIRING_TTL_SECONDS must be an integer between 60 and 1800");
  }
  return {
    publicBaseUrl,
    redirectUri: new URL("/oauth/callback", publicBaseUrl).toString(),
    googleClientId: required(env, "GOOGLE_CLIENT_ID"),
    googleClientSecret: required(env, "GOOGLE_CLIENT_SECRET"),
    encryptionKey,
    csrfKey,
    dataFile: path.resolve(env.DATA_FILE ?? "./data/devices.json"),
    pairingTtlMs: ttlSec * 1000,
    host: env.HOST ?? "127.0.0.1",
    port: Number(env.PORT ?? "8787"),
    trustProxy: env.TRUST_PROXY === "1",
    secureCookies: secure,
    // __Host- prefix requires Secure; only the loopback dev mode falls back.
    cookieName: secure ? "__Host-kgp_session" : "kgp_session_dev",
  };
}
