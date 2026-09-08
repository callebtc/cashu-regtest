# Source-only pinned archives avoid cloning the full Spark Git history.
FROM rust:1.92-slim-bookworm AS builder
RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler libprotobuf-dev \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
ADD https://github.com/benthecarman/open-ssp/archive/25eec4a8c492a16a4d1962b7115430181a8200ad.tar.gz /tmp/ssp.tar.gz
RUN tar -xzf /tmp/ssp.tar.gz --strip-components=1 -C /app
ADD https://github.com/benthecarman/spark-sdk/archive/2472fdc0e136868eb10e5ad9f501a7e740080f04.tar.gz /tmp/sdk.tar.gz
RUN tar -xzf /tmp/sdk.tar.gz --strip-components=1 -C /app/vendor/breez-sdk
ADD https://github.com/benthecarman/spark/archive/83cca565c3cce1a4692cedef601fef553ed0249b.tar.gz /tmp/spark.tar.gz
RUN tar -xzf /tmp/spark.tar.gz --strip-components=1 -C /app/vendor/spark
ENV CARGO_BUILD_JOBS=2
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    cargo build --release --locked

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --system --gid 10001 ssp \
 && useradd --system --uid 10001 --gid ssp --home-dir /data ssp \
 && install -d -o ssp -g ssp /data
COPY --from=builder /app/target/release/open-ssp /usr/local/bin/open-ssp
COPY --from=builder /app/LICENSE /usr/share/doc/open-ssp/LICENSE
COPY --from=builder /app/vendor/breez-sdk/LICENSE /usr/share/doc/breez-sdk/LICENSE
ENV SSP_DATA_DIR=/data
USER ssp
ENTRYPOINT ["open-ssp"]
