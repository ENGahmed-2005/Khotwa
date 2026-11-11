FROM node:22-bookworm-slim AS build
WORKDIR /app
ENV PRISMA_SKIP_POSTINSTALL_GENERATE=true
RUN apt-get update && apt-get install -y --no-install-recommends openssl ca-certificates && rm -rf /var/lib/apt/lists/*
COPY backend/package.json backend/package-lock.json ./
RUN npm ci
COPY backend/ ./
RUN npm run db:generate && npm run build

FROM node:22-bookworm-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends chromium fonts-noto-core ca-certificates openssl tini && rm -rf /var/lib/apt/lists/*
WORKDIR /app
ENV NODE_ENV=production HOST=0.0.0.0 PORT=10000 KHOTWA_CHROMIUM_EXECUTABLE=/usr/bin/chromium
# Prisma CLI is retained to apply versioned migrations on Free service startup.
# No tests, local environments, keys, or student data are copied into this stage.
COPY --from=build --chown=node:node /app/package.json /app/package-lock.json ./
COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/dist/src ./dist/src
COPY --from=build --chown=node:node /app/prisma ./prisma
USER node
EXPOSE 10000
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["sh", "-c", "./node_modules/.bin/prisma migrate deploy && exec node dist/src/server.js"]
