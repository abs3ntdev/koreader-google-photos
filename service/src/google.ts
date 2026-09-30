import * as client from "openid-client";

export const APPENDONLY_SCOPE = "https://www.googleapis.com/auth/photoslibrary.appendonly";

// Static Google endpoints (https://developers.google.com/identity/protocols/oauth2/web-server).
// Using static metadata avoids a discovery round trip and pins the issuer.
const GOOGLE_METADATA: client.ServerMetadata = {
  issuer: "https://accounts.google.com",
  authorization_endpoint: "https://accounts.google.com/o/oauth2/v2/auth",
  token_endpoint: "https://oauth2.googleapis.com/token",
  revocation_endpoint: "https://oauth2.googleapis.com/revoke",
};

export class OAuthError extends Error {
  readonly kind: "invalid_grant" | "upstream" | "scope" | "no_refresh_token";
  constructor(kind: OAuthError["kind"], message: string) {
    super(message);
    this.kind = kind;
  }
}

export interface GoogleOAuthOptions {
  clientId: string;
  clientSecret: string;
  redirectUri: string;
  /** Injected for tests; defaults to global fetch. */
  fetch?: (url: string, init: RequestInit) => Promise<Response>;
}

export interface CodeResult {
  refreshToken: string;
  scope: string;
}

export interface AccessResult {
  accessToken: string;
  expiresIn: number;
  scope: string;
  rotatedRefreshToken?: string;
}

export class GoogleOAuth {
  private readonly config: client.Configuration;
  private readonly redirectUri: string;

  constructor(opts: GoogleOAuthOptions) {
    this.redirectUri = opts.redirectUri;
    this.config = new client.Configuration(
      GOOGLE_METADATA,
      opts.clientId,
      { redirect_uris: [opts.redirectUri] },
      client.ClientSecretPost(opts.clientSecret),
    );
    if (opts.fetch) this.config[client.customFetch] = opts.fetch as unknown as client.CustomFetch;
  }

  authorizationUrl(state: string, codeChallenge: string): URL {
    return client.buildAuthorizationUrl(this.config, {
      redirect_uri: this.redirectUri,
      scope: APPENDONLY_SCOPE,
      state,
      code_challenge: codeChallenge,
      code_challenge_method: "S256",
      access_type: "offline",
      prompt: "consent select_account",
    });
  }

  /**
   * Exchange the authorization code. `query` is the raw callback query string;
   * the URL is rebuilt from the configured redirect URI, never the Host header.
   */
  async exchange(query: string, expectedState: string, verifier: string): Promise<CodeResult> {
    const current = new URL(this.redirectUri);
    current.search = query;
    let tokens: client.TokenEndpointResponse;
    try {
      tokens = await client.authorizationCodeGrant(this.config, current, {
        expectedState,
        pkceCodeVerifier: verifier,
        idTokenExpected: false,
      });
    } catch (e) {
      throw classify(e);
    }
    const scope = tokens.scope ?? "";
    if (!scope.split(" ").includes(APPENDONLY_SCOPE)) {
      throw new OAuthError("scope", "appendonly scope not granted");
    }
    if (!tokens.refresh_token) throw new OAuthError("no_refresh_token", "no refresh token returned");
    return { refreshToken: tokens.refresh_token, scope };
  }

  async refresh(refreshToken: string): Promise<AccessResult> {
    let t: client.TokenEndpointResponse;
    try {
      t = await client.refreshTokenGrant(this.config, refreshToken);
    } catch (e) {
      throw classify(e);
    }
    const scope = t.scope ?? APPENDONLY_SCOPE;
    if (!scope.split(" ").includes(APPENDONLY_SCOPE)) throw new OAuthError("scope", "appendonly scope missing");
    return {
      accessToken: t.access_token,
      expiresIn: typeof t.expires_in === "number" ? t.expires_in : 3600,
      scope,
      rotatedRefreshToken: t.refresh_token && t.refresh_token !== refreshToken ? t.refresh_token : undefined,
    };
  }

  async revoke(refreshToken: string): Promise<void> {
    try {
      await client.tokenRevocation(this.config, refreshToken);
    } catch {
      // best effort; the local record is deleted regardless
    }
  }
}

function classify(e: unknown): OAuthError {
  const err = e as { error?: string; code?: string; cause?: { error?: string } };
  const code = err?.error ?? err?.cause?.error;
  if (code === "invalid_grant") return new OAuthError("invalid_grant", "grant invalid or revoked");
  // Never include the upstream message: it may echo request parameters.
  return new OAuthError("upstream", `oauth upstream failure (${err?.code ?? code ?? "unknown"})`);
}
