# syntax=docker/dockerfile:1

# Debian (glibc) base on purpose: Claude Code ships prebuilt native helpers
# (ripgrep among them) that are built against glibc. Alpine/musl works most of
# the time and then fails in confusing ways, so we don't use it.
FROM node:22-bookworm-slim

ARG CLAUDE_CODE_VERSION=latest
ARG BUILD_DATE
ARG VCS_REF

LABEL org.opencontainers.image.title="Claude Code for Unraid" \
      org.opencontainers.image.description="Claude Code CLI in a persistent toolbox container for Unraid" \
      org.opencontainers.image.source="https://github.com/adman234/claude-unraid-docker" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}"

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    TERM=xterm-256color \
    SHELL=/bin/bash \
    npm_config_update_notifier=false \
    DISABLE_AUTOUPDATER=1

# Runtime toolbox. These are the things you actually reach for when an agent is
# driving a shell on a NAS: git, a pager, an editor, network + archive tools.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      curl \
      wget \
      git \
      git-lfs \
      openssh-client \
      ripgrep \
      fd-find \
      jq \
      less \
      nano \
      procps \
      psmisc \
      htop \
      tree \
      rsync \
      unzip \
      zip \
      xz-utils \
      python3 \
      python3-venv \
      tini \
      gosu \
      tzdata \
      locales \
 && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
 && rm -rf /var/lib/apt/lists/*

# Baked into the image so the container starts instantly and works even if npm
# is unreachable. Update by pulling a newer image (or CLAUDE_UPDATE_ON_START).
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
 && npm cache clean --force \
 && claude --version

COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/claude-code /usr/local/bin/claude-code
COPY scripts/claude-update /usr/local/bin/claude-update
COPY scripts/profile-banner.sh /etc/profile.d/00-claude-code.sh
COPY scripts/root-bashrc.sh /etc/claude-code/root-bashrc.sh

RUN chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/claude-code \
             /usr/local/bin/claude-update \
 && mkdir -p /home/claude /workspace \
 && cat /etc/claude-code/root-bashrc.sh >> /root/.bashrc

WORKDIR /workspace

VOLUME ["/home/claude"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# Claude Code is an interactive TUI, not a daemon. The container's job is to sit
# there holding a ready-to-use environment; you attach to it with the Unraid
# console button or `docker exec`.
CMD ["sleep", "infinity"]
