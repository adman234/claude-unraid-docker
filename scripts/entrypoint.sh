#!/usr/bin/env bash
# Runs as root, sets up the unprivileged user + persistent home, then drops
# privileges for the long-running process.
set -euo pipefail

PUID="${PUID:-99}"
PGID="${PGID:-100}"
UMASK_SET="${UMASK:-022}"
CLAUDE_USER="${CLAUDE_USER:-claude}"
RUN_AS_ROOT="${RUN_AS_ROOT:-false}"
HOME_DIR="/home/${CLAUDE_USER}"

log() { printf '[claude-code] %s\n' "$*"; }

umask "${UMASK_SET}"

if [ -n "${TZ:-}" ] && [ -f "/usr/share/zoneinfo/${TZ}" ]; then
    ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime
    echo "${TZ}" > /etc/timezone
fi

# --- user / group -----------------------------------------------------------
# Unraid shares are owned by nobody:users (99:100). Matching that by default
# means files Claude creates on the array look like every other file on it,
# instead of root-owned files the webUI and other containers choke on.
if ! getent group "${PGID}" >/dev/null 2>&1; then
    # `docker restart` keeps the writable layer, so a group we created on a
    # previous start may still exist under the old GID. Move it, don't re-add.
    if getent group "${CLAUDE_USER}" >/dev/null 2>&1; then
        groupmod -o -g "${PGID}" "${CLAUDE_USER}"
    else
        groupadd -o -g "${PGID}" "${CLAUDE_USER}"
    fi
fi
GROUP_NAME="$(getent group "${PGID}" | cut -d: -f1)"

if id -u "${CLAUDE_USER}" >/dev/null 2>&1; then
    usermod -o -u "${PUID}" -g "${PGID}" -d "${HOME_DIR}" -s /bin/bash "${CLAUDE_USER}" >/dev/null
else
    useradd -o -u "${PUID}" -g "${PGID}" -d "${HOME_DIR}" -s /bin/bash -M "${CLAUDE_USER}"
fi

case "${RUN_AS_ROOT}" in
    [Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]) DROP_PRIVS=false ;;
    *) DROP_PRIVS=true ;;
esac

if [ "${DROP_PRIVS}" = "true" ]; then
    log "running as ${CLAUDE_USER} (uid=${PUID} gid=${PGID} group=${GROUP_NAME} umask=${UMASK_SET})"
else
    log "RUN_AS_ROOT is set: running as root; files Claude creates will be root-owned"
fi

# --- persistent home --------------------------------------------------------
# This is the whole point of the container: ~/.claude.json holds your login, so
# persisting it is what stops you re-authenticating after every restart.
CLAUDE_DIRS=(
    "${HOME_DIR}/.claude"
    "${HOME_DIR}/.config"
    "${HOME_DIR}/.cache"
    "${HOME_DIR}/.local/bin"
)
mkdir -p "${CLAUDE_DIRS[@]}"

if [ "$(stat -c %u "${HOME_DIR}")" != "${PUID}" ] || [ "$(stat -c %g "${HOME_DIR}")" != "${PGID}" ]; then
    log "fixing ownership of ${HOME_DIR} (one-off, may take a moment)"
    chown -R "${PUID}:${PGID}" "${HOME_DIR}"
else
    # The recursive pass above is skipped on a normal restart, so claim any dir
    # mkdir just created as root. Non-recursive: never touch user data.
    chown "${PUID}:${PGID}" "${HOME_DIR}/.local" "${CLAUDE_DIRS[@]}" 2>/dev/null || true
fi

# Only claim /workspace if nobody else has; never recurse into user data.
if [ -d /workspace ] && [ "$(stat -c %u /workspace)" = "0" ]; then
    chown "${PUID}:${PGID}" /workspace 2>/dev/null || true
fi

# Repos on the array are owned by whatever wrote them; without this git refuses
# to touch them with "detected dubious ownership".
# gosu preserves the environment, so HOME must be set explicitly or these run
# against root's home.
run_as_claude() { HOME="${HOME_DIR}" USER="${CLAUDE_USER}" gosu "${CLAUDE_USER}" "$@"; }

if ! run_as_claude git config --global --get-all safe.directory 2>/dev/null | grep -qx '\*'; then
    run_as_claude git config --global --add safe.directory '*' \
        || log "warning: could not set git safe.directory; git may refuse repos owned by other users"
fi

# --- optional update on start ----------------------------------------------
case "${CLAUDE_UPDATE_ON_START:-false}" in
    [Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss])
        log "CLAUDE_UPDATE_ON_START set, updating Claude Code..."
        npm install -g @anthropic-ai/claude-code@latest \
            || log "update failed; continuing with the version baked into the image"
        ;;
esac

log "Claude Code $(claude --version 2>/dev/null || echo 'version unknown') ready"
log "attach with the Unraid console button, or: docker exec -it claude-code claude-code"

# --- hand off ---------------------------------------------------------------
if [ "${DROP_PRIVS}" != "true" ]; then
    exec /usr/bin/tini -g -- "$@"
fi

export HOME="${HOME_DIR}"
export USER="${CLAUDE_USER}"
exec /usr/bin/tini -g -- gosu "${CLAUDE_USER}" "$@"
