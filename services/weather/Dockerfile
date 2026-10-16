FROM node:20-alpine AS builder
WORKDIR /app
RUN corepack enable && corepack prepare pnpm@9.0.0 --activate
COPY package.json pnpm-lock.yaml* ./
RUN pnpm install --frozen-lockfile || pnpm install
COPY tsconfig.json ./
COPY src ./src
RUN pnpm run build

FROM node:20-alpine AS runtime
WORKDIR /app
RUN apk add --no-cache tini \
 && corepack enable && corepack prepare pnpm@9.0.0 --activate \
 && addgroup -S app && adduser -S app -G app
COPY package.json pnpm-lock.yaml* ./
RUN pnpm install --prod --frozen-lockfile || pnpm install --prod
COPY --from=builder /app/dist ./dist
USER app
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "dist/main.js"]