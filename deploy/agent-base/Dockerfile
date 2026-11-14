# syntax=docker/dockerfile:1
# The image every managed run's turns execute in (docs/dev/plan.md §6.5): git, gh,
# common toolchains and both harness CLIs. Projects can extend it.
FROM golang:1.26.0-bookworm AS go-tools
# Build the pinned source as the main module: sqlc uses replace directives,
# which prevent `go install module@version`.
RUN git clone --depth 1 --branch v1.31.1 https://github.com/sqlc-dev/sqlc.git /tmp/sqlc \
 && cd /tmp/sqlc && go build -o /go/bin/sqlc ./cmd/sqlc

# Nix lets a turn install any tool it needs without root (nix profile
# install nixpkgs#protobuf): the runner's nix-daemon owns the store, shared by
# every turn through the lazyagents-nix volume (see runner/docker_nix.go).
FROM nixos/nix:2.24.10 AS nix

FROM node:24-bookworm-slim
COPY --from=go-tools /usr/local/go /usr/local/go
COPY --from=go-tools /go/bin/sqlc /usr/local/bin/sqlc
ENV PATH="/usr/local/go/bin:${PATH}"

# ffmpeg, numpy and Pillow let a coding chat render videos with code (chat
# videos encode H.264 MP4s); python3-venv lets it install anything else it
# needs without touching the system Python.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git openssh-client make jq ripgrep python3 build-essential gnupg \
      ffmpeg python3-numpy python3-pil python3-venv \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# The docker CLI only: turns get a Docker API through the runner's sandboxing
# proxy (DOCKER_HOST), never the host's daemon or socket.
ARG DOCKER_CLI_VERSION=27.5.1
RUN arch="$(uname -m)" \
 && curl -fsSL "https://download.docker.com/linux/static/stable/${arch}/docker-${DOCKER_CLI_VERSION}.tgz" \
    | tar -xz -C /usr/local/bin --strip-components=1 docker/docker
# Compose, so an agent can bring up an app's stack: its builds use the classic
# builder (the proxy refuses BuildKit) and its ./ binds become mounts of the
# run's checkout.
ARG COMPOSE_VERSION=v2.32.4
RUN mkdir -p /usr/local/lib/docker/cli-plugins \
 && curl -fsSL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-$(uname -m)" \
    -o /usr/local/lib/docker/cli-plugins/docker-compose \
 && chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

COPY --from=nix /nix /nix
RUN groupadd --system nixbld \
 && for i in $(seq 1 8); do useradd --system --no-create-home --home-dir /var/empty --shell /usr/sbin/nologin \
      --gid nixbld --groups nixbld "nixbld$i"; done \
 && mkdir -p /etc/nix \
 && printf '%s\n' 'build-users-group = nixbld' 'experimental-features = nix-command flakes' \
      'sandbox = false' 'auto-optimise-store = true' > /etc/nix/nix.conf
# Turns reach the store through the daemon; what a turn installs lands in its
# run's home profile, which later turns of the run keep.
ENV NIX_REMOTE=daemon
ENV PATH="/home/node/.nix-profile/bin:${PATH}:/nix/var/nix/profiles/default/bin"

# Harness CLI versions (adapters in server/internal/harness).
ARG CLAUDE_CODE_VERSION=2.1.325
ARG CODEX_VERSION=0.169.0
RUN npm install -g --no-fund --no-audit \
      @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} @openai/codex@${CODEX_VERSION} \
 && npm cache clean --force

# Antigravity (agy). Google publishes no npm package, so pin the release slug
# (`<version>-<build>`) and SHA-512 checksums from the installer's manifests:
# https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_<arch>.json
# A failed install fails the build: an image without agy breaks every Antigravity
# turn. Pass --build-arg INSTALL_ANTIGRAVITY=false to omit it.
ARG INSTALL_ANTIGRAVITY=true
ARG AGY_RELEASE=1.5.9-4515810895593472
ARG AGY_SHA512_AMD64=d01eb13ba7750eed18907f1ae8860864371e0ad9064415e8d033d22b4bd7b9b4e4c7f962058520b452d67db1c33163d9a889d55a7dffa159596ec6cd91a87b79
ARG AGY_SHA512_ARM64=16c632a09b81f598f7652bc11180861f9d2ee4408ffa161dadc83b2010de7a9cd055e97b4b46cd01903e35c0e8bf21d8262462ba7c5f168cc6dada9ac3d522c0
RUN if [ "$INSTALL_ANTIGRAVITY" = true ]; then \
      set -eu; \
      arch="$(dpkg --print-architecture)"; \
      case "$arch" in \
        amd64) path="linux-x64/cli_linux_x64.tar.gz"; want="$AGY_SHA512_AMD64" ;; \
        arm64) path="linux-arm/cli_linux_arm64.tar.gz"; want="$AGY_SHA512_ARM64" ;; \
        *) echo "no agy checksum pinned for $arch" >&2; exit 1 ;; \
      esac; \
      curl -fsSL -o /tmp/agy.tgz "https://storage.googleapis.com/antigravity-public/antigravity-cli/${AGY_RELEASE}/${path}"; \
      echo "${want}  /tmp/agy.tgz" | sha512sum -c -; \
      tar -xzf /tmp/agy.tgz -C /tmp antigravity; \
      install -m 0755 /tmp/antigravity /usr/local/bin/agy; \
      test "$(HOME=/tmp/agy-home agy --version)" = "${AGY_RELEASE%%-*}"; \
      rm -rf /tmp/agy.tgz /tmp/antigravity /tmp/agy-home; \
    fi
ENV AGY_CLI_DISABLE_AUTO_UPDATE=1

# Browser system libraries are installed once in the image. Browser revisions
# follow each project's Playwright lockfile and live in the persistent cache.
ARG PLAYWRIGHT_VERSION=1.64.1
RUN npx --yes playwright@${PLAYWRIGHT_VERSION} install-deps chromium

# The node user (uid 1000) runs turns. A new named volume copies /workspace's
# ownership from the image, so the agent can write to it.
RUN mkdir -p /cache /workspace && chown node:node /cache /workspace
USER node
ENV HOME=/home/node
WORKDIR /workspace
CMD ["sh"]
