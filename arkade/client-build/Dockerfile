# syntax=docker/dockerfile:1.7
FROM node:24.15.0-bookworm
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /sdk
RUN git init && git remote add origin https://github.com/arkade-os/ts-sdk.git \
    && git fetch --depth=1 origin 45a53690aa80dbc3fd058f3fa4c250c262cc566b \
    && git checkout --detach FETCH_HEAD
RUN corepack enable && corepack prepare pnpm@10.25.0 --activate \
    && pnpm install --frozen-lockfile --ignore-scripts \
    && pnpm --filter @arkade-os/sdk --filter @arkade-os/boltz-swap build
WORKDIR /sdk/packages/boltz-swap
ENTRYPOINT ["node"]
