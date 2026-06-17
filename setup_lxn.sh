#!/usr/bin/env bash
#
# Repair script for lxn host (local execution).
#
# Usage:
#   ./setup_lxn.sh <command> [options]
#
# Commands:
#   fix-sshd    Enable PasswordAuthentication + PubkeyAuthentication in sshd_config
#   tmux-uninstall  Remove tmux from the system
#   deploy      Install PostgreSQL, create role/db/schema
#   all         fix-sshd + tmux-uninstall + deploy (full repair)

set -euo pipefail

# ── defaults / constants ─────────────────────────────────────────────────────
readonly SSHD_CONFIG="/etc/ssh/sshd_config"

# pg
readonly PG_VERSION="${LXN_PG_VERSION:-16}"
readonly PG_DB="${LXN_PG_DB:-lxn}"
readonly PG_USER="${LXN_PG_USER:-lxn}"
readonly PG_PASSWORD="${LXN_PG_PASSWORD:-changeme}"
readonly PG_ALLOWED_NET="${LXN_PG_ALLOWED_NET:-0.0.0.0/0}"
readonly PG_HBA_AUTH="${LXN_PG_HBA_AUTH:-scram-sha-256}"
readonly PG_HBA_MARKER="# lxn-managed (do not edit)"
readonly PG_LOG="${LXN_PG_LOG:-/var/log/postgresql/postgresql-${PG_VERSION}-main.log}"

# repo (clone target on lxn)
readonly LXN_REPO_URL="${LXN_REPO_URL:-git@github.com:BMyTreee/pg_lxn_esp.git}"
readonly LXN_REPO_DIR="${LXN_REPO_DIR:-${HOME}/pg_lxn_esp}"

# tmux listener session
readonly TMUX_SESSION="${LXN_TMUX_SESSION:-listen_lxn}"
readonly TMUX_LISTENER_CMD="${LXN_TMUX_LISTENER_CMD:-}"
readonly TMUX_LOG_LINES="${LXN_LOG_LINES:-50}"

# internal
readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REMOTE_DIR="${LXN_REMOTE_DIR:-/tmp/pg_setup}"

# ── helpers ──────────────────────────────────────────────────────────────────
log()  { printf '\033[1;36m[lxn]\033[0m %s\n' "$*"; }
log_ok() { printf '\033[1;32m[lxn]\033[0m %s\n' "$*"; }
log_err() { printf '\033[1;31m[lxn:err]\033[0m %s\n' "$*" >&2; }
die()  { log_err "$*"; exit 1; }

as_root() {
    if [[ "${EUID}" -eq 0 ]]; then "$@"; else sudo "$@"; fi
}
as_user() {
    # run command as postgres user (works when running as root or non-root)
    if [[ "${EUID}" -eq 0 ]]; then
        su - postgres -c "$*"
    else
        sudo -u postgres bash -c "$*"
    fi
}

# ── command: fix-sshd ───────────────────────────────────────────────────────
cmd_fix_sshd() {
    log "fixing sshd_config"

    as_root cp -n "${SSHD_CONFIG}" "${SSHD_CONFIG}.bak"
    as_root sed -i -E 's|^[[:space:]]*#?[[:space:]]*(PasswordAuthentication).*|\1 yes|' "${SSHD_CONFIG}"
    as_root sed -i -E 's|^[[:space:]]*#?[[:space:]]*(PubkeyAuthentication).*|\1 yes|' "${SSHD_CONFIG}"
    for f in /etc/ssh/sshd_config.d/*.conf; do
        [[ -f "$f" ]] || continue
        as_root sed -i -E 's|^[[:space:]]*#?[[:space:]]*(PasswordAuthentication).*|\1 yes|' "$f"
        as_root sed -i -E 's|^[[:space:]]*#?[[:space:]]*(PubkeyAuthentication).*|\1 yes|' "$f"
    done
    # fallback: append if directive is completely absent
    grep -qE '^[[:space:]]*PasswordAuthentication' "${SSHD_CONFIG}" || echo 'PasswordAuthentication yes' | as_root tee -a "${SSHD_CONFIG}" >/dev/null
    grep -qE '^[[:space:]]*PubkeyAuthentication' "${SSHD_CONFIG}" || echo 'PubkeyAuthentication yes' | as_root tee -a "${SSHD_CONFIG}" >/dev/null

    grep -E '^[[:space:]]*(PasswordAuthentication|PubkeyAuthentication)' "${SSHD_CONFIG}" || true

    if command -v systemctl >/dev/null; then
        as_root systemctl restart sshd || as_root systemctl restart ssh
    else
        as_root service sshd restart || as_root service ssh restart
    fi

    log_ok "done. PasswordAuthentication + PubkeyAuthentication enabled"
}

# ── command: tmux-uninstall ─────────────────────────────────────────────────
cmd_tmux_uninstall() {
    log "uninstalling tmux"

    if ! command -v tmux >/dev/null 2>&1; then
        log_ok "tmux not installed"
        return 0
    fi

    as_root apt-get remove -y tmux
    as_root apt-get autoremove -y

    log_ok "tmux removed"
}

# ── command: tmux-install ────────────────────────────────────────────────────
cmd_tmux_install() {
    log "installing tmux"

    if command -v tmux >/dev/null 2>&1; then
        log_ok "tmux already installed: $(tmux -V)"
        return 0
    fi

    as_root apt-get update -y
    as_root apt-get install -y tmux
    log_ok "tmux installed: $(tmux -V)"
}

# ── command: tmux-run (start listener session) ──────────────────────────────
cmd_tmux_run() {
    log "starting tmux session: ${TMUX_SESSION}"

    command -v tmux >/dev/null 2>&1 || die "tmux not installed (run: $0 tmux-install)"

    if tmux has-session -t "${TMUX_SESSION}" 2>/dev/null; then
        log_ok "session '${TMUX_SESSION}' already running"
        return 0
    fi

    local cmd
    if [[ -n "${TMUX_LISTENER_CMD}" ]]; then
        cmd="${TMUX_LISTENER_CMD}"
    else
        [[ -f "${PG_LOG}" ]] || die "pg log not found at ${PG_LOG} (set LXN_PG_LOG or LXN_TMUX_LISTENER_CMD)"
        cmd="tail -F ${PG_LOG}"
    fi

    tmux new-session -d -s "${TMUX_SESSION}" "${cmd}"
    log_ok "session '${TMUX_SESSION}' started"
    log "  cmd:    ${cmd}"
    log "  attach: $0 tmux-attach"
    log "  log:    $0 tmux-log"
}

# ── command: tmux-log (print recent pane output) ────────────────────────────
cmd_tmux_log() {
    tmux has-session -t "${TMUX_SESSION}" 2>/dev/null \
        || die "no session '${TMUX_SESSION}' (run: $0 tmux-run)"
    tmux capture-pane -p -t "${TMUX_SESSION}" -S -"${TMUX_LOG_LINES}"
}

# ── command: tmux-attach ────────────────────────────────────────────────────
cmd_tmux_attach() {
    tmux has-session -t "${TMUX_SESSION}" 2>/dev/null \
        || die "no session '${TMUX_SESSION}' (run: $0 tmux-run)"
    exec tmux attach -t "${TMUX_SESSION}"
}

# ── command: tmux-kill ──────────────────────────────────────────────────────
cmd_tmux_kill() {
    if tmux has-session -t "${TMUX_SESSION}" 2>/dev/null; then
        tmux kill-session -t "${TMUX_SESSION}"
        log_ok "session '${TMUX_SESSION}' killed"
    else
        log "no session '${TMUX_SESSION}'"
    fi
}

# ── locate a postgres config file via SHOW, else glob the Debian/Ubuntu path ─
detect_pg_file() {
    local kind="$1"
    local val
    val=$(as_user "psql -tAc 'SHOW ${kind}'" 2>/dev/null | tr -d '[:space:]')
    if [[ -n "${val}" && -f "${val}" ]]; then
        printf '%s\n' "${val}"
        return 0
    fi
    case "${kind}" in
        hba_file)   ls /etc/postgresql/*/main/pg_hba.conf 2>/dev/null | head -n1 ;;
        config_file) ls /etc/postgresql/*/main/postgresql.conf 2>/dev/null | head -n1 ;;
    esac
}

restart_pg() {
    if command -v systemctl >/dev/null; then
        as_root systemctl restart postgresql || as_root pg_ctlcluster "${PG_VERSION}" main restart
    else
        as_root service postgresql restart
    fi
}

# ── command: open-pg (allow remote hosts in pg_hba.conf + listen_addresses) ──
cmd_open_pg() {
    log "opening pg for net=${PG_ALLOWED_NET} auth=${PG_HBA_AUTH}"

    local hba conf
    hba="$(detect_pg_file hba_file)"
    conf="$(detect_pg_file config_file)"
    [[ -n "${hba}" && -f "${hba}" ]] || die "pg_hba.conf not found"
    [[ -n "${conf}" && -f "${conf}" ]] || die "postgresql.conf not found"

    as_root cp -n "${hba}" "${hba}.bak" 2>/dev/null || true
    as_root cp -n "${conf}" "${conf}.bak" 2>/dev/null || true

    # listen_addresses: replace existing line or append
    if grep -qE '^[[:space:]]*listen_addresses[[:space:]]*=' "${conf}"; then
        as_root sed -i -E "s|^[[:space:]]*#?[[:space:]]*listen_addresses[[:space:]]*=.*|listen_addresses = '*'|" "${conf}"
    else
        printf "listen_addresses = '*'\n" | as_root tee -a "${conf}" >/dev/null
    fi

    # idempotent pg_hba rule (marker guards against duplicates)
    if ! grep -qF "${PG_HBA_MARKER}" "${hba}"; then
        {
            printf '\n%s\n' "${PG_HBA_MARKER}"
            printf 'host  all  all  %s  %s\n' "${PG_ALLOWED_NET}" "${PG_HBA_AUTH}"
        } | as_root tee -a "${hba}" >/dev/null
    fi

    restart_pg
    log_ok "remote pg access enabled"
}

# ── command: clone (git clone / pull this repo onto lxn) ───────────────────
cmd_clone() {
    log "repo: ${LXN_REPO_URL} -> ${LXN_REPO_DIR}"

    if [[ -d "${LXN_REPO_DIR}/.git" ]]; then
        log "exists, pulling"
        git -C "${LXN_REPO_DIR}" pull --ff-only
    else
        git clone "${LXN_REPO_URL}" "${LXN_REPO_DIR}"
    fi

    log_ok "repo ready at ${LXN_REPO_DIR}"
}

# ── command: deploy (local) ─────────────────────────────────────────────────
cmd_deploy() {
    log "pg=${PG_VERSION} db=${PG_DB} user=${PG_USER}"

    # copy init.sql to staging dir (local)
    log "copying to ${REMOTE_DIR}"
    mkdir -p "${REMOTE_DIR}"
    cp "${HERE}/init.sql" "${REMOTE_DIR}/"

    # run PostgreSQL setup (local)
    log "running PostgreSQL setup"
    export PG_VERSION PG_DB PG_USER PG_PASSWORD REMOTE_DIR
    bash -s <<'REMOTE'
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
        as_root apt-get install -y curl
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
role_exists() {
    local result
    result=$(su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='${PG_USER}'\"" 2>/dev/null)
    [[ "${result}" == "1" ]]
}
database_exists() {
    local result
    result=$(su - postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='${PG_DB}'\"" 2>/dev/null)
    [[ "${result}" == "1" ]]
}
ensure_role_db() {
    log "role/db: user=${PG_USER} db=${PG_DB}"
    if ! role_exists; then
        su - postgres -c "psql -c \"CREATE ROLE \\\"${PG_USER}\\\" WITH LOGIN PASSWORD '${PG_PASSWORD}';\""
    else
        su - postgres -c "psql -c \"ALTER ROLE \\\"${PG_USER}\\\" WITH LOGIN PASSWORD '${PG_PASSWORD}';\""
    fi
    if ! database_exists; then
        su - postgres -c "createdb -O '${PG_USER}' '${PG_DB}'"
    fi
    su - postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE \\\"${PG_DB}\\\" TO \\\"${PG_USER}\\\";\""
}
load_init() {
    [[ -f "${INIT_SQL}" ]] || { log "no init.sql — skipping"; return 0; }
    log "loading ${INIT_SQL}"
    su - postgres -c "psql -d '${PG_DB}' -v ON_ERROR_STOP=1 -f '${INIT_SQL}'"
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

    cmd_open_pg

    log_ok "deploy done."
}

# ── command: prompt all (ask for PG user/pass) ──────────────────────────────
cmd_prompt_all() {
    # skip prompts if env vars already set
    [[ -n "${LXN_PG_USER:-}" && -n "${LXN_PG_PASSWORD:-}" ]] && {
        log "PG user=${LXN_PG_USER} password=*** (from env)"
        return 0
    }

    log "enter PostgreSQL credentials (or leave blank for defaults)"

    read -r -p "PostgreSQL user [${LXN_PG_USER:-lxn}]: " pg_user_input
    export LXN_PG_USER="${pg_user_input:-lxn}"

    read -r -s -p "PostgreSQL password [${LXN_PG_PASSWORD:-changeme}]: " pg_pass_input
    echo
    export LXN_PG_PASSWORD="${pg_pass_input:-changeme}"

    log "PG user=${LXN_PG_USER} password=***"
}

# ── main / dispatch ─────────────────────────────────────────────────────────
usage() {
    cat <<EOF

Usage:  ./setup_lxn.sh <command> [options]

Bootstrap / repo:
  clone          git clone (or pull) this repo onto lxn

SSH:
  fix-sshd       Enable PasswordAuthentication + PubkeyAuthentication in sshd_config

PostgreSQL:
  deploy         Install PostgreSQL, create role/db/schema, open remote access
  open-pg        Allow remote hosts in pg_hba.conf + set listen_addresses='*'

tmux:
  tmux-install   Install tmux
  tmux-run       Start listener session (tails pg log by default)
  tmux-log       Print recent pane output (show log)
  tmux-attach    Attach to the listener session
  tmux-kill      Kill the listener session
  tmux-uninstall Remove tmux

Full setup:
  all            fix-sshd + deploy + tmux-install + tmux-run

Config (env vars):
  LXN_REPO_URL, LXN_REPO_DIR              — git clone source/target
  LXN_PG_VERSION, LXN_PG_DB, LXN_PG_USER, LXN_PG_PASSWORD  — PG config
  LXN_PG_ALLOWED_NET   — CIDR allowed in pg_hba.conf (default: 0.0.0.0/0)
  LXN_PG_HBA_AUTH      — pg_hba auth method (default: scram-sha-256)
  LXN_PG_LOG           — pg log file for tmux listener (default auto)
  LXN_TMUX_SESSION     — tmux session name (default: listen_lxn)
  LXN_TMUX_LISTENER_CMD — custom command for tmux-run (default: tail pg log)
  LXN_LOG_LINES        — lines shown by tmux-log (default: 50)

Examples:
  ./setup_lxn.sh clone
  LXN_PG_PASSWORD='s3cret' ./setup_lxn.sh all
  LXN_TMUX_LISTENER_CMD='./my_listener' ./setup_lxn.sh tmux-run
EOF
}

[[ $# -eq 0 ]] && { usage; exit 1; }

case "${1}" in
    clone)          cmd_clone ;;
    fix-sshd)       cmd_fix_sshd ;;
    deploy)         cmd_deploy ;;
    open-pg)        cmd_open_pg ;;
    tmux-install)   cmd_tmux_install ;;
    tmux-run)       cmd_tmux_run ;;
    tmux-log)       cmd_tmux_log ;;
    tmux-attach)    cmd_tmux_attach ;;
    tmux-kill)      cmd_tmux_kill ;;
    tmux-uninstall) cmd_tmux_uninstall ;;
    all)            cmd_prompt_all; cmd_fix_sshd; cmd_deploy; cmd_tmux_install; cmd_tmux_run ;;
    -h|--help|help) usage ;;
    *) die "unknown command: $1 (try --help)" ;;
esac
