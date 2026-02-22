# syntax=docker/dockerfile:1.7

# ── Stage 1: Build ────────────────────────────────────────────
FROM rust:1.93-slim@sha256:9663b80a1621253d30b146454f903de48f0af925c967be48c84745537cd35d8b AS builder

WORKDIR /app

# Install build dependencies
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

# 1. Copy manifests to cache dependencies
COPY Cargo.toml Cargo.lock ./
COPY crates/robot-kit/Cargo.toml crates/robot-kit/Cargo.toml
# Create dummy targets declared in Cargo.toml so manifest parsing succeeds.
RUN mkdir -p src benches crates/robot-kit/src \
    && echo "fn main() {}" > src/main.rs \
    && echo "fn main() {}" > benches/agent_benchmarks.rs \
    && echo "pub fn placeholder() {}" > crates/robot-kit/src/lib.rs
RUN --mount=type=cache,id=zeroclaw-cargo-registry,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,id=zeroclaw-cargo-git,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,id=zeroclaw-target,target=/app/target,sharing=locked \
    cargo build --release --locked
RUN rm -rf src benches crates/robot-kit/src

# 2. Copy only build-relevant source paths (avoid cache-busting on docs/tests/scripts)
COPY src/ src/
COPY web/ web/
COPY benches/ benches/
COPY crates/ crates/
COPY firmware/ firmware/
COPY web/dist/ web/dist/
RUN --mount=type=cache,id=zeroclaw-cargo-registry,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,id=zeroclaw-cargo-git,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,id=zeroclaw-target,target=/app/target,sharing=locked \
    cargo build --release --locked && \
    cp target/release/zeroclaw /app/zeroclaw && \
    strip /app/zeroclaw

# Prepare runtime directory structure and default config inline (no extra stage)
RUN mkdir -p /zeroclaw-data/.zeroclaw /zeroclaw-data/workspace && \
    cat > /zeroclaw-data/.zeroclaw/config.toml <<EOF && \
    chown -R 65534:65534 /zeroclaw-data
workspace_dir = "/zeroclaw-data/workspace"
config_path = "/zeroclaw-data/.zeroclaw/config.toml"
api_key = ""
default_provider = "openrouter"
default_model = "anthropic/claude-sonnet-4-20250514"
default_temperature = 0.7

[gateway]
port = 42617
host = "[::]"
allow_public_bind = true

[tunnel]
provider = "none"
EOF

# ── Stage 2: Development Runtime (Debian with Tailscale) ─────
FROM debian:trixie-slim@sha256:f6e2cfac5cf956ea044b4bd75e6397b4372ad88fe00908045e9a0d21712ae3ba AS dev

ARG AGENT_NAME="_default"

# Install runtime dependencies + basic debug tools + Tailscale support
RUN apt-get update && apt-get install -y \
    ca-certificates \
    curl \
    git \
    iputils-ping \
    vim \
    jq \
    iproute2 \
    iptables \
    procps \
        tar \
        unzip \
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

COPY --from=builder /zeroclaw-data /zeroclaw-data
COPY --from=builder /app/zeroclaw /usr/local/bin/zeroclaw

# Create dedicated users:
# - zeroclaw: agent runtime user
# - docsd: managed-docs writer daemon user
# Both share zeroclawdocs group so zeroclaw can connect to docsd socket.
RUN groupadd -g 1010 zeroclawdocs && \
    useradd -m -u 1000 -s /bin/bash -d /zeroclaw-data -G zeroclawdocs zeroclaw && \
    useradd -M -u 1001 -s /usr/sbin/nologin -g zeroclawdocs docsd && \
    mkdir -p /zeroclaw-data/workspace/.managed-docs && \
    chown -R zeroclaw:zeroclaw /zeroclaw-data /var/lib/tailscale /var/run/tailscale && \
    chown -R docsd:zeroclawdocs /zeroclaw-data/workspace/.managed-docs && \
    chmod 0770 /zeroclaw-data/workspace/.managed-docs

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

# Copy agent-specific scaffold files into image at build time.
COPY .agents/${AGENT_NAME}/ /agent-config/

# Copy agent-specific resolved artifacts into image at build time.
# These files are generated from .agents/<agent>/tools.toml by scripts/resolve-agent-tools.sh.
RUN mkdir -p /tmp/agent-build-tools /usr/local/bin/agent-tools
COPY .agents/${AGENT_NAME}/.build-tools/ /tmp/agent-build-tools/

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
      xargs -r /usr/local/bin/bun add --global < /tmp/agent-build-tools/bun-packages.txt && \
      if [ -x /opt/bun/bin/playwriter ]; then ln -sf /opt/bun/bin/playwriter /usr/local/bin/playwriter; fi; \
    fi

# Optional agent-specific skill installs (via npm/npx).
RUN if [ -f /agent-config/skills.install ]; then \
      chmod +x /agent-config/skills.install && /agent-config/skills.install; \
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
ENV AGENT_CONFIG_DIR=/agent-config
# Defaults for local dev (Ollama) - matches config.template.toml
ENV PROVIDER="ollama"
ENV ZEROCLAW_MODEL="llama3.2"
ENV ZEROCLAW_GATEWAY_PORT=3000
ENV DOCSD_SOCKET=/zeroclaw-data/workspace/.managed-docs/docsd.sock

# Note: API_KEY is intentionally NOT set here to avoid confusion.
# It is set in config.toml as the Ollama URL.

WORKDIR /zeroclaw-data
# Run as root so entrypoint can start tailscaled, then drop to zeroclaw user
EXPOSE 3000
VOLUME ["/var/lib/tailscale"]
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# ── Stage 3: Production Runtime (Distroless) ─────────────────
FROM gcr.io/distroless/cc-debian13:nonroot@sha256:84fcd3c223b144b0cb6edc5ecc75641819842a9679a3a58fd6294bec47532bf7 AS release

COPY --from=builder /app/zeroclaw /usr/local/bin/zeroclaw
COPY --from=builder /zeroclaw-data /zeroclaw-data

# Environment setup
ENV ZEROCLAW_WORKSPACE=/zeroclaw-data/workspace
ENV HOME=/zeroclaw-data
# Default provider and model are set in config.toml, not here,
# so config file edits are not silently overridden
#ENV PROVIDER=
ENV ZEROCLAW_GATEWAY_PORT=42617

# API_KEY must be provided at runtime!

WORKDIR /zeroclaw-data
USER 65534:65534
EXPOSE 42617
ENTRYPOINT ["zeroclaw"]
CMD ["gateway"]
