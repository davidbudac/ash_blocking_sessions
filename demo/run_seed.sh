#!/bin/sh
# DEMO/TEST ONLY — never run against a production database.
#
# Seed realistic blocking scenarios, wait for ASH to record them, then force an
# AWR snapshot so the samples land in DBA_HIST_ACTIVE_SESS_HISTORY.
#
# This script is intentionally invasive (that's its job on a TEST database):
#   * DROPs and recreates the ASH_TEST schema, killing its leftover sessions
#   * submits DBMS_SCHEDULER jobs that hold row/table/user locks for ~4 minutes
#   * forces an AWR snapshot (DBMS_WORKLOAD_REPOSITORY.CREATE_SNAPSHOT)
# It therefore asks for confirmation before touching the database.
#
# Runs entirely on the current host with SQL*Plus: no ssh, no rsync.
#
# Usage:
#   ./run_seed.sh [connect_string] [wait_secs]
#
#   ./run_seed.sh                    # / as sysdba, ~4 minute wait (default)
#   ./run_seed.sh "/ as sysdba" 60   # 60 seconds (quick smoke test - less data)
#
# Set ASH_SEED_FORCE=1 to skip the confirmation prompt (for scripted test runs).
#
# The first argument is the sqlplus connect string ('AUTO' = '/ as sysdba').
# seed_blocking.sql does its schema setup as SYSDBA in CDB$ROOT, then reconnects
# to the PDB as ASH_TEST itself, so the default OS-auth connection is expected.
#
# The created jobs (ASH_TEST.ASH_DEMO_*) auto-drop when they finish their
# DBMS_LOCK.SLEEP, so no manual cleanup is needed afterwards.
#
# Plain POSIX sh: runs under AIX /bin/sh (ksh), ksh93, and bash alike.

set -eu

CONN="${1:-AUTO}"
WAIT_SECS="${2:-240}"

if [ "$CONN" = AUTO ] || [ -z "$CONN" ]; then
  CONN="/ as sysdba"
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$SCRIPT_DIR"

if ! command -v sqlplus >/dev/null 2>&1; then
  echo "ERROR: sqlplus not found on PATH. Set your Oracle environment first" >&2
  echo "       (e.g. '. oraenv'), then re-run." >&2
  exit 1
fi

# Mask the password when echoing a user/pw@service connect string.
CONN_DISPLAY="$CONN"
case "$CONN" in
  */*@*) CONN_DISPLAY="${CONN%%/*}/***@${CONN#*@}" ;;
esac

if [ "${ASH_SEED_FORCE:-0}" != 1 ]; then
  echo "*** DEMO SEED — TEST DATABASES ONLY ***"
  echo "This will connect as: $CONN_DISPLAY"
  echo "and will: DROP/CREATE the ASH_TEST schema (killing its sessions),"
  echo "hold locks for ~4 minutes, and force an AWR snapshot."
  printf "Type 'seed' to continue: "
  read ANSWER
  if [ "$ANSWER" != seed ]; then
    echo "Aborted (nothing was run)."
    exit 1
  fi
fi

SEED_START_LOCAL=$(date -u '+%Y-%m-%dT%H:%M:%S')
echo "==> Seeding blocking jobs (UTC $SEED_START_LOCAL)"
# $CONN unquoted so '/ as sysdba' reaches sqlplus as three words.
sqlplus -S -L $CONN @seed_blocking.sql

echo "==> Jobs submitted. Sleeping ${WAIT_SECS}s so ASH can sample them..."
sleep "$WAIT_SECS"

echo "==> Taking AWR snapshot"
sqlplus -S -L $CONN @take_snap.sql

SEED_END_LOCAL=$(date -u '+%Y-%m-%dT%H:%M:%S')
echo
echo "==> Done. Suggested report window (UTC, give or take a few seconds):"
echo "    $ROOT_DIR/run_report.sh AUTO $SEED_START_LOCAL $SEED_END_LOCAL 3"
echo "    (AUTO = connect '/ as sysdba'; CON_ID 3 = PDB1, where the seed jobs ran)"
