# syntax=docker/dockerfile:1.7

FROM alpine:3.20 AS spark-source
ADD https://github.com/buildonspark/spark/archive/0b3a32a05c9ac06cc411683551dd1f1bde9d0caa.tar.gz /tmp/spark.tar.gz
RUN mkdir /src \
 && tar -xzf /tmp/spark.tar.gz --strip-components=1 -C /src

FROM --platform=$BUILDPLATFORM golang:1.27-bookworm AS builder-go
ARG TARGETOS TARGETARCH BUILDARCH
ENV GOOS=$TARGETOS
ENV GOARCH=$TARGETARCH
WORKDIR /src
RUN dpkg --add-architecture arm64 \
 && dpkg --add-architecture amd64 \
 && apt-get update \
 && apt-get install -y --no-install-recommends patch protobuf-compiler wget \
 && if [ "$BUILDARCH" != "$TARGETARCH" ]; then \
      if [ "$TARGETARCH" = "arm64" ]; then \
        apt-get install -y gcc-aarch64-linux-gnu libzmq3-dev:arm64; \
      elif [ "$TARGETARCH" = "amd64" ]; then \
        apt-get install -y gcc-x86-64-linux-gnu libzmq3-dev:amd64; \
      fi; \
    else \
      apt-get install -y libzmq3-dev; \
    fi \
 && rm -rf /var/lib/apt/lists/*
RUN apt-get update \
 && apt-get install -y --no-install-recommends libprotobuf-dev \
 && rm -rf /var/lib/apt/lists/*
COPY --from=spark-source /src/spark/go.mod /src/spark/go.sum spark/
RUN --mount=type=cache,target=/go/pkg/mod cd spark && go mod download
COPY --from=spark-source /src/spark spark
COPY --from=spark-source /src/protos protos
COPY --from=spark-source /src/Makefile Makefile
COPY open-ssp-rpc.patch /tmp/open-ssp-rpc.patch
RUN patch -p1 < /tmp/open-ssp-rpc.patch \
 && go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.11 \
 && go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.6.0 \
 && go install github.com/envoyproxy/protoc-gen-validate@v1.3.0 \
 && make -B all
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    set -e; \
    export CGO_ENABLED=1; \
    if [ "$BUILDARCH" != "$TARGETARCH" ]; then \
      if [ "$TARGETARCH" = "amd64" ]; then \
        export CC=x86_64-linux-gnu-gcc CXX=x86_64-linux-gnu-g++; \
        export PKG_CONFIG_PATH=/usr/lib/x86_64-linux-gnu/pkgconfig; \
        export CGO_CFLAGS="-I/usr/include -I/usr/include/x86_64-linux-gnu"; \
        export CGO_LDFLAGS="-L/usr/lib/x86_64-linux-gnu"; \
      elif [ "$TARGETARCH" = "arm64" ]; then \
        export CC=aarch64-linux-gnu-gcc CXX=aarch64-linux-gnu-g++; \
        export PKG_CONFIG_PATH=/usr/lib/aarch64-linux-gnu/pkgconfig; \
        export CGO_CFLAGS="-I/usr/include -I/usr/include/aarch64-linux-gnu"; \
        export CGO_LDFLAGS="-L/usr/lib/aarch64-linux-gnu"; \
      fi; \
    fi; \
    cd spark; \
    go test -c -o /tmp/grpc.test ./so/grpc; \
    go test -c -o /tmp/handler.test ./so/handler; \
    go test ./so/rpcpolicy; \
    go build -o /go/bin/spark-operator ./bin/operator
RUN if [ -e /go/bin/${TARGETOS}_${TARGETARCH} ]; then \
      mv /go/bin/${TARGETOS}_${TARGETARCH}/* /go/bin/; \
    fi
RUN GRPC_HEALTH_PROBE_VERSION=v0.4.13 \
 && wget -qO /bin/grpc_health_probe \
      "https://github.com/grpc-ecosystem/grpc-health-probe/releases/download/${GRPC_HEALTH_PROBE_VERSION}/grpc_health_probe-${TARGETOS}-${TARGETARCH}" \
 && chmod +x /bin/grpc_health_probe

FROM --platform=$BUILDPLATFORM rust:1.92-slim-bookworm AS chef
RUN cargo install cargo-chef --version 0.1.73

FROM chef AS planner-rust
WORKDIR /signer
COPY --from=spark-source /src/signer/ ./
RUN cargo chef prepare --recipe-path recipe.json

FROM chef AS cacher-rust
ARG TARGETOS TARGETARCH
RUN echo "$TARGETARCH" | sed 's,arm,aarch,;s,amd,x86_,' > /tmp/arch \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      "gcc-$(tr _ - < /tmp/arch)-linux-gnu" \
      "g++-$(tr _ - < /tmp/arch)-linux-gnu" \
 && rm -rf /var/lib/apt/lists/* \
 && rustup target add "$(cat /tmp/arch)-unknown-${TARGETOS}-gnu"
COPY --from=planner-rust /signer/recipe.json /signer/recipe.json
WORKDIR /signer
RUN cargo chef cook --release \
      --target "$(cat /tmp/arch)-unknown-${TARGETOS}-gnu" \
      --recipe-path recipe.json

FROM chef AS builder-rust
WORKDIR /protos
COPY --from=spark-source /src/protos/ ./
WORKDIR /signer
COPY --from=spark-source /src/signer/ ./
COPY --from=cacher-rust /signer/target target
COPY --from=cacher-rust /usr/local/cargo /usr/local/cargo
COPY --from=cacher-rust /tmp/arch /tmp/arch
ARG TARGETOS TARGETARCH
RUN apt-get update \
 && apt-get install -y --no-install-recommends protobuf-compiler libprotobuf-dev \
      "gcc-$(tr _ - < /tmp/arch)-linux-gnu" \
      "g++-$(tr _ - < /tmp/arch)-linux-gnu" \
 && rm -rf /var/lib/apt/lists/* \
 && rustup target add "$(cat /tmp/arch)-unknown-${TARGETOS}-gnu" \
 && cargo build --target "$(cat /tmp/arch)-unknown-${TARGETOS}-gnu" --release

FROM --platform=$TARGETPLATFORM arigaio/atlas:1.0.0-community AS atlas

FROM debian:bookworm-slim
RUN addgroup --system --gid 1000 spark \
 && adduser --system --uid 1000 --home /home/spark --ingroup spark spark \
 && apt-get update \
 && apt-get install -y --no-install-recommends libzmq5 ca-certificates gettext-base \
 && apt-get -y upgrade \
 && rm -rf /var/lib/apt/lists/*
EXPOSE 9735 10009
ENTRYPOINT ["spark-operator"]
COPY --from=atlas /atlas /usr/local/bin/atlas
RUN chmod 0755 /usr/local/bin/atlas
COPY --from=builder-go /go/bin/spark-operator /usr/local/bin/spark-operator
COPY --from=builder-go /bin/grpc_health_probe /usr/local/bin/grpc_health_probe
COPY --from=builder-rust /signer/target/*/release/spark-frost-signer /usr/local/bin/spark-frost-signer
COPY --from=spark-source /src/spark/so/ent/migrate/migrations /opt/spark/migrations
COPY --from=spark-source /src/spark/so/entephemeral/migrate/migrations /opt/spark/ephemeral_migrations
