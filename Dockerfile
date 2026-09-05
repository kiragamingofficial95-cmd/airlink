FROM oven/bun:1.4 AS daemon-builder
WORKDIR /build/daemon
COPY daemon-main/daemon-main/package.json daemon-main/daemon-main/bun.lock* ./
RUN bun install 2>/dev/null || true
COPY daemon-main/daemon-main/ ./
RUN bun run build || true

FROM oven/bun:1.4 AS bun-runtime

FROM node:22-slim AS panel-builder
WORKDIR /build/panel
ENV PNPM_HOME="/root/.local/share/pnpm"
ENV PATH="$PNPM_HOME:$PATH"
RUN npm install -g pnpm@11.20.0
COPY panel-main/package.json panel-main/pnpm-workspace.yaml ./
RUN pnpm install --no-frozen-lockfile || true
COPY panel-main/ ./
RUN pnpm install --no-frozen-lockfile || true
RUN pnpm run migrate:deploy || pnpm exec prisma db push || true
RUN pnpm run build || true

FROM node:22-slim
COPY --from=bun-runtime /usr/local/bin/bun /usr/local/bin/bun
RUN apt-get update && apt-get install -y --no-install-recommends \
    postgresql postgresql-contrib \
    redis-server \
    unzip \
    curl \
    ca-certificates \
    procps \
    && rm -rf /var/lib/apt/lists/*

ENV PNPM_HOME="/root/.local/share/pnpm"
ENV PATH="$PNPM_HOME:$PATH"
RUN npm install -g pnpm@11.20.0

# Panel
WORKDIR /app/panel
COPY --from=panel-builder /build/panel /app/panel

# Daemon
WORKDIR /app/daemon
COPY daemon-main/daemon-main/package.json daemon-main/daemon-main/bun.lock* ./
COPY --from=daemon-builder /build/daemon/node_modules ./node_modules
COPY daemon-main/daemon-main/ ./

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 3000 3002 5432 6379 3004
ENTRYPOINT ["/entrypoint.sh"]
