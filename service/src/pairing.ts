import { confirmationCode, randomToken, safeEqual, sha256 } from "./secrets.ts";

export type PairStatus =
  | "waiting" // created, phone has not started OAuth
  | "oauth_pending" // phone session claimed pairing, redirected to Google
  | "exchanging" // callback received, token exchange in flight
  | "authorized" // tokens staged, both sides must confirm
  | "finalizing" // both confirmed, persisting device record
  | "complete"; // device credential ready for delivery until ack

export interface Pairing {
  id: string;
  pollSecretHash: string;
  createdAt: number;
  expiresAt: number;
  status: PairStatus;
  claimantHash?: string; // sha256(browser session id)
  oauthState?: string;
  pkceVerifier?: string;
  code?: string;
  staged?: { refreshToken: string; scope: string };
  phoneConfirmed: boolean;
  readerConfirmed: boolean;
  mismatches: number;
  device?: { deviceId: string; credential: string };
}

export const MAX_MISMATCHES = 5;
export const MAX_PAIRINGS = 1000;

export class PairingStore {
  private pairings = new Map<string, Pairing>();
  private byState = new Map<string, string>();
  private readonly ttlMs: number;
  private readonly now: () => number;

  constructor(ttlMs: number, now: () => number = Date.now) {
    this.ttlMs = ttlMs;
    this.now = now;
  }

  create(): { pairing: Pairing; pollSecret: string } | undefined {
    this.sweep();
    if (this.pairings.size >= MAX_PAIRINGS) return undefined;
    const pollSecret = randomToken(32);
    const t = this.now();
    const pairing: Pairing = {
      id: randomToken(16),
      pollSecretHash: sha256(pollSecret),
      createdAt: t,
      expiresAt: t + this.ttlMs,
      status: "waiting",
      phoneConfirmed: false,
      readerConfirmed: false,
      mismatches: 0,
    };
    this.pairings.set(pairing.id, pairing);
    return { pairing, pollSecret };
  }

  /** Live (non expired) pairing or undefined. Expired entries are destroyed. */
  get(id: string): Pairing | undefined {
    const p = this.pairings.get(id);
    if (!p) return undefined;
    if (this.now() >= p.expiresAt) {
      this.destroy(p);
      return undefined;
    }
    return p;
  }

  /** True if an id existed but is now expired (for a 410 vs 404 distinction). */
  wasExpired(id: string): boolean {
    const p = this.pairings.get(id);
    return !!p && this.now() >= p.expiresAt;
  }

  authReader(id: string, pollSecret: string | undefined): Pairing | "expired" | undefined {
    if (this.wasExpired(id)) {
      this.destroy(this.pairings.get(id)!);
      return "expired";
    }
    const p = this.get(id);
    if (!p || !pollSecret) return undefined;
    return safeEqual(sha256(pollSecret), p.pollSecretHash) ? p : undefined;
  }

  claim(p: Pairing, sessionId: string, state: string, verifier: string): void {
    p.claimantHash = sha256(sessionId);
    p.oauthState = state;
    p.pkceVerifier = verifier;
    p.status = "oauth_pending";
    this.byState.set(state, p.id);
  }

  isClaimant(p: Pairing, sessionId: string | undefined): boolean {
    return !!sessionId && !!p.claimantHash && safeEqual(sha256(sessionId), p.claimantHash);
  }

  /** Single use: the state mapping is removed on first lookup. */
  takeState(state: string): Pairing | undefined {
    const id = this.byState.get(state);
    if (!id) return undefined;
    this.byState.delete(state);
    const p = this.get(id);
    if (!p || p.oauthState !== state) return undefined;
    return p;
  }

  stage(p: Pairing, refreshToken: string, scope: string): void {
    p.staged = { refreshToken, scope };
    p.code = confirmationCode();
    p.status = "authorized";
    p.oauthState = undefined;
    p.pkceVerifier = undefined;
  }

  isLive(p: Pairing): boolean {
    return this.pairings.get(p.id) === p && this.now() < p.expiresAt;
  }

  destroy(p: Pairing): void {
    if (p.oauthState) this.byState.delete(p.oauthState);
    p.staged = undefined;
    p.device = undefined;
    this.pairings.delete(p.id);
  }

  sweep(): void {
    const t = this.now();
    for (const p of this.pairings.values()) if (t >= p.expiresAt) this.destroy(p);
  }

  get size(): number {
    return this.pairings.size;
  }
}
