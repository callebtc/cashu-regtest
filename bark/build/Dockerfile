# syntax=docker/dockerfile:1.7
FROM rust:1.94-bookworm AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
    clang cmake pkg-config protobuf-compiler libssl-dev libpq-dev libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git init && git remote add origin https://github.com/ark-bitcoin/bark.git \
    && git fetch --depth=1 origin e3d4174ca08a3c97bc23e1e73aa5332d725a7689 \
    && git checkout --detach FETCH_HEAD
# Bound compiler memory use on development machines and CI runners.
ENV CARGO_PROFILE_RELEASE_LTO=false
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/src/target \
    cargo build --locked --release --jobs 2 --bin captaind --bin bark \
    && cp target/release/captaind target/release/bark /usr/local/bin/

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates libssl3 libpq5 libsqlite3-0 curl jq \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/local/bin/captaind /usr/local/bin/bark /usr/local/bin/
COPY --from=build /src/LICENSE /usr/share/licenses/bark/LICENSE
ENTRYPOINT ["bark"]
