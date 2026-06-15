#!/usr/bin/env bash
#
# Enable SSH password login on the `lxn` host.
#   - backs up /etc/ssh/sshd_config
#   - sets `PasswordAuthentication yes` (uncomment / flip / append)
#   - restarts sshd
#
set -euo pipefail

# ── constants ────────────────────────────────────────────────────────────────
readonly SSH_HOST="${LXN_HOST:-lxn}"
readonly SSH_USER="${LXN_USER:-pi}"
readonly SSHD_CONFIG="/etc/ssh/sshd_config"

# ── helpers ──────────────────────────────────────────────────────────────────
log() { printf '\033[1;33m[pw-ssh]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[pw-ssh:err]\033[0m %s\n' "$*" >&2; exit 1; }

remote_target() { printf '%s@%s' "${SSH_USER}" "${SSH_HOST}"; }

# ── steps ────────────────────────────────────────────────────────────────────
enable_password_auth() {
    log "on ${SSH_HOST}: enabling PasswordAuthentication in ${SSHD_CONFIG}"
    ssh "$(remote_target)" 'bash -s' <<REMOTE
set -euo pipefail
SSHD_CONFIG="${SSHD_CONFIG}"

sudo cp -n "\${SSHD_CONFIG}" "\${SSHD_CONFIG}.bak"

# also clear any drop-in override that would force it back to no
for f in /etc/ssh/sshd_config.d/*.conf; do
    [[ -f "\$f" ]] || continue
    sudo sed -i -E 's|^[[:space:]]*#?[[:space:]]*PasswordAuthentication.*|PasswordAuthentication yes|' "\$f"
done

if grep -Eq '^[[:space:]]*#?[[:space:]]*PasswordAuthentication' "\${SSHD_CONFIG}"; then
    sudo sed -i -E 's|^[[:space:]]*#?[[:space:]]*PasswordAuthentication.*|PasswordAuthentication yes|' "\${SSHD_CONFIG}"
else
    echo 'PasswordAuthentication yes' | sudo tee -a "\${SSHD_CONFIG}" >/dev/null
fi

sudo sshd -t
grep -E '^[[:space:]]*PasswordAuthentication' "\${SSHD_CONFIG}"

if command -v systemctl >/dev/null; then
    sudo systemctl restart sshd || sudo systemctl restart ssh
else
    sudo service sshd restart || sudo service ssh restart
fi
REMOTE
}

ensure_user_password() {
    log "on ${SSH_HOST}: ensuring ${SSH_USER} has a password"
    echo "if you don't know the current password, run this on ${SSH_HOST}:"
    echo "    sudo passwd ${SSH_USER}"
}

# ── main ─────────────────────────────────────────────────────────────────────
main() {
    command -v ssh >/dev/null || die "ssh not found"
    log "target=$(remote_target)"
    enable_password_auth
    ensure_user_password
    log "done. login with:  ssh $(remote_target)"
}

main "$@"
