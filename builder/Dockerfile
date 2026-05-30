FROM node:26-slim

LABEL org.opencontainers.image.source=https://github.com/beyond-all-reason/BAR-Widgets
LABEL org.opencontainers.image.description="BAR Workshop builder"
LABEL org.opencontainers.image.licenses="GPL-2.0-or-later"

WORKDIR /app/builder

# Install dependencies first (layer caching)
COPY builder/package.json builder/npm-shrinkwrap.json ./
RUN npm ci --omit=dev

# Copy the rest of the builder
COPY builder/ ./

WORKDIR /app

CMD ["npx", "--prefix", "builder", "tsx", "builder/src/build.ts"]
