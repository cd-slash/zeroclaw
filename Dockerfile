# syntax=docker/dockerfile:1.7

# ── Stage 1: Build ────────────────────────────────────────────
FROM rust:1.92-slim@sha256:bf3368a992915f128293ac76917ab6e561e4dda883273c8f5c9f6f8ea37a378e AS builder

WORKDIR /app

# Install build dependencies
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

# 1. Copy manifests to cache dependencies
COPY Cargo.toml Cargo.lock ./
# Create dummy main.rs to build dependencies
RUN mkdir src && echo "fn main() {}" > src/main.rs
RUN --mount=type=cache,id=zeroclaw-cargo-registry,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,id=zeroclaw-cargo-git,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,id=zeroclaw-target,target=/app/target,sharing=locked \
    cargo build --release --locked
RUN rm -rf src

# 2. Copy source code
COPY . .
RUN --mount=type=cache,id=zeroclaw-cargo-registry,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,id=zeroclaw-cargo-git,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,id=zeroclaw-target,target=/app/target,sharing=locked \
    cargo build --release --locked && \
    cp target/release/zeroclaw /app/zeroclaw && \
    strip /app/zeroclaw

# ── Stage 2: Permissions & Config Prep ───────────────────────
FROM busybox:1.37@sha256:b3255e7dfbcd10cb367af0d409747d511aeb66dfac98cf30e97e87e4207dd76f AS permissions
# Create directory structure (simplified workspace path)
RUN mkdir -p /zeroclaw-data/.zeroclaw /zeroclaw-data/workspace

# Create minimal config for PRODUCTION (allows binding to public interfaces)
# NOTE: Provider configuration must be done via environment variables at runtime
RUN cat > /zeroclaw-data/.zeroclaw/config.toml <<EOF
workspace_dir = "/zeroclaw-data/workspace"
config_path = "/zeroclaw-data/.zeroclaw/config.toml"
api_key = ""
default_provider = "openrouter"
default_model = "anthropic/claude-sonnet-4-20250514"
default_temperature = 0.7

[gateway]
port = 3000
host = "[::]"
allow_public_bind = true

[tunnel]
provider = "none"
EOF

RUN chown -R 65534:65534 /zeroclaw-data

# ── Stage 3: Development Runtime (Debian with Tailscale) ────────────────────
FROM debian:trixie-slim@sha256:f6e2cfac5cf956ea044b4bd75e6397b4372ad88fe00908045e9a0d21712ae3ba AS dev

ARG AGENT_NAME="_default"

# Install runtime dependencies + basic debug tools + Tailscale support
RUN apt-get update && apt-get install -y \
    ca-certificates \
    openssl \
    curl \
    git \
    iputils-ping \
    vim \
    jq \
    iproute2 \
    iptables \
    procps \
    tar \
    && rm -rf /var/lib/apt/lists/*

# Install Tailscale
RUN curl -fsSL https://tailscale.com/install.sh | sh

# Install Litestream for SQLite backup
# Using official Litestream release
RUN curl -fsSL -o litestream.deb https://github.com/benbjohnson/litestream/releases/download/v0.3.13/litestream-v0.3.13-linux-amd64.deb \
    && dpkg -i litestream.deb \
    && rm litestream.deb

# Create required directories
RUN mkdir -p /var/lib/tailscale /var/run/tailscale /etc/litestream

COPY --from=permissions /zeroclaw-data /zeroclaw-data
COPY --from=builder /app/zeroclaw /usr/local/bin/zeroclaw

# Create zeroclaw user for running zeroclaw and Tailscale SSH access
# Using UID 1000 (standard first user) instead of reusing nobody (65534)
RUN useradd -m -u 1000 -s /bin/bash -d /zeroclaw-data zeroclaw && \
    chown -R zeroclaw:zeroclaw /zeroclaw-data /var/lib/tailscale /var/run/tailscale

# Overwrite minimal config with DEV template (Ollama defaults)
COPY dev/config.template.toml /zeroclaw-data/.zeroclaw/config.toml
RUN chown zeroclaw:zeroclaw /zeroclaw-data/.zeroclaw/config.toml

# Copy entrypoint script for Tailscale authentication
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Copy Litestream configuration and start script
COPY .agents/litestream.template.yml /etc/litestream/litestream.yml
COPY start-agent-with-litestream.sh /usr/local/bin/start-agent-with-litestream.sh
RUN chmod +x /usr/local/bin/start-agent-with-litestream.sh

# Copy agent setup script for dynamic package/tool installation
COPY agent-setup.sh /usr/local/bin/agent-setup.sh
RUN chmod +x /usr/local/bin/agent-setup.sh

# Copy agent-specific resolved artifacts into image at build time.
# These files are generated from .agents/<agent>/tools.toml by scripts/resolve-agent-tools.sh.
RUN mkdir -p /tmp/agent-build-tools /usr/local/bin/agent-tools
COPY --from=builder /app/.agents/${AGENT_NAME}/.build-tools/ /tmp/agent-build-tools/

# Install agent-specific APT packages declared in tools.toml [apt].packages
RUN if [ -s /tmp/agent-build-tools/apt-packages.txt ]; then \
      apt-get update && \
      xargs -r apt-get install -y --no-install-recommends < /tmp/agent-build-tools/apt-packages.txt && \
      rm -rf /var/lib/apt/lists/*; \
    fi

# Install Bun and global packages declared in tools.toml [bun].packages
RUN if [ -s /tmp/agent-build-tools/bun-packages.txt ]; then \
      export BUN_INSTALL=/opt/bun && \
      curl -fsSL https://bun.sh/install | bash && \
      ln -sf /opt/bun/bin/bun /usr/local/bin/bun && \
      xargs -r /usr/local/bin/bun add --global < /tmp/agent-build-tools/bun-packages.txt; \
    fi

RUN cp -a /tmp/agent-build-tools/. /usr/local/bin/agent-tools/ && \
    rm -f /usr/local/bin/agent-tools/apt-packages.txt /usr/local/bin/agent-tools/bun-packages.txt /usr/local/bin/agent-tools/.gitkeep
RUN find /usr/local/bin/agent-tools -maxdepth 1 -type f ! -name ".*.tool" -exec chmod +x {} \; || true

# Add agent-tools to PATH globally
ENV PATH="/opt/bun/bin:/usr/local/bin/agent-tools:${PATH}"

# Environment setup
# Use consistent workspace path
ENV ZEROCLAW_WORKSPACE=/zeroclaw-data/workspace
ENV HOME=/zeroclaw-data
# Defaults for local dev (Ollama) - matches config.template.toml
ENV PROVIDER="ollama"
ENV ZEROCLAW_MODEL="llama3.2"
ENV ZEROCLAW_GATEWAY_PORT=3000

# Note: API_KEY is intentionally NOT set here to avoid confusion.
# It is set in config.toml as the Ollama URL.

WORKDIR /zeroclaw-data
# Run as root so entrypoint can start tailscaled, then drop to zeroclaw user
EXPOSE 3000
VOLUME ["/var/lib/tailscale"]
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# ── Stage 4: Production Runtime (Distroless) ─────────────────
FROM gcr.io/distroless/cc-debian13:nonroot@sha256:84fcd3c223b144b0cb6edc5ecc75641819842a9679a3a58fd6294bec47532bf7 AS release

COPY --from=builder /app/zeroclaw /usr/local/bin/zeroclaw
COPY --from=permissions /zeroclaw-data /zeroclaw-data

# Environment setup
ENV ZEROCLAW_WORKSPACE=/zeroclaw-data/workspace
ENV HOME=/zeroclaw-data
# Default provider (model is set in config.toml, not here,
# so config file edits are not silently overridden)
ENV PROVIDER="openrouter"
ENV ZEROCLAW_GATEWAY_PORT=3000

# API_KEY must be provided at runtime!

WORKDIR /zeroclaw-data
USER 65534:65534
EXPOSE 3000
ENTRYPOINT ["zeroclaw"]
CMD ["gateway", "--port", "3000", "--host", "[::]"]
