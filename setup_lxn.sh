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

Commands:
  fix-sshd        Enable PasswordAuthentication + PubkeyAuthentication in sshd_config
  tmux-uninstall  Remove tmux from the system
  deploy          Install PostgreSQL, create role/db/schema
  all             fix-sshd + tmux-uninstall + deploy (full repair)

Config (env vars):
  LXN_PG_VERSION, LXN_PG_DB, LXN_PG_USER, LXN_PG_PASSWORD — PG config
  LXN_REMOTE_DIR              — staging dir (default: /tmp/pg_setup)

Example:
  LXN_PG_PASSWORD='s3cret' ./setup_lxn.sh deploy
EOF
}

[[ $# -eq 0 ]] && { usage; exit 1; }

case "${1}" in
    fix-sshd)       cmd_fix_sshd ;;
    tmux-uninstall) cmd_tmux_uninstall ;;
    deploy)         cmd_deploy ;;
    all)            cmd_prompt_all; cmd_fix_sshd; cmd_tmux_uninstall; cmd_deploy ;;
    -h|--help|help) usage ;;
    *) die "unknown command: $1 (try --help)" ;;
esac
