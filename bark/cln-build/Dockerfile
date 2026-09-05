# syntax=docker/dockerfile:1.7
FROM rust:1.94-bookworm AS hold
RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git init && git remote add origin https://github.com/BoltzExchange/hold.git \
    && git fetch --depth=1 origin af0055b132f3b9f24d0b1d478a15005fcf8f014f \
    && git checkout --detach FETCH_HEAD
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/src/target \
    cargo build --locked --release --jobs 2 \
    && cp target/release/hold /usr/local/bin/hold
FROM elementsproject/lightningd:v26.06.6
RUN apt-get update && apt-get install -y --no-install-recommends openssl \
    && rm -rf /var/lib/apt/lists/*
COPY --from=hold /usr/local/bin/hold /usr/local/bin/hold
COPY --from=hold /src/LICENSE /usr/share/licenses/hold/LICENSE
