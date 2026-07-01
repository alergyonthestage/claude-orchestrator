# ── Stage 1: Build Docker socket proxy ─────────────────────────────
FROM golang:1.22-bookworm AS proxy-builder
WORKDIR /build
COPY proxy/go.mod proxy/go.sum* ./
RUN go mod download 2>/dev/null || true
COPY proxy/ .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o cco-docker-proxy ./cmd/cco-docker-proxy/

# ── Stage 2: Main image ───────────────────────────────────────────
FROM node:22-bookworm

# ── System dependencies ──────────────────────────────────────────────
RUN apt-get update && apt-get install -y \
    git \
    tmux \
    jq \
    ripgrep \
    fzf \
    curl \
    wget \
    python3 \
    python3-pip \
    openssh-client \
    socat \
    less \
    vim \
    && rm -rf /var/lib/apt/lists/*

# ── Locale (UTF-8 support) ──────────────────────────────────────────
RUN apt-get update && apt-get install -y locales \
    && sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# ── Docker CLI (for Docker-from-Docker) ──────────────────────────────
# Install Docker CLI only (no daemon). Used to control host Docker via socket.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
       https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y docker-ce-cli docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# ── GitHub CLI ─────────────────────────────────────────────────────
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) \
       signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
       https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# ── gosu (drop-in su replacement for Docker entrypoints) ─────────────
# gosu does a direct exec without creating a new session/pty, so TTY
# passthrough works correctly — unlike su/sudo which break stdin forwarding.
RUN arch="$(dpkg --print-architecture)" \
    && curl -fsSL "https://github.com/tianon/gosu/releases/download/1.17/gosu-${arch}" -o /usr/local/bin/gosu \
    && chmod +x /usr/local/bin/gosu \
    && gosu nobody true

# ── Claude Code (native installer — ADR-0039) ────────────────────────
# The binary is NO LONGER baked into the image. The entrypoint installs it at
# first start (curl install.sh) into /home/claude/.local/{bin,share/claude},
# which is bind-mounted from a persistent host CACHE dir so it survives restarts
# and AUTO-UPDATES in place — no `cco build --no-cache` needed for upgrades, and
# no root-owned npm global dir, so the auto-updater is left ENABLED (no
# DISABLE_AUTOUPDATER). The default channel/version is `latest`; a user can pin
# it via the `~/.cco/claude-version` config knob or `cco build --claude-version`.
# CLAUDE_CODE_VERSION is the baked default the entrypoint forwards to install.sh
# when `cco start` does not override it.
ARG CLAUDE_CODE_VERSION=latest
ENV CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION}
# The native installer lives in ~/.local/bin; put it on PATH for all users.
ENV PATH="/home/claude/.local/bin:${PATH}"

# ── Framework MCP servers (pre-installed for instant startup) ─────────
# chrome-devtools-mcp: browser automation via CDP (used by browser.enabled feature)
RUN npm install -g chrome-devtools-mcp@latest

# ── MCP Server packages (optional pre-installation) ──────────────────
# Pre-install stdio MCP servers for faster startup.
# Override at build time: cco build --mcp-packages "pkg1 pkg2"
# Leave empty to rely on npx on-demand installation.
ARG MCP_PACKAGES=""
RUN if [ -n "$MCP_PACKAGES" ]; then npm install -g $MCP_PACKAGES; fi

# ── User setup script (global, build time) ─────────────────────────
# Heavy system-level setup (apt packages, compilers). Runs once during `cco build` as root.
# Lightweight runtime config (dotfiles, aliases) belongs in global/setup.sh (runs at `cco start` as claude).
# Pass content via: cco build (auto-reads global/setup-build.sh)
ARG SETUP_BUILD_SCRIPT_CONTENT=""
RUN if [ -n "$SETUP_BUILD_SCRIPT_CONTENT" ]; then \
        printf '%s' "$SETUP_BUILD_SCRIPT_CONTENT" > /tmp/setup-build.sh \
        && bash /tmp/setup-build.sh \
        && rm -f /tmp/setup-build.sh; \
    fi

# ── User setup ───────────────────────────────────────────────────────
# Create docker group with placeholder GID (adjusted at runtime by entrypoint
# to match host socket GID). Pre-creating ensures `chown claude:docker` never
# fails due to missing group.
RUN groupadd -g 999 docker \
    && useradd -m -s /bin/bash claude \
    && mkdir -p /home/claude/.claude /workspace \
    && chown -R claude:claude /home/claude /workspace

# ── Docker socket proxy (from builder stage) ──────────────────────
COPY --from=proxy-builder /build/cco-docker-proxy /usr/local/bin/cco-docker-proxy
RUN chmod +x /usr/local/bin/cco-docker-proxy

# ── Config files ─────────────────────────────────────────────────────
COPY config/tmux.conf /home/claude/.tmux.conf
COPY config/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY config/hooks/ /usr/local/bin/cco-hooks/
RUN chown claude:claude /home/claude/.tmux.conf \
    && chmod +x /usr/local/bin/entrypoint.sh \
    && chmod +x /usr/local/bin/cco-hooks/*.sh

# ── cco CLI (wrapped-cco shim — ADR-0036 D4) ─────────────────────────
# Bake the tool code so `cco` runs in-container behind the whitelist shim under
# container-operator mode (P9: cco on PATH, never a reimplementation). Only the
# code the whitelisted verbs need is baked: bin/ + lib/ (the CLI), templates/
# (pack|template create), changelog.yml + package.json (version/news). defaults/
# and migrations/ are NOT baked — the verbs that read them (init/update/sync) are
# host-only and refused by the shim. bin/cco resolves REPO_ROOT via its symlink,
# so /opt/cco is the framework root; jq is already installed above.
COPY bin/ /opt/cco/bin/
COPY lib/ /opt/cco/lib/
COPY templates/ /opt/cco/templates/
COPY changelog.yml package.json /opt/cco/
RUN chmod +x /opt/cco/bin/cco \
    && ln -sf /opt/cco/bin/cco /usr/local/bin/cco

# ── Managed settings (framework infrastructure — non-overridable) ────
COPY --chown=root:root defaults/managed/ /etc/claude-code/
# Directories need 755 (execute bit for traversal); files need 644 (read-only).
# Simple chmod -R 644 would break nested dirs like .claude/skills/init-workspace/.
RUN find /etc/claude-code/ -type d -exec chmod 755 {} + \
    && find /etc/claude-code/ -type f -exec chmod 644 {} +

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
