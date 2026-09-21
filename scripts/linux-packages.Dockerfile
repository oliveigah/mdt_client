# syntax=docker/dockerfile:1

# Releases include Erlang native libraries. Build each package on the distro
# family where it will run so those libraries use the target OpenSSL ABI.
FROM docker.io/hexpm/elixir:1.19.4-erlang-28.2-ubuntu-jammy-20260509 AS deb-build

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl git file pkg-config \
    libwebkit2gtk-4.1-dev libssl-dev libayatana-appindicator3-dev \
    librsvg2-dev libxdo-dev desktop-file-utils xdg-utils \
    && rm -rf /var/lib/apt/lists/*

RUN curl --proto '=https' --tlsv1.2 --fail --silent --show-error \
      --retry 5 --retry-delay 2 --retry-all-errors \
      https://sh.rustup.rs -o /tmp/rustup.sh \
    && sh /tmp/rustup.sh -y --profile minimal --default-toolchain 1.98.1 \
    && rm /tmp/rustup.sh
ENV PATH="/root/.cargo/bin:${PATH}"
ENV CARGO_HTTP_MULTIPLEXING=false CARGO_NET_RETRY=10 MIX_ENV=prod
ARG TARGETARCH
RUN --mount=type=cache,id=mdt-cargo-registry,target=/root/.cargo/registry \
    --mount=type=cache,id=mdt-cargo-git,target=/root/.cargo/git \
    --mount=type=cache,id=mdt-deb-tauri-cli-${TARGETARCH},target=/tmp/tauri-cli-target \
    CARGO_TARGET_DIR=/tmp/tauri-cli-target \
    cargo install tauri-cli --version 2.11.4 --locked

WORKDIR /app
COPY mix.exs mix.lock ./
RUN git config --global http.version HTTP/1.1
RUN --mount=type=cache,id=mdt-deb-mix-home,target=/root/.mix \
    --mount=type=cache,id=mdt-deb-hex-home,target=/root/.hex \
    --mount=type=cache,id=mdt-deb-mix-deps,target=/app/deps \
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

RUN --mount=type=cache,id=mdt-cargo-registry,target=/root/.cargo/registry \
    --mount=type=cache,id=mdt-cargo-git,target=/root/.cargo/git \
    --mount=type=cache,id=mdt-deb-mix-home,target=/root/.mix \
    --mount=type=cache,id=mdt-deb-hex-home,target=/root/.hex \
    --mount=type=cache,id=mdt-deb-mix-deps,target=/app/deps \
    --mount=type=cache,id=mdt-deb-mix-build-${TARGETARCH},target=/app/_build \
    mix assets.setup \
    && cargo tauri build --no-bundle -- --locked \
    && cargo tauri bundle --bundles deb --verbose \
    && mkdir /out \
    && cp src-tauri/target/release/bundle/deb/*.deb /out/

FROM scratch AS deb
COPY --from=deb-build /out /out


FROM docker.io/library/fedora:44 AS rpm-build

RUN dnf --assumeyes --setopt=install_weak_deps=False install \
    ca-certificates curl git file gcc gcc-c++ make pkgconf-pkg-config \
    autoconf ncurses-devel perl tar gzip unzip \
    webkit2gtk4.1-devel openssl-devel librsvg2-devel libxdo-devel \
    desktop-file-utils xdg-utils rpm-build \
    && dnf clean all

ARG ERLANG_VERSION=28.3
ARG ERLANG_SHA256=1956ad6584678b631ab4f9b8aebe2dac037cd7401abb44564a01134ff0ac5bed
RUN curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
      "https://github.com/erlang/otp/releases/download/OTP-${ERLANG_VERSION}/otp_src_${ERLANG_VERSION}.tar.gz" \
      --output /tmp/erlang.tar.gz \
    && printf '%s  %s\n' "$ERLANG_SHA256" /tmp/erlang.tar.gz | sha256sum --check --strict \
    && mkdir /tmp/erlang-src \
    && tar --extract --gzip --file /tmp/erlang.tar.gz --directory /tmp/erlang-src --strip-components=1 \
    && cd /tmp/erlang-src \
    && ./configure --prefix=/opt/erlang --without-javac --without-odbc --without-wx \
    && make --jobs="$(nproc)" \
    && make install \
    && rm -rf /tmp/erlang-src /tmp/erlang.tar.gz

ARG ELIXIR_VERSION=1.19.4
ARG ELIXIR_SHA256=8fd7b5705b756c0e1ec71f9e8281b4b75801b9564f0205b5035319e8505ad2b4
RUN curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
      "https://github.com/elixir-lang/elixir/releases/download/v${ELIXIR_VERSION}/elixir-otp-28.zip" \
      --output /tmp/elixir.zip \
    && printf '%s  %s\n' "$ELIXIR_SHA256" /tmp/elixir.zip | sha256sum --check --strict \
    && mkdir /opt/elixir \
    && unzip -q /tmp/elixir.zip -d /opt/elixir \
    && rm /tmp/elixir.zip

RUN curl --proto '=https' --tlsv1.2 --fail --silent --show-error \
      --retry 5 --retry-delay 2 --retry-all-errors \
      https://sh.rustup.rs -o /tmp/rustup.sh \
    && sh /tmp/rustup.sh -y --profile minimal --default-toolchain 1.98.1 \
    && rm /tmp/rustup.sh
ENV PATH="/root/.cargo/bin:/opt/elixir/bin:/opt/erlang/bin:${PATH}"
ENV CARGO_HTTP_MULTIPLEXING=false CARGO_NET_RETRY=10 MIX_ENV=prod
ARG TARGETARCH
RUN --mount=type=cache,id=mdt-cargo-registry,target=/root/.cargo/registry \
    --mount=type=cache,id=mdt-cargo-git,target=/root/.cargo/git \
    --mount=type=cache,id=mdt-rpm-tauri-cli-${TARGETARCH},target=/tmp/tauri-cli-target \
    CARGO_TARGET_DIR=/tmp/tauri-cli-target \
    cargo install tauri-cli --version 2.11.4 --locked

ENV LANG=C.UTF-8 LC_ALL=C.UTF-8
ENV RUSTFLAGS="-C target-cpu=native"
WORKDIR /app
COPY mix.exs mix.lock ./
RUN git config --global http.version HTTP/1.1
RUN --mount=type=cache,id=mdt-rpm-mix-home,target=/root/.mix \
    --mount=type=cache,id=mdt-rpm-hex-home,target=/root/.hex \
    --mount=type=cache,id=mdt-rpm-mix-deps,target=/app/deps \
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

RUN --mount=type=cache,id=mdt-cargo-registry,target=/root/.cargo/registry \
    --mount=type=cache,id=mdt-cargo-git,target=/root/.cargo/git \
    --mount=type=cache,id=mdt-rpm-mix-home,target=/root/.mix \
    --mount=type=cache,id=mdt-rpm-hex-home,target=/root/.hex \
    --mount=type=cache,id=mdt-rpm-mix-deps,target=/app/deps \
    --mount=type=cache,id=mdt-rpm-mix-build-${TARGETARCH},target=/app/_build \
    mix assets.setup \
    && cargo tauri build --no-bundle -- --locked \
    && cargo tauri bundle --bundles rpm --verbose \
    && mkdir /out \
    && cp src-tauri/target/release/bundle/rpm/*.rpm /out/

FROM scratch AS rpm
COPY --from=rpm-build /out /out
