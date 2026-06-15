#!/usr/bin/env bash
#
# Start (or attach to) a named tmux session on `lxn`, running a command.
# Default command: run the listen_lxn_mqtt binary (assumes it's deployed on lxn).
#
# Usage:
#   ./tmux_run.sh                              # uses defaults
#   LXN_TMUX_COMMAND='/opt/listen_lxn_mqtt' ./tmux_run.sh
#   LXN_TMUX_COMMAND='bash -lc "cargo run"' ./tmux_run.sh
#
set -euo pipefail

# ── constants ────────────────────────────────────────────────────────────────
readonly SSH_HOST="${LXN_HOST:-lxn}"
readonly SSH_USER="${LXN_USER:-pi}"
readonly SESSION_NAME="${LXN_TMUX_SESSION:-listen_lxn}"
readonly WORKDIR="${LXN_TMUX_CWD:-/opt/listen_lxn_mqtt}"
readonly COMMAND="${LXN_TMUX_COMMAND:-/opt/listen_lxn_mqtt}"

# ── helpers ──────────────────────────────────────────────────────────────────
log() { printf '\033[1;36m[tmux]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[tmux:err]\033[0m %s\n' "$*" >&2; exit 1; }

remote_target() { printf '%s@%s' "${SSH_USER}" "${SSH_HOST}"; }

# ── steps ────────────────────────────────────────────────────────────────────
ensure_tmux() {
    log "ensuring tmux is present on ${SSH_HOST}"
    ssh "$(remote_target)" 'bash -s' <<'REMOTE'
set -euo pipefail
as_root() { if [[ "${EUID}" -ne 0 ]]; then sudo "$@"; else "$@"; fi; }
command -v tmux >/dev/null 2>&1 || as_root apt-get install -y tmux
REMOTE
}

start_session() {
    log "starting session '${SESSION_NAME}' on ${SSH_HOST}"
    ssh "$(remote_target)" \
        "tmux has-session -t '${SESSION_NAME}' 2>/dev/null \
            && echo 'session ${SESSION_NAME} already running' \
            || tmux new-session -d -s '${SESSION_NAME}' -c '${WORKDIR}' '${COMMAND}' \
            && tmux list-sessions"
}

# ── main ─────────────────────────────────────────────────────────────────────
attach_usage() {
    cat <<EOF

attach with:
    ssh $(remote_target) -t tmux attach -t ${SESSION_NAME}

tail output (no attach):
    ssh $(remote_target) 'tmux capture-pane -p -t ${SESSION_NAME} -S -50'

kill session:
    ssh $(remote_target) 'tmux kill-session -t ${SESSION_NAME}'
EOF
}

main() {
    command -v ssh >/dev/null || die "ssh not found"
    log "target=$(remote_target) session=${SESSION_NAME} cmd=${COMMAND}"
    ensure_tmux
    start_session
    attach_usage
}

main "$@"
