#!/usr/bin/env bash
# Build the ASH Blocking Sessions HTML report on dbmint and pull it back.
#
# Usage:
#   ./run_report.sh                                        # last 2h, all containers, auto file name
#   ./run_report.sh 2026-05-20T10:00:00 2026-05-20T14:00:00
#   ./run_report.sh AUTO AUTO 3                            # last 2h, only CON_ID=3 (PDB1)
#   ./run_report.sh AUTO AUTO ALL report.html
#
# All time arguments are in ISO format with a 'T' separator (no spaces).

set -euo pipefail

PROJECT_NAME="ash_blocking_sessions"
HOST="dbmint"
SSH_PORT=2201
REMOTE_USER="oracle"
REMOTE_DIR="~/${PROJECT_NAME}"
ENV_PREAMBLE='export ORACLE_SID=cdb1; export ORAENV_ASK=NO; . oraenv >/dev/null 2>&1;'

BEGIN_TIME="${1:-AUTO}"
END_TIME="${2:-AUTO}"
CON_ID="${3:-ALL}"
OUT_FILE="${4:-AUTO}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

echo "==> Syncing project to ${HOST}:${REMOTE_DIR}"
rsync -az --delete \
  --exclude='.git/' --exclude='reports/' --exclude='.DS_Store' \
  ./ "${REMOTE_USER}@${HOST}:${REMOTE_DIR}/" \
  -e "ssh -p ${SSH_PORT}"

echo "==> Ensuring reports/ exists on ${HOST}"
ssh -p "${SSH_PORT}" "${REMOTE_USER}@${HOST}" "mkdir -p ${REMOTE_DIR}/reports"

echo "==> Building report on ${HOST}"
echo "    begin=${BEGIN_TIME}  end=${END_TIME}  con_id=${CON_ID}  out=${OUT_FILE}"
ssh -p "${SSH_PORT}" "${REMOTE_USER}@${HOST}" \
  "${ENV_PREAMBLE} cd ${REMOTE_DIR} && sqlplus -S -L / as sysdba @build_report.sql '${BEGIN_TIME}' '${END_TIME}' '${CON_ID}' '${OUT_FILE}'"

echo "==> Pulling reports/ back"
mkdir -p "${SCRIPT_DIR}/reports"
rsync -az -e "ssh -p ${SSH_PORT}" "${REMOTE_USER}@${HOST}:${REMOTE_DIR}/reports/" "${SCRIPT_DIR}/reports/"

LATEST="$(ls -1t "${SCRIPT_DIR}/reports/"*.html 2>/dev/null | head -n1 || true)"
if [[ -n "${LATEST}" ]]; then
  echo
  echo "==> Latest report: ${LATEST}"
  echo "    open ${LATEST}"
else
  echo
  echo "==> No HTML produced. Check the sqlplus output above for errors."
fi
