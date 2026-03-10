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

# ── Claude Code ──────────────────────────────────────────────────────
# Pin version for reproducible builds: cco build --build-arg CLAUDE_CODE_VERSION=1.0.x
ARG CLAUDE_CODE_VERSION=latest
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}
ENV CLAUDE_CODE_DISABLE_AUTOUPDATE=1

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
# Create claude user. Docker socket GID is set at runtime via entrypoint.
RUN useradd -m -s /bin/bash claude \
    && mkdir -p /home/claude/.claude /workspace \
    && chown -R claude:claude /home/claude /workspace

# ── Config files ─────────────────────────────────────────────────────
COPY config/tmux.conf /home/claude/.tmux.conf
COPY config/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY config/hooks/ /usr/local/bin/cco-hooks/
RUN chown claude:claude /home/claude/.tmux.conf \
    && chmod +x /usr/local/bin/entrypoint.sh \
    && chmod +x /usr/local/bin/cco-hooks/*.sh

# ── Managed settings (framework infrastructure — non-overridable) ────
COPY --chown=root:root defaults/managed/ /etc/claude-code/
# Directories need 755 (execute bit for traversal); files need 644 (read-only).
# Simple chmod -R 644 would break nested dirs like .claude/skills/init-workspace/.
RUN find /etc/claude-code/ -type d -exec chmod 755 {} + \
    && find /etc/claude-code/ -type f -exec chmod 644 {} +

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
