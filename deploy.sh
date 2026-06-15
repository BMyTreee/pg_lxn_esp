#!/usr/bin/env bash
#
# Deploy PostgreSQL setup to the `lxn` host.
# SCPs the remote installer + init SQL, then runs them over SSH.
#
set -euo pipefail

# ── constants ────────────────────────────────────────────────────────────────
readonly SSH_HOST="${LXN_HOST:-lxn}"
readonly SSH_USER="${LXN_USER:-pi}"
readonly REMOTE_DIR="${LXN_REMOTE_DIR:-/tmp/pg_setup}"
readonly PG_VERSION="${LXN_PG_VERSION:-16}"
readonly PG_DB="${LXN_PG_DB:-lxn}"
readonly PG_USER="${LXN_PG_USER:-lxn}"
readonly PG_PASSWORD="${LXN_PG_PASSWORD:-changeme}"

readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REMOTE_SCRIPT="setup_pg.sh"
readonly INIT_SQL="init.sql"

# ── helpers ──────────────────────────────────────────────────────────────────
log()  { printf '\033[1;34m[deploy]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[deploy:err]\033[0m %s\n' "$*" >&2; exit 1; }

remote_target() { printf '%s@%s' "${SSH_USER}" "${SSH_HOST}"; }

# ── preflight ────────────────────────────────────────────────────────────────
preflight() {
    command -v scp >/dev/null || die "scp not found"
    command -v ssh >/dev/null || die "ssh not found"
    [[ -f "${HERE}/${REMOTE_SCRIPT}" ]] || die "missing ${REMOTE_SCRIPT}"
    [[ -f "${HERE}/${INIT_SQL}"     ]] || die "missing ${INIT_SQL}"
    log "host=${SSH_HOST} user=${SSH_USER} pg=${PG_VERSION} db=${PG_DB}"
}

# ── steps ────────────────────────────────────────────────────────────────────
copy_files() {
    log "copying files to ${REMOTE_DIR}"
    ssh "$(remote_target)" "mkdir -p '${REMOTE_DIR}'"
    scp "${HERE}/${REMOTE_SCRIPT}" \
        "${HERE}/${INIT_SQL}" \
        "$(remote_target):${REMOTE_DIR}/"
}

run_remote() {
    log "running setup on ${SSH_HOST}"
    ssh "$(remote_target)" \
        "PG_VERSION='${PG_VERSION}' \
         PG_DB='${PG_DB}' \
         PG_USER='${PG_USER}' \
         PG_PASSWORD='${PG_PASSWORD}' \
         bash '${REMOTE_DIR}/${REMOTE_SCRIPT}'"
}

# ── main ─────────────────────────────────────────────────────────────────────
main() {
    preflight
    copy_files
    run_remote
    log "done."
}

main "$@"
