FROM rust:1.92-slim-bookworm AS builder
RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler libprotobuf-dev pkg-config libssl-dev git \
 && rm -rf /var/lib/apt/lists/*
ADD https://github.com/breez/spark-sdk/archive/a3fac0e8f1f38e7e3dca110a22f37dd3264e2bde.tar.gz /tmp/sdk.tar.gz
RUN mkdir /sdk && tar -xzf /tmp/sdk.tar.gz --strip-components=1 -C /sdk
WORKDIR /app
ENV CARGO_BUILD_JOBS=2
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    cargo build --release --locked

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/target/release/cashu-breez-test /usr/local/bin/cashu-breez-test
COPY --from=builder /app/Cargo.lock /build/Cargo.lock
COPY --from=builder /sdk/LICENSE /usr/share/doc/breez-sdk/LICENSE
ENTRYPOINT ["cashu-breez-test"]
