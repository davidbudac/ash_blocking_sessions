#!/usr/bin/env bash
# Seed realistic blocking scenarios on dbmint, wait for ASH to record them,
# then force an AWR snapshot so the samples land in DBA_HIST_ACTIVE_SESS_HISTORY.
#
# Usage:
#   ./run_seed.sh             # ~4 minute wait between seed and snap (default)
#   ./run_seed.sh 60          # 60 seconds (quick smoke test - less data)
#
# The created jobs (ASH_TEST.ASH_DEMO_*) auto-drop when they finish their
# DBMS_LOCK.SLEEP, so no manual cleanup is needed afterwards.

set -euo pipefail

PROJECT_NAME="ash_blocking_sessions"
HOST="dbmint"
SSH_PORT=2201
REMOTE_USER="oracle"
REMOTE_DIR="~/${PROJECT_NAME}"
ENV_PREAMBLE='export ORACLE_SID=cdb1; export ORAENV_ASK=NO; . oraenv >/dev/null 2>&1;'

WAIT_SECS="${1:-240}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

echo "==> Syncing project to ${HOST}:${REMOTE_DIR}"
rsync -az --delete \
  --exclude='.git/' --exclude='reports/' --exclude='.DS_Store' \
  ./ "${REMOTE_USER}@${HOST}:${REMOTE_DIR}/" \
  -e "ssh -p ${SSH_PORT}"

SEED_START_LOCAL="$(date -u '+%Y-%m-%dT%H:%M:%S')"
echo "==> Seeding blocking jobs on ${HOST} (local time ${SEED_START_LOCAL})"
ssh -p "${SSH_PORT}" "${REMOTE_USER}@${HOST}" \
  "${ENV_PREAMBLE} cd ${REMOTE_DIR} && sqlplus -S -L / as sysdba @sql/seed_blocking.sql"

echo "==> Jobs submitted. Sleeping ${WAIT_SECS}s so ASH can sample them..."
sleep "${WAIT_SECS}"

echo "==> Taking AWR snapshot on ${HOST}"
ssh -p "${SSH_PORT}" "${REMOTE_USER}@${HOST}" \
  "${ENV_PREAMBLE} cd ${REMOTE_DIR} && sqlplus -S -L / as sysdba @sql/take_snap.sql"

SEED_END_LOCAL="$(date -u '+%Y-%m-%dT%H:%M:%S')"
echo
echo "==> Done. Suggested report window (UTC, give or take a few seconds):"
echo "    ./run_report.sh AUTO ${SEED_START_LOCAL} ${SEED_END_LOCAL} 3"
echo "    (AUTO = connect '/ as sysdba'; CON_ID 3 = PDB1, where the seed jobs ran)"
