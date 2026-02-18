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

# ── Claude Code ──────────────────────────────────────────────────────
RUN npm install -g @anthropic-ai/claude-code@latest

# ── User setup ───────────────────────────────────────────────────────
# Create claude user. Docker socket GID is set at runtime via entrypoint.
RUN useradd -m -s /bin/bash claude \
    && mkdir -p /home/claude/.claude /workspace \
    && chown -R claude:claude /home/claude /workspace

# ── Config files ─────────────────────────────────────────────────────
COPY config/tmux.conf /home/claude/.tmux.conf
COPY config/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chown claude:claude /home/claude/.tmux.conf \
    && chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
