# Shown on interactive login shells inside the container.
case "$-" in *i*) ;; *) return ;; esac

if [ -z "${CLAUDE_BANNER_SHOWN:-}" ]; then
    export CLAUDE_BANNER_SHOWN=1
    printf '\n\033[38;5;173m  Claude Code\033[0m on Unraid  \033[2m(%s)\033[0m\n\n' \
        "$(claude --version 2>/dev/null || echo 'version unknown')"
    printf '  \033[1mclaude\033[0m          start Claude Code here (%s)\n' "$(pwd)"
    printf '  \033[1mclaude --help\033[0m   all options\n'
    printf '  \033[1m/login\033[0m          authenticate (inside Claude Code, first run only)\n\n'
    printf '  \033[2mYour login and settings live in ~/.claude* and survive restarts.\033[0m\n'
    printf '  \033[2mMounted host paths are readable directly -- no filesystem MCP needed.\033[0m\n\n'
fi
