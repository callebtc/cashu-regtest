FROM node:22-bookworm-slim

ARG SPARK_SDK_REPOSITORY=https://github.com/benthecarman/spark.git
ARG SPARK_SDK_COMMIT=06614d2e3535385f15aef3749b2c8a780f679ebc

RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/spark-sdk
RUN git init \
 && git remote add origin "$SPARK_SDK_REPOSITORY" \
 && git fetch --depth=1 origin "$SPARK_SDK_COMMIT" \
 && git checkout --detach FETCH_HEAD

WORKDIR /opt/spark-sdk/sdks/js
RUN --mount=type=cache,target=/root/.yarn/berry/cache \
    corepack enable \
 && yarn install --no-immutable --mode=skip-build \
 && yarn build:sdk

COPY e2e.mjs /opt/spark-test/e2e.mjs
CMD ["node", "/opt/spark-test/e2e.mjs"]
