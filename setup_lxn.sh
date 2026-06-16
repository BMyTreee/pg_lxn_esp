#!/usr/bin/env bash
#
# One-script setup for the `lxn` host (Debian / Pi OS).
#
# Usage:
#   ./setup_lxn.sh <command> [options]
#
# Commands:
#   fix-sshd   Enable PasswordAuthentication + PubkeyAuthentication
#   ssh-key    One-time: enable key-based SSH login to lxn
#   ssh-pw     One-time: enable password-based SSH login on lxn
#   deploy     SCP + run PostgreSQL setup (install, role/db, schema)
#   tmux-install  Install tmux on lxn
#   tmux-run      Start the listener in a named tmux session
#   all        ssh-key + deploy (one-liner setup)
#

set -euo pipefail

# ── defaults / constants ─────────────────────────────────────────────────────
readonly SSH_HOST="${LXN_HOST:-lxn}"
readonly SSH_USER="${LXN_USER:-pi}"

# key
readonly KEY_ALGO="${LXN_KEY_ALGO:-ed25519}"
readonly KEY_COMMENT="${LXN_KEY_COMMENT:-lxn-deploy@$(hostname)}"

case "${KEY_ALGO}" in
    ed25519) readonly KEY_PATH="${HOME}/.ssh/id_ed25519" ;;
    rsa)     readonly KEY_PATH="${HOME}/.ssh/id_rsa"     ;;
    *)       echo "unsupported algo: ${KEY_ALGO}" >&2; exit 1 ;;
esac
readonly PUB_KEY="${KEY_PATH}.pub"

# deploy / pg
readonly REMOTE_DIR="${LXN_REMOTE_DIR:-/tmp/pg_setup}"
readonly PG_VERSION="${LXN_PG_VERSION:-16}"
readonly PG_DB="${LXN_PG_DB:-lxn}"
readonly PG_USER="${LXN_PG_USER:-lxn}"
readonly PG_PASSWORD="${LXN_PG_PASSWORD:-changeme}"

# tmux
readonly SESSION_NAME="${LXN_TMUX_SESSION:-listen_lxn}"
readonly WORKDIR="${LXN_TMUX_CWD:-/opt/listen_lxn_mqtt}"
readonly COMMAND="${LXN_TMUX_COMMAND:-/opt/listen_lxn_mqtt}"

# internal
readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SSHD_CONFIG="/etc/ssh/sshd_config"

# ── helpers ──────────────────────────────────────────────────────────────────
log()  { printf '\033[1;36m[lxn]\033[0m %s\n' "$*"; }
log_ok() { printf '\033[1;32m[lxn]\033[0m %s\n' "$*"; }
log_err() { printf '\033[1;31m[lxn:err]\033[0m %s\n' "$*" >&2; }
die()  { log_err "$*"; exit 1; }

remote_target() { printf '%s@%s' "${SSH_USER}" "${SSH_HOST}"; }

as_root_remote() {
    ssh "$(remote_target)" "bash -s" <<'REMOTE'
set -euo pipefail
as_root() { if [[ "${EUID}" -ne 0 ]]; then sudo "$@"; else "$@"; fi; }
REMOTE
}

# ── command: fix-sshd ───────────────────────────────────────────────────────
cmd_fix_sshd() {
    log "target=$(remote_target)"

    ssh "$(remote_target)" 'bash -s' <<REMOTE
set -euo pipefail
SSHD_CONFIG="${SSHD_CONFIG}"

sudo cp -n "\${SSHD_CONFIG}" "\${SSHD_CONFIG}.bak"
sudo sed -i -E 's|^[[:space:]]*#?[[:space:]]*(PasswordAuthentication).*|\1 yes|' "\${SSHD_CONFIG}"
sudo sed -i -E 's|^[[:space:]]*#?[[:space:]]*(PubkeyAuthentication).*|\1 yes|' "\${SSHD_CONFIG}"
for f in /etc/ssh/sshd_config.d/*.conf; do
    [[ -f "\$f" ]] || continue
    sudo sed -i -E 's|^[[:space:]]*#?[[:space:]]*(PasswordAuthentication).*|\1 yes|' "\$f"
    sudo sed -i -E 's|^[[:space:]]*#?[[:space:]]*(PubkeyAuthentication).*|\1 yes|' "\$f"
done
# fallback: append if directive is completely absent
grep -qE '^[[:space:]]*PasswordAuthentication' "\${SSHD_CONFIG}" || echo 'PasswordAuthentication yes' | sudo tee -a "\${SSHD_CONFIG}" >/dev/null
grep -qE '^[[:space:]]*PubkeyAuthentication' "\${SSHD_CONFIG}" || echo 'PubkeyAuthentication yes' | sudo tee -a "\${SSHD_CONFIG}" >/dev/null
grep -E '^[[:space:]]*(PasswordAuthentication|PubkeyAuthentication)' "\${SSHD_CONFIG}" || true
if command -v systemctl >/dev/null; then
    sudo systemctl restart sshd || sudo systemctl restart ssh
else
    sudo service sshd restart || sudo service ssh restart
fi
REMOTE

    log_ok "done. PasswordAuthentication + PubkeyAuthentication enabled"
}

# ── command: ssh-key ─────────────────────────────────────────────────────────
cmd_ssh_key() {
    log "target=$(remote_target) key=${KEY_PATH}"

    # 1. generate local key if missing
    if [[ -f "${KEY_PATH}" ]]; then
        log_ok "key exists: ${KEY_PATH}"
    else
        log "generating ${KEY_ALGO} key"
        mkdir -p "${HOME}/.ssh"
        chmod 700 "${HOME}/.ssh"
        ssh-keygen -t "${KEY_ALGO}" -f "${KEY_PATH}" -N "" -C "${KEY_COMMENT}"
    fi

    # 2. enable PubkeyAuthentication on remote
    log "on ${SSH_HOST}: enabling PubkeyAuthentication"
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

    # 3. install public key into authorized_keys
    log "on ${SSH_HOST}: installing public key"
    ssh "$(remote_target)" \
        'set -e; mkdir -p "${HOME}/.ssh"; chmod 700 "${HOME}/.ssh"; touch "${HOME}/.ssh/authorized_keys"; chmod 600 "${HOME}/.ssh/authorized_keys"; KEY="$(cat)"; grep -qF "${KEY}" "${HOME}/.ssh/authorized_keys" || echo "${KEY}" >> "${HOME}/.ssh/authorized_keys"; echo "entries: $(wc -l < "${HOME}/.ssh/authorized_keys")"' \
        < "${PUB_KEY}"

    # 4. verify
    log "verifying key login"
    if ssh -o BatchMode=yes -o PasswordAuthentication=no "$(remote_target)" \
        'echo "key login ok as $(whoami)@$(hostname)"'; then
        log_ok "passwordless SSH to ${SSH_HOST} is ready"
    else
        die "key login failed — check sshd_config and authorized_keys on remote"
    fi
}

# ── command: ssh-pw ──────────────────────────────────────────────────────────
cmd_ssh_pw() {
    log "target=$(remote_target)"

    ssh "$(remote_target)" 'bash -s' <<REMOTE
set -euo pipefail
SSHD_CONFIG="${SSHD_CONFIG}"

sudo cp -n "\${SSHD_CONFIG}" "\${SSHD_CONFIG}.bak"
for f in /etc/ssh/sshd_config.d/*.conf; do
    [[ -f "\$f" ]] || continue
    sudo sed -i -E 's|^[[:space:]]*#?[[:space:]]*PasswordAuthentication.*|PasswordAuthentication yes|' "\$f"
done
if grep -Eq '^[[:space:]]*#?[[:space:]]*PasswordAuthentication' "\${SSHD_CONFIG}"; then
    sudo sed -i -E 's|^[[:space:]]*#?[[:space:]]*PasswordAuthentication.*|PasswordAuthentication yes|' "\${SSHD_CONFIG}"
else
    echo 'PasswordAuthentication yes' | sudo tee -a "\${SSHD_CONFIG}" >/dev/null
fi

sudo sshd -t || true
grep -E '^[[:space:]]*PasswordAuthentication' "\${SSHD_CONFIG}" || true

if command -v systemctl >/dev/null; then
    sudo systemctl restart sshd || sudo systemctl restart ssh
else
    sudo service sshd restart || sudo service ssh restart
fi
REMOTE

    log "on ${SSH_HOST}: ensure user '${SSH_USER}' has a password"
    echo "  sudo passwd ${SSH_USER}"
    log_ok "done. login with: ssh $(remote_target)"
}

# ── command: deploy ──────────────────────────────────────────────────────────
cmd_deploy() {
    command -v scp >/dev/null || die "scp not found"
    command -v ssh >/dev/null || die "ssh not found"

    log "host=${SSH_HOST} user=${SSH_USER} pg=${PG_VERSION} db=${PG_DB}"

    # copy init.sql only (setup logic is embedded in this script)
    log "copying to ${REMOTE_DIR}"
    ssh "$(remote_target)" "mkdir -p '${REMOTE_DIR}'"
    scp "${HERE}/init.sql" "$(remote_target):${REMOTE_DIR}/"

    # run embedded PostgreSQL setup on remote (heredoc quoted → no local expansion)
    log "running PostgreSQL setup on ${SSH_HOST}"
    export PG_VERSION PG_DB PG_USER PG_PASSWORD REMOTE_DIR
    ssh "$(remote_target)" 'bash -s' <<'REMOTE'
set -euo pipefail
: "${PG_VERSION:=16}"
: "${PG_DB:=lxn}"
: "${PG_USER:=lxn}"
: "${PG_PASSWORD:=changeme}"
readonly REMOTE_DIR="${REMOTE_DIR:-/tmp/pg_setup}"
readonly INIT_SQL="${REMOTE_DIR}/init.sql"
log() { printf '\033[1;32m[setup]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[setup:err]\033[0m %s\n' "$*" >&2; exit 1; }
as_root() { if [[ "${EUID}" -ne 0 ]]; then sudo "$@"; else "$@"; fi; }
install_pg() {
    log "apt: update + install postgresql-${PG_VERSION}"
    as_root apt-get update -y
    if ! as_root apt-get install -y "postgresql-${PG_VERSION}"; then
        log "package missing — adding PGDG repo"
        as_root install -d /usr/share/postgresql-common/pgdg
        as_root curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
            https://www.postgresql.org/media/keys/ACCC4CF8.asc
        as_root sh -c "echo 'deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
            https://apt.postgresql.org/pub/repos/apt $(. /etc/os-release && echo \"${VERSION_CODENAME}\")-pgdg main' \
            > /etc/apt/sources.list.d/pgdg.list"
        as_root apt-get update -y
        as_root apt-get install -y "postgresql-${PG_VERSION}"
    fi
}
ensure_cluster() {
    log "starting cluster v${PG_VERSION}/main"
    as_root pg_ctlcluster "${PG_VERSION}" main start 2>/dev/null \
        || as_root systemctl enable --now postgresql
}
role_exists()     { as_root -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${PG_USER}'" | grep -q 1; }
database_exists() { as_root -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${PG_DB}'" | grep -q 1; }
ensure_role_db() {
    log "role/db: user=${PG_USER} db=${PG_DB}"
    if ! role_exists; then
        as_root -u postgres psql -c "CREATE ROLE \\"${PG_USER}\\" WITH LOGIN PASSWORD '${PG_PASSWORD}';"
    else
        as_root -u postgres psql -c "ALTER ROLE \\"${PG_USER}\\" WITH LOGIN PASSWORD '${PG_PASSWORD}';"
    fi
    if ! database_exists; then
        as_root -u postgres createdb -O "${PG_USER}" "${PG_DB}"
    fi
    as_root -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE \\"${PG_DB}\\" TO \\"${PG_USER}\\";"
}
load_init() {
    [[ -f "${INIT_SQL}" ]] || { log "no init.sql — skipping"; return 0; }
    log "loading ${INIT_SQL}"
    as_root -u postgres psql -d "${PG_DB}" -v ON_ERROR_STOP=1 -f "${INIT_SQL}"
}
main() {
    install_pg
    ensure_cluster
    ensure_role_db
    load_init
    log "postgresql ready: ${PG_USER}@/${PG_DB} on $(hostname)"
}
main "$@"
REMOTE
    unset PG_VERSION PG_DB PG_USER PG_PASSWORD

    log_ok "deploy done."
}

# ── command: tmux-install ───────────────────────────────────────────────────
cmd_tmux_install() {
    log "target=$(remote_target)"

    ssh "$(remote_target)" 'bash -s' <<REMOTE
set -euo pipefail
as_root() { if [[ "\${EUID}" -ne 0 ]]; then sudo "\$@"; else "\$@"; fi; }
if command -v tmux >/dev/null 2>&1; then
    echo "tmux already: \$(tmux -V)"
    exit 0
fi
as_root apt-get update -y
as_root apt-get install -y tmux
echo "installed: \$(tmux -V)"
REMOTE

    log_ok "done. interactive: ssh $(remote_target) -t tmux"
}

# ── command: tmux-run ───────────────────────────────────────────────────────
cmd_tmux_run() {
    log "target=$(remote_target) session=${SESSION_NAME} cmd=${COMMAND}"

    # ensure tmux
    log "ensuring tmux on ${SSH_HOST}"
    ssh "$(remote_target)" 'bash -s' <<REMOTE
set -euo pipefail
as_root() { if [[ "${EUID}" -ne 0 ]]; then sudo "$@"; else "$@"; fi; }
command -v tmux >/dev/null 2>&1 || as_root apt-get install -y tmux
REMOTE

    # start session (idempotent — skips if already running)
    log "starting session '${SESSION_NAME}'"
    ssh "$(remote_target)" \
        "tmux has-session -t '${SESSION_NAME}' 2>/dev/null \
            && echo 'session ${SESSION_NAME} already running' \
            || tmux new-session -d -s '${SESSION_NAME}' -c '${WORKDIR}' '${COMMAND}' \
            && tmux list-sessions"

    cat <<EOF

attach:  ssh $(remote_target) -t tmux attach -t ${SESSION_NAME}
tail:    ssh $(remote_target) 'tmux capture-pane -p -t ${SESSION_NAME} -S -50'
kill:    ssh $(remote_target) 'tmux kill-session -t ${SESSION_NAME}'
EOF
}

# ── command: prompt all (ask for PG user/pass) ──────────────────────────────
cmd_prompt_all() {
    log "enter PostgreSQL credentials (or leave blank for defaults)"

    read -r -p "PostgreSQL user [lxn]: " pg_user_input
    [[ -n "$pg_user_input" ]] && export LXN_PG_USER="$pg_user_input"

    read -r -s -p "PostgreSQL password [changeme]: " pg_pass_input
    echo
    [[ -n "$pg_pass_input" ]] && export LXN_PG_PASSWORD="$pg_pass_input"

    log "PG user=${LXN_PG_USER} password=***"
}

# ── main / dispatch ─────────────────────────────────────────────────────────
usage() {
    cat <<EOF

Usage:  ./setup_lxn.sh <command> [options]

Commands:
  fix-sshd    Enable PasswordAuthentication + PubkeyAuthentication
  ssh-key     One-time: enable key-based SSH login to lxn
  ssh-pw        One-time: enable password-based SSH login on lxn
  deploy        SCP + run PostgreSQL setup (install, role/db, schema)
  tmux-install  Install tmux on lxn
  tmux-run      Start the listener in a named tmux session
  all           ssh-key + deploy (one-liner setup)

Config (env vars):
  LXN_HOST, LXN_USER          — SSH target (default: pi@lxn)
  LXN_KEY_ALGO, LXN_KEY_COMMENT — SSH key type / comment
  LXN_REMOTE_DIR              — staging dir on remote (default: /tmp/pg_setup)
  LXN_PG_VERSION, LXN_PG_DB, LXN_PG_USER, LXN_PG_PASSWORD — PG config
  LXN_TMUX_SESSION, LXN_TMUX_CWD, LXN_TMUX_COMMAND — tmux config

Example:
  LXN_PG_PASSWORD='s3cret' ./setup_lxn.sh deploy
EOF
}

[[ $# -eq 0 ]] && { usage; exit 1; }

case "${1}" in
    fix-sshd)   cmd_fix_sshd ;;
    ssh-key)    cmd_ssh_key ;;
    ssh-pw)       cmd_ssh_pw ;;
    deploy)       cmd_deploy ;;
    tmux-install) cmd_tmux_install ;;
    tmux-run)     cmd_tmux_run ;;
    all)          cmd_prompt_all; cmd_ssh_key; cmd_deploy; cmd_tmux_install; cmd_tmux_run ;;
    -h|--help|help) usage ;;
    *) die "unknown command: $1 (try --help)" ;;
esac
