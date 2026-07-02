#!/usr/bin/env bash
# Build the ASH Blocking Sessions HTML report on dbmint and pull it back.
#
# Usage:
#   ./run_report.sh [connect_string] [begin_time] [end_time] [con_id] [out_file]
#
#   ./run_report.sh                                        # / as sysdba, last 2h, all containers
#   ./run_report.sh "/ as sysdba" 2026-05-20T10:00:00 2026-05-20T14:00:00
#   ./run_report.sh AUTO AUTO AUTO 3                       # default conn, last 2h, only CON_ID=3
#   ./run_report.sh 'c##ashreport/pw@//localhost/cdb1.world' AUTO AUTO ALL report.html
#
# The first argument is the sqlplus connect string, run on the DB host after
# SSHing in as ${REMOTE_USER} ('AUTO' = '/ as sysdba', i.e. OS auth to
# CDB$ROOT). A named user must be a COMMON user connected to CDB$ROOT with
# SELECT_CATALOG_ROLE and access to the ASH_ASSETS/ASH_REPORTS directories
# (see sql/01_dirs.sql). Quote the whole string so it stays one argument.
#
# All time arguments are in ISO format with a 'T' separator (no spaces).

set -euo pipefail

PROJECT_NAME="ash_blocking_sessions"
HOST="dbmint"
SSH_PORT=2201
REMOTE_USER="oracle"
REMOTE_DIR="~/${PROJECT_NAME}"
ENV_PREAMBLE='export ORACLE_SID=cdb1; export ORAENV_ASK=NO; . oraenv >/dev/null 2>&1;'

CONN="${1:-AUTO}"
BEGIN_TIME="${2:-AUTO}"
END_TIME="${3:-AUTO}"
CON_ID="${4:-ALL}"
OUT_FILE="${5:-AUTO}"

# Catch the pre-connect-string calling convention (times used to come first).
if [[ "${CONN}" =~ ^[0-9]{4}- ]]; then
  echo "ERROR: the first argument is now the connect string, not the begin time." >&2
  echo "       ./run_report.sh \"/ as sysdba\" ${*}" >&2
  exit 2
fi
if [[ "${CONN}" == "AUTO" || -z "${CONN}" ]]; then
  CONN="/ as sysdba"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

echo "==> Syncing project to ${HOST}:${REMOTE_DIR}"
rsync -az --delete \
  --exclude='.git/' --exclude='reports/' --exclude='.DS_Store' \
  ./ "${REMOTE_USER}@${HOST}:${REMOTE_DIR}/" \
  -e "ssh -p ${SSH_PORT}"

echo "==> Ensuring reports/ exists on ${HOST}"
ssh -p "${SSH_PORT}" "${REMOTE_USER}@${HOST}" "mkdir -p ${REMOTE_DIR}/reports"

# Mask the password when echoing a user/pw@service string.
CONN_DISPLAY="${CONN}"
if [[ "${CONN}" == *"/"*"@"* ]]; then
  CONN_DISPLAY="${CONN%%/*}/***@${CONN#*@}"
fi

echo "==> Building report on ${HOST}"
echo "    conn=${CONN_DISPLAY}  begin=${BEGIN_TIME}  end=${END_TIME}  con_id=${CON_ID}  out=${OUT_FILE}"
# ${CONN} is expanded unquoted on purpose: '/ as sysdba' must reach sqlplus as
# three words. A user/pw@service string has no spaces, so it stays one word.
ssh -p "${SSH_PORT}" "${REMOTE_USER}@${HOST}" \
  "${ENV_PREAMBLE} cd ${REMOTE_DIR} && sqlplus -S -L ${CONN} @build_report.sql '${BEGIN_TIME}' '${END_TIME}' '${CON_ID}' '${OUT_FILE}'"

echo "==> Pulling reports/ back"
mkdir -p "${SCRIPT_DIR}/reports"
# Only pull generated reports. ash_blocking_demo.html is a hand-maintained,
# source-controlled offline copy (rich sample data inlined) — a stale copy
# lingering on the host must NOT overwrite it.
rsync -az -e "ssh -p ${SSH_PORT}" \
  --exclude='ash_blocking_demo.html' \
  "${REMOTE_USER}@${HOST}:${REMOTE_DIR}/reports/" "${SCRIPT_DIR}/reports/"

LATEST="$(ls -1t "${SCRIPT_DIR}/reports/"*.html 2>/dev/null | head -n1 || true)"
if [[ -n "${LATEST}" ]]; then
  echo
  echo "==> Latest report: ${LATEST}"
  echo "    open ${LATEST}"
else
  echo
  echo "==> No HTML produced. Check the sqlplus output above for errors."
fi
