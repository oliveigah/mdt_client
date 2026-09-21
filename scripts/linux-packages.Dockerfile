# syntax=docker/dockerfile:1

# Ubuntu 22.04 keeps the generated binaries compatible with a broad range of
# current Linux distributions while providing WebKitGTK 4.1 for Tauri 2.
FROM docker.io/hexpm/elixir:1.19.4-erlang-28.2-ubuntu-jammy-20260509 AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl git file pkg-config \
    libwebkit2gtk-4.1-dev libssl-dev libayatana-appindicator3-dev \
    librsvg2-dev libxdo-dev desktop-file-utils xdg-utils rpm \
    && rm -rf /var/lib/apt/lists/*

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o /tmp/rustup.sh \
    && sh /tmp/rustup.sh -y --profile minimal --default-toolchain 1.98.1 \
    && rm /tmp/rustup.sh
ENV PATH="/root/.cargo/bin:${PATH}"
ENV CARGO_HTTP_MULTIPLEXING=false CARGO_NET_RETRY=10
ARG TARGETARCH
RUN --mount=type=cache,id=mdt-cargo-registry,target=/root/.cargo/registry \
    --mount=type=cache,id=mdt-cargo-git,target=/root/.cargo/git \
    --mount=type=cache,id=mdt-tauri-cli-${TARGETARCH},target=/tmp/tauri-cli-target \
    CARGO_TARGET_DIR=/tmp/tauri-cli-target \
    cargo install tauri-cli --version 2.11.4 --locked

ENV MIX_ENV=prod
WORKDIR /app

COPY mix.exs mix.lock ./
RUN git config --global http.version HTTP/1.1
RUN --mount=type=cache,id=mdt-mix-home,target=/root/.mix \
    --mount=type=cache,id=mdt-hex-home,target=/root/.hex \
    --mount=type=cache,id=mdt-mix-deps,target=/app/deps \
    mix local.hex --force \
    && mix local.rebar --force \
    && for attempt in 1 2 3 4 5; do \
         mix deps.get --only prod --check-locked && exit 0; \
         printf 'Dependency download failed (attempt %s/5); retrying...\n' "$attempt"; \
         sleep 2; \
       done \
    && exit 1

COPY config ./config
COPY lib ./lib
COPY assets ./assets
COPY priv ./priv
COPY src-tauri ./src-tauri
COPY .gitignore ./

# Build once. The format-specific stages below package the same native binary
# and Phoenix release, so Docker can share this expensive layer.
RUN --mount=type=cache,id=mdt-cargo-registry,target=/root/.cargo/registry \
    --mount=type=cache,id=mdt-cargo-git,target=/root/.cargo/git \
    --mount=type=cache,id=mdt-mix-home,target=/root/.mix \
    --mount=type=cache,id=mdt-hex-home,target=/root/.hex \
    --mount=type=cache,id=mdt-mix-deps,target=/app/deps \
    --mount=type=cache,id=mdt-mix-build-${TARGETARCH},target=/app/_build \
    mix assets.setup \
    && cargo tauri build --no-bundle -- --locked

FROM build AS package-deb
RUN cargo tauri bundle --bundles deb --verbose \
    && mkdir /out \
    && cp src-tauri/target/release/bundle/deb/*.deb /out/

FROM build AS package-rpm
RUN cargo tauri bundle --bundles rpm --verbose \
    && mkdir /out \
    && cp src-tauri/target/release/bundle/rpm/*.rpm /out/

FROM scratch AS deb
COPY --from=package-deb /out /out

FROM scratch AS rpm
COPY --from=package-rpm /out /out
