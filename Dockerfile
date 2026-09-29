# Production images for the VPS deploy (see docs/DEPLOY.md).
#   docker build --target api -t openmuse-api .
#   docker build --target web --build-arg PUBLIC_URL=https://muse.example.com -t openmuse-web .
FROM node:24-slim AS base
ENV PNPM_HOME=/pnpm PATH=/pnpm:$PATH CI=true
RUN corepack enable
WORKDIR /repo

FROM base AS deps
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY apps/mobile/package.json apps/mobile/
COPY apps/worker/package.json apps/worker/
RUN --mount=type=cache,id=pnpm,target=/pnpm/store pnpm install --frozen-lockfile

FROM deps AS build-server
COPY tsconfig.json tsconfig.build.json ./
COPY apps/server apps/server
COPY packages packages
RUN pnpm build:server

FROM deps AS build-web
ARG PUBLIC_URL
RUN test -n "$PUBLIC_URL" || (echo "Set --build-arg PUBLIC_URL=https://your-domain" && exit 1)
ENV EXPO_PUBLIC_API_URL=$PUBLIC_URL
COPY packages/domain packages/domain
COPY apps/mobile apps/mobile
RUN pnpm --dir apps/mobile build:web

FROM base AS prod-deps
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY apps/mobile/package.json apps/mobile/
COPY apps/worker/package.json apps/worker/
RUN --mount=type=cache,id=pnpm,target=/pnpm/store \
    pnpm install --frozen-lockfile --prod --filter openmuse

FROM node:24-slim AS api
ENV NODE_ENV=production HOST=0.0.0.0 PORT=8787 DATA_DIR=/data
WORKDIR /app
COPY --from=prod-deps /repo/package.json ./
COPY --from=prod-deps /repo/node_modules ./node_modules
COPY --from=build-server /repo/dist ./dist
RUN mkdir /data && chown node:node /data
USER node
EXPOSE 8787
HEALTHCHECK --interval=15s --timeout=5s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:8787/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "dist/apps/server/src/index.js"]

FROM caddy:2-alpine AS web
COPY infra/Caddyfile /etc/caddy/Caddyfile
COPY --from=build-web /repo/apps/mobile/dist/web /srv
