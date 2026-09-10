# Both the Rust executable and Erlang runtime must use the older Linux baseline.
FROM docker.io/hexpm/elixir:1.19.4-erlang-28.2-ubuntu-jammy-20260509 AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl wget git file pkg-config xz-utils \
    libwebkit2gtk-4.1-dev libssl-dev libayatana-appindicator3-dev \
    librsvg2-dev libxdo-dev patchelf desktop-file-utils \
    && rm -rf /var/lib/apt/lists/*

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o /tmp/rustup.sh \
    && sh /tmp/rustup.sh -y --profile minimal --default-toolchain 1.98.1 \
    && rm /tmp/rustup.sh
ENV PATH="/root/.cargo/bin:${PATH}"
RUN cargo install tauri-cli --version 2.11.4 --locked

ENV MIX_ENV=prod
# linuxdeploy's older strip cannot read modern .relr.dyn sections.
# Extraction also lets the build run without FUSE or a privileged container.
ENV NO_STRIP=1 APPIMAGE_EXTRACT_AND_RUN=1

WORKDIR /app
COPY mix.exs mix.lock ./
RUN mix local.hex --force && mix local.rebar --force \
    && mix deps.get --only prod --check-locked

COPY config ./config
COPY lib ./lib
COPY assets ./assets
COPY priv ./priv
COPY src-tauri ./src-tauri
# Tauri searches for package.json; ignore Mix deps so it uses /app as the frontend.
COPY .gitignore ./
RUN mix assets.setup \
    && cargo tauri build --no-bundle -- --locked

# The opener plugin needs this desktop helper in the AppImage.
RUN apt-get update && apt-get install -y --no-install-recommends xdg-utils \
    && rm -rf /var/lib/apt/lists/*
RUN cargo tauri bundle --bundles appimage --verbose \
    && mkdir /out \
    && cp src-tauri/target/release/bundle/appimage/*.AppImage /out/

# Wayland must match the host's Mesa/EGL drivers. Bundling Ubuntu's older copy
# crashes on newer Fedora desktops: https://github.com/tauri-apps/tauri/issues/15665
RUN mkdir /tmp/mdt-appimage && cd /tmp/mdt-appimage \
    && for appimage in /out/*.AppImage; do \
      "$appimage" --appimage-extract >/dev/null \
      && rm -f squashfs-root/usr/lib/libwayland-*.so* \
      && ARCH="$(uname -m)" OUTPUT="$appimage" \
         /root/.cache/tauri/linuxdeploy-plugin-appimage.AppImage --appdir squashfs-root \
      || exit 1; \
    done \
    && rm -rf /tmp/mdt-appimage

FROM scratch AS artifact
COPY --from=build /out /out
