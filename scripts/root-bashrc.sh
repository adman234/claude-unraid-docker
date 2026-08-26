
# --- claude-code container --------------------------------------------------
# Unraid's console button and `docker exec -it ... bash` both land here as root.
# Hop straight to the unprivileged user so files land on the array with sane
# ownership. Set RUN_AS_ROOT=true, or export CLAUDE_ROOT_SHELL=1, to opt out.
if [ -t 0 ] \
   && [ -z "${CLAUDE_ROOT_SHELL:-}" ] \
   && [ "$(id -u)" = "0" ] \
   && [ "${RUN_AS_ROOT:-false}" != "true" ] \
   && id -u "${CLAUDE_USER:-claude}" >/dev/null 2>&1 \
   && command -v gosu >/dev/null 2>&1; then
    export CLAUDE_ROOT_SHELL=1
    # gosu preserves the environment, so HOME would otherwise stay /root.
    export HOME="/home/${CLAUDE_USER:-claude}"
    export USER="${CLAUDE_USER:-claude}"
    cd "${PWD:-/workspace}" 2>/dev/null || cd /workspace
    exec gosu "${CLAUDE_USER:-claude}" /bin/bash -l
fi
