
# ---- Added by MDT. Everything above is yours; this layer is the same for every build. ----
# Only pointers: MDT fills /mnt/mdt for each VM (its CA bundle, the
# placeholders, git's credential helper) and mounts the VM's Cache at /cache.
# Nothing here belongs to one identity, so a CA change needs no rebuild.
RUN set -e; \
    mkdir -p /etc/ssl/certs /etc/ca-certificates/update.d /etc/profile.d /mnt/mdt /cache /root; \
    ln -sf /mnt/mdt/ca-bundle.pem /etc/ssl/certs/ca-certificates.crt; \
    printf '#!/bin/sh\n# MDT: keep the bundle pointing at the one MDT writes.\nln -sf /mnt/mdt/ca-bundle.pem /etc/ssl/certs/ca-certificates.crt\n' \
      > /etc/ca-certificates/update.d/zz-mdt; \
    chmod 755 /etc/ca-certificates/update.d/zz-mdt; \
    ln -sf /mnt/mdt/profile.sh /etc/profile.d/mdt.sh; \
    if [ -f /etc/bash.bashrc ]; then echo '[ -r /mnt/mdt/bashrc.sh ] && . /mnt/mdt/bashrc.sh' >> /etc/bash.bashrc; fi; \
    if command -v git >/dev/null; then \
      git config --system credential.helper /mnt/mdt/bin/git-credential; \
      git config --system url."https://github.com/".insteadOf "git@github.com:"; \
      git config --system --add url."https://github.com/".insteadOf "ssh://git@github.com/"; \
    fi; \
    mkdir -p /etc/mdt; \
    if command -v mise >/dev/null; then mise ls --offline > /etc/mdt/versions.txt 2>&1 || true; fi
ENV SSL_CERT_FILE=/mnt/mdt/ca-bundle.pem \
    CURL_CA_BUNDLE=/mnt/mdt/ca-bundle.pem \
    REQUESTS_CA_BUNDLE=/mnt/mdt/ca-bundle.pem \
    HEX_CACERTS_PATH=/mnt/mdt/ca-bundle.pem \
    CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE=/mnt/mdt/ca-bundle.pem \
    NODE_EXTRA_CA_CERTS=/mnt/mdt/ca.pem \
    HEX_HTTP_TIMEOUT=900 \
    BASH_ENV=/mnt/mdt/profile.sh \
    SHELL=/bin/bash \
    MDT_SANDBOX=1 \
    ZED_FILE_WATCHER_MODE=poll \
    ZED_FILE_WATCHER_POLL_MS=5000 \
    XDG_CACHE_HOME=/cache/xdg \
    MISE_DATA_DIR=/cache/mise \
    MISE_CACHE_DIR=/cache/xdg/mise \
    HEX_HOME=/cache/hex \
    MIX_HOME=/cache/mix \
    npm_config_cache=/cache/npm \
    npm_config_prefix=/cache/npm-global \
    GOPATH=/cache/go \
    CARGO_HOME=/cache/cargo \
    GRADLE_USER_HOME=/cache/gradle \
    PATH="/cache/mise/shims:/cache/npm-global/bin:/cache/cargo/bin:/cache/go/bin:${PATH}"
