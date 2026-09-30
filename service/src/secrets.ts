import { createCipheriv, createDecipheriv, createHash, createHmac, randomBytes, timingSafeEqual } from "node:crypto";

/** 256-bit url-safe random token. */
export function randomToken(bytes = 32): string {
  return randomBytes(bytes).toString("base64url");
}

export function sha256(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("base64url");
}

export function safeEqual(a: string, b: string): boolean {
  const ab = Buffer.from(a, "utf8");
  const bb = Buffer.from(b, "utf8");
  if (ab.length !== bb.length) return false;
  return timingSafeEqual(ab, bb);
}

export function hmac(key: Buffer, ...parts: string[]): string {
  const h = createHmac("sha256", key);
  for (const p of parts) h.update(`${p.length}:${p}`);
  return h.digest("base64url");
}

/** Uniformly random 6 digit code. */
export function confirmationCode(): string {
  // rejection sampling to avoid modulo bias
  for (;;) {
    const n = randomBytes(4).readUInt32BE(0);
    if (n < 4_294_000_000) return String(n % 1_000_000).padStart(6, "0");
  }
}

export interface Sealed {
  iv: string;
  ct: string;
  tag: string;
}

export function seal(key: Buffer, plaintext: string, aad: string): Sealed {
  const iv = randomBytes(12);
  const c = createCipheriv("aes-256-gcm", key, iv);
  c.setAAD(Buffer.from(aad, "utf8"));
  const ct = Buffer.concat([c.update(plaintext, "utf8"), c.final()]);
  return { iv: iv.toString("base64"), ct: ct.toString("base64"), tag: c.getAuthTag().toString("base64") };
}

export function open(key: Buffer, s: Sealed, aad: string): string {
  const d = createDecipheriv("aes-256-gcm", key, Buffer.from(s.iv, "base64"));
  d.setAAD(Buffer.from(aad, "utf8"));
  d.setAuthTag(Buffer.from(s.tag, "base64"));
  return Buffer.concat([d.update(Buffer.from(s.ct, "base64")), d.final()]).toString("utf8");
}
