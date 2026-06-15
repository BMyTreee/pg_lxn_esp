#!/usr/bin/env bash
#
# One-time setup: enable SSH key login to the `lxn` host.
#   1. generate a local key if missing
#   2. on lxn: uncomment `PubkeyAuthentication yes` in /etc/ssh/sshd_config
#   3. on lxn: append our public key to ~/.ssh/authorized_keys
#   4. restart sshd
#   5. verify key login
#
set -euo pipefail

# ── constants ────────────────────────────────────────────────────────────────
readonly SSH_HOST="${LXN_HOST:-lxn}"
readonly SSH_USER="${LXN_USER:-pi}"
readonly KEY_ALGO="${LXN_KEY_ALGO:-ed25519}"
readonly KEY_COMMENT="${LXN_KEY_COMMENT:-lxn-deploy@$(hostname)}"

case "${KEY_ALGO}" in
    ed25519) readonly KEY_PATH="${HOME}/.ssh/id_ed25519" ;;
    rsa)     readonly KEY_PATH="${HOME}/.ssh/id_rsa"     ;;
    *)       echo "unsupported algo: ${KEY_ALGO}" >&2; exit 1 ;;
esac
readonly PUB_KEY="${KEY_PATH}.pub"

readonly SSHD_CONFIG="/etc/ssh/sshd_config"

# ── helpers ──────────────────────────────────────────────────────────────────
log() { printf '\033[1;35m[ssh]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[ssh:err]\033[0m %s\n' "$*" >&2; exit 1; }

remote_target() { printf '%s@%s' "${SSH_USER}" "${SSH_HOST}"; }

# ── local: ensure key ────────────────────────────────────────────────────────
ensure_key() {
    if [[ -f "${KEY_PATH}" ]]; then
        log "key exists: ${KEY_PATH}"
        return 0
    fi
    log "generating ${KEY_ALGO} key at ${KEY_PATH}"
    mkdir -p "${HOME}/.ssh"
    chmod 700 "${HOME}/.ssh"
    ssh-keygen -t "${KEY_ALGO}" -f "${KEY_PATH}" -N "" -C "${KEY_COMMENT}"
}

# ── remote: uncomment PubkeyAuthentication yes ───────────────────────────────
enable_pubkey_in_sshd() {
    log "on ${SSH_HOST}: enabling PubkeyAuthentication in ${SSHD_CONFIG}"
    #   - back up the original
    #   - turn "#PubkeyAuthentication yes" / "PubkeyAuthentication no" → "PubkeyAuthentication yes"
    #   - if the directive is absent, append it
    #   - restart sshd (systemd or service)
    ssh "$(remote_target)" 'bash -s' <<REMOTE
set -euo pipefail
SSHD_CONFIG="${SSHD_CONFIG}"

sudo cp -n "\${SSHD_CONFIG}" "\${SSHD_CONFIG}.bak"

if grep -Eq '^[[:space:]]*#?[[:space:]]*PubkeyAuthentication' "\${SSHD_CONFIG}"; then
    sudo sed -i -E 's|^[[:space:]]*#?[[:space:]]*PubkeyAuthentication.*|PubkeyAuthentication yes|' "\${SSHD_CONFIG}"
else
    echo 'PubkeyAuthentication yes' | sudo tee -a "\${SSHD_CONFIG}" >/dev/null
fi
grep -E '^[[:space:]]*PubkeyAuthentication' "\${SSHD_CONFIG}"

if command -v systemctl >/dev/null; then
    sudo systemctl restart sshd || sudo systemctl restart ssh
else
    sudo service sshd restart || sudo service ssh restart
fi
REMOTE
}

# ── remote: append our public key to authorized_keys ─────────────────────────
install_authorized_key() {
    log "on ${SSH_HOST}: appending public key to ~/.ssh/authorized_keys"
    # pubkey is piped via stdin; remote reads it once into $KEY, dedups, appends
    ssh "$(remote_target)" \
        'set -e; mkdir -p "${HOME}/.ssh"; chmod 700 "${HOME}/.ssh"; touch "${HOME}/.ssh/authorized_keys"; chmod 600 "${HOME}/.ssh/authorized_keys"; KEY="$(cat)"; grep -qF "${KEY}" "${HOME}/.ssh/authorized_keys" || echo "${KEY}" >> "${HOME}/.ssh/authorized_keys"; echo "authorized_keys entries: $(wc -l < "${HOME}/.ssh/authorized_keys")"' \
        < "${PUB_KEY}"
}

# ── verify ───────────────────────────────────────────────────────────────────
verify_login() {
    log "verifying key-based login (no password allowed)"
    if ssh -o BatchMode=yes -o PasswordAuthentication=no "$(remote_target)" \
        'echo "key login ok as $(whoami)@$(hostname)"'; then
        log "success — passwordless SSH to ${SSH_HOST} is ready"
    else
        die "key login failed — check ${SSHD_CONFIG} and authorized_keys on remote"
    fi
}

# ── main ─────────────────────────────────────────────────────────────────────
main() {
    log "target=$(remote_target) key=${KEY_PATH}"
    ensure_key
    enable_pubkey_in_sshd
    install_authorized_key
    verify_login
}

main "$@"
