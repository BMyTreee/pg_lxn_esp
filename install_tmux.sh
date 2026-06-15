#!/usr/bin/env bash
#
# Install tmux on the `lxn` host via apt.
#
set -euo pipefail

# ── constants ────────────────────────────────────────────────────────────────
readonly SSH_HOST="${LXN_HOST:-lxn}"
readonly SSH_USER="${LXN_USER:-pi}"

# ── helpers ──────────────────────────────────────────────────────────────────
log() { printf '\033[1;36m[tmux]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[tmux:err]\033[0m %s\n' "$*" >&2; exit 1; }

remote_target() { printf '%s@%s' "${SSH_USER}" "${SSH_HOST}"; }

# ── steps ────────────────────────────────────────────────────────────────────
install_tmux() {
    log "installing tmux on ${SSH_HOST}"
    ssh "$(remote_target)" 'bash -s' <<REMOTE
set -euo pipefail
as_root() { if [[ "\${EUID}" -ne 0 ]]; then sudo "\$@"; else "\$@"; fi; }

if command -v tmux >/dev/null 2>&1; then
    echo "tmux already installed: \$(tmux -V)"
    exit 0
fi

as_root apt-get update -y
as_root apt-get install -y tmux
echo "installed: \$(tmux -V)"
REMOTE
}

# ── main ─────────────────────────────────────────────────────────────────────
main() {
    command -v ssh >/dev/null || die "ssh not found"
    log "target=$(remote_target)"
    install_tmux
    log "done. start a session with:  ssh $(remote_target) -t tmux"
}

main "$@"
