# Deploying the broker with Docker (Unraid)

No image is published to a registry. You build it yourself from `service/` and run it
on your server. It has been built and run locally with Docker. It has **not** been
tested on a real Unraid host or against live Google OAuth.

## Contract

| Item | Value |
|---|---|
| Build context | `service/` (`service/Dockerfile`) |
| Local tag | `koreader-google-photos-broker:local` |
| Base | `node:24.21.0-alpine3.24`, pinned by digest. Runs the TypeScript sources directly on Node 24, with production dependencies only (`npm ci --omit=dev`) |
| User | `99:100` (Unraid `nobody:users`). You can override it with `--user UID:GID` |
| Listen | `HOST=0.0.0.0`, `PORT=8787`, plain HTTP |
| Data | Bind-mount `/config`. The store lives at `DATA_FILE=/config/data/devices.json`. The image has no `VOLUME` instruction, so you must mount `/config` yourself |
| Health | `HEALTHCHECK` runs `GET /healthz` |
| Replicas | Exactly one. The store is a single local file |

Required env: `PUBLIC_BASE_URL` (https origin), `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`,
`TOKEN_ENCRYPTION_KEY` (`openssl rand -base64 32`). Optional env: `TRUST_PROXY=1` (recommended
behind a proxy) and `PAIRING_TTL_SECONDS`. Never set `ALLOW_INSECURE_LOOPBACK` in a
container. It exists only for local http://localhost development.

## Permissions model

The container never runs chown or chmod on anything. You set up the one appdata directory once:

```sh
mkdir -p /mnt/user/appdata/kgp-broker
chown 99:100 /mnt/user/appdata/kgp-broker
chmod 700 /mnt/user/appdata/kgp-broker
```

On first start the broker creates `/config/data` with mode 0700. It does not create `devices.json` until the first device pairs successfully, and then writes it with mode 0600.
If the data directory is group- or world-accessible, or is owned by a different UID, the broker
refuses to start. To use a different UID:GID, change both the `--user` value and the owner of
that directory. Do not run Unraid's "New Permissions" tool on this share, because it would
make the data directory group-accessible.

## Build / import on Unraid

On the Unraid host, if it has git:
```sh
git clone <this repo> /mnt/user/appdata/kgp-src && cd /mnt/user/appdata/kgp-src
docker build -t koreader-google-photos-broker:local service/
```
Or build on another machine and copy the image over:
```sh
docker build -t koreader-google-photos-broker:local service/
docker save koreader-google-photos-broker:local | gzip > kgp-broker.tar.gz
# copy to Unraid, then:
docker load < kgp-broker.tar.gz
```
To pick up base image security updates, rebuild with an updated digest in `NODE_IMAGE`.

## Option A: Unraid template

1. Copy `deploy/unraid/kgp-broker.xml` to `/boot/config/plugins/dockerMan/templates-user/my-kgp-broker.xml`.
2. In Docker, choose Add Container and select the `kgp-broker` template. Fill in the four
   required variables. The secret fields are masked.
3. Extra Parameters already sets `--user 99:100`, `--restart unless-stopped`, `--read-only`,
   `--cap-drop ALL` and `no-new-privileges`. Leave Privileged off.

## Option B: docker compose

```sh
cp deploy/broker.env.example deploy/broker.env && chmod 600 deploy/broker.env   # fill in
docker compose -f deploy/docker-compose.yml up -d --build
```
`KGP_APPDATA` sets the host data directory (default `/mnt/user/appdata/kgp-broker`).
`KGP_BIND` sets the published address (default `127.0.0.1`). Set it to the LAN IP if your
proxy runs on another host.

## Reverse proxy

Terminate HTTPS at your proxy (for example SWAG or Nginx Proxy Manager) for `PUBLIC_BASE_URL`,
forward to `http://<unraid>:8787`, and set `TRUST_PROXY=1`. Only the proxy should be able to
reach port 8787. In the Google OAuth client, set the redirect URI to
`<PUBLIC_BASE_URL>/oauth/callback`.

## Backups

- Back up the appdata directory. `devices.json` holds the encrypted refresh tokens.
- Store `TOKEN_ENCRYPTION_KEY` in a password manager, separate from the appdata backup. If
  you lose or change the key, every device has to pair again.
- The client secret and the key are passed only as env vars. They are never baked into the image.
