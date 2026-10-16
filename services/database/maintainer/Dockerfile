# ── Build stage ─────────────────────────────────────────────────────────
FROM node:20-alpine AS builder

WORKDIR /app
RUN corepack enable && corepack prepare pnpm@9.0.0 --activate

COPY package.json pnpm-lock.yaml* ./
RUN pnpm install --frozen-lockfile || pnpm install

COPY tsconfig.json ./
COPY src ./src
RUN pnpm run build

# ── Runtime stage ───────────────────────────────────────────────────────
FROM node:20-alpine AS runtime

# bash + psql for load_gtfs.sh; unzip for extracting the feed.
RUN apk add --no-cache tini bash postgresql-client unzip \
 && corepack enable && corepack prepare pnpm@9.0.0 --activate \
 && addgroup -S app && adduser -S app -G app

WORKDIR /app

COPY package.json pnpm-lock.yaml* ./
RUN pnpm install --prod --frozen-lockfile || pnpm install --prod

COPY --from=builder /app/dist ./dist
COPY healthcheck.js ./

RUN chmod +x healthcheck.js

# /state is a volume; make it writable for the app user.
RUN mkdir -p /state && chown -R app:app /state

USER app
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "dist/main.js"]