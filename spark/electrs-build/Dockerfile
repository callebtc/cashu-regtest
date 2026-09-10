# syntax=docker/dockerfile:1.7

FROM alpine:3.20 AS source
ADD https://github.com/mempool/electrs/archive/5b8819039dc1ad1dddf2c3c293ec8825975680f8.tar.gz /tmp/electrs.tar.gz
RUN mkdir /src \
 && tar -xzf /tmp/electrs.tar.gz --strip-components=1 -C /src

FROM rust:1.85-bookworm AS builder
WORKDIR /build
RUN apt-get update \
 && apt-get install -y --no-install-recommends clang cmake librocksdb-dev \
 && rm -rf /var/lib/apt/lists/*
COPY --from=source /src/ .
# Scope caches per image for parallel Bake targets; lock concurrent builds of this image.
RUN --mount=type=cache,id=cashu-spark-electrs-cargo-registry,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,id=cashu-spark-electrs-cargo-target,target=/build/target,sharing=locked \
    cargo build --release --locked --jobs 2 --bin electrs \
 && cp target/release/electrs /tmp/electrs

FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates librocksdb-dev \
 && rm -rf /var/lib/apt/lists/*
COPY --from=builder /tmp/electrs /bin/electrs
ENTRYPOINT ["/bin/electrs"]
