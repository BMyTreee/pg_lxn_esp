#!/usr/bin/env bash
#
# Runs ON the `lxn` host: apt-installs PostgreSQL, creates role/db, loads init.sql.
# Idempotent — safe to re-run.
#
set -euo pipefail

# ── constants (injected by deploy.sh, with sane fallbacks) ───────────────────
: "${PG_VERSION:=16}"
: "${PG_DB:=lxn}"
: "${PG_USER:=lxn}"
: "${PG_PASSWORD:=changeme}"

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly INIT_SQL="${SCRIPT_DIR}/init.sql"

# ── helpers ──────────────────────────────────────────────────────────────────
log() { printf '\033[1;32m[setup]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[setup:err]\033[0m %s\n' "$*" >&2; exit 1; }

as_root() { if [[ "${EUID}" -ne 0 ]]; then sudo "$@"; else "$@"; fi; }

# ── install via apt ──────────────────────────────────────────────────────────
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

# ── start cluster ────────────────────────────────────────────────────────────
ensure_cluster() {
    log "starting cluster v${PG_VERSION}/main"
    as_root pg_ctlcluster "${PG_VERSION}" main start 2>/dev/null \
        || as_root systemctl enable --now postgresql
}

# ── role / db ────────────────────────────────────────────────────────────────
role_exists()     { as_root -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${PG_USER}'" | grep -q 1; }
database_exists() { as_root -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${PG_DB}'" | grep -q 1; }

ensure_role_db() {
    log "role/db: user=${PG_USER} db=${PG_DB}"
    if ! role_exists; then
        as_root -u postgres psql -c "CREATE ROLE \"${PG_USER}\" WITH LOGIN PASSWORD '${PG_PASSWORD}';"
    else
        as_root -u postgres psql -c "ALTER ROLE \"${PG_USER}\" WITH LOGIN PASSWORD '${PG_PASSWORD}';"
    fi
    if ! database_exists; then
        as_root -u postgres createdb -O "${PG_USER}" "${PG_DB}"
    fi
    as_root -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE \"${PG_DB}\" TO \"${PG_USER}\";"
}

# ── init schema ──────────────────────────────────────────────────────────────
load_init() {
    [[ -f "${INIT_SQL}" ]] || { log "no init.sql — skipping"; return 0; }
    log "loading ${INIT_SQL}"
    as_root -u postgres psql -d "${PG_DB}" -v ON_ERROR_STOP=1 -f "${INIT_SQL}"
}

# ── main ─────────────────────────────────────────────────────────────────────
main() {
    install_pg
    ensure_cluster
    ensure_role_db
    load_init
    log "postgresql ready: ${PG_USER}@/${PG_DB} on $(hostname)"
}

main "$@"
