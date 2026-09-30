# syntax=docker/dockerfile:1
# Build context: the service/ directory.
#   docker build -t koreader-google-photos-broker:local service/
# Node 24 runs the TypeScript sources directly (native type stripping), no build step.
ARG NODE_IMAGE=node:24.21.0-alpine3.24@sha256:ebfe2f90462722a7a4de65e91990e97fe0d401c70e0e762c5b53302f905ec1c1

FROM ${NODE_IMAGE} AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund && npm cache clean --force

FROM ${NODE_IMAGE}
ENV NODE_ENV=production \
    HOST=0.0.0.0 \
    PORT=8787 \
    DATA_FILE=/config/data/devices.json
WORKDIR /app
# Application files are root-owned and read-only for the runtime user.
COPY --from=deps /app/node_modules ./node_modules
COPY package.json package-lock.json ./
COPY src ./src
COPY docker/healthcheck.mjs ./docker/healthcheck.mjs
# /config is the only writable location. Mount a host directory owned by the
# runtime UID:GID. The service creates /config/data (mode 0700) itself.
RUN mkdir -p /config && chown 99:100 /config && chmod 0750 /config
# No VOLUME instruction on purpose: always bind-mount /config explicitly
# (no anonymous volumes that silently hold the device store).
# Unraid convention nobody:users. Override with --user UID:GID if needed.
USER 99:100
EXPOSE 8787
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD ["node", "/app/docker/healthcheck.mjs"]
STOPSIGNAL SIGTERM
CMD ["node", "src/server.ts"]
