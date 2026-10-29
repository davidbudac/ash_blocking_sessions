#!/bin/sh
# Build the ASH Blocking Sessions HTML report locally with SQL*Plus.
#
# Fully READ-ONLY against the database: the PL/SQL only SELECTs and prints the
# report JSON to stdout (no DDL, no DML, no directory objects, no server-side
# file access). This script captures that output, splices the JSON into
# assets/template.html, and writes the finished HTML into reports/ — all on
# THIS machine. That also means it works unchanged against a remote database:
# the report always lands here, next to the script.
#
# Usage:
#   ./run_report.sh [connect_string] [begin_time] [end_time] [out_file]
#
#   ./run_report.sh                                        # / as sysdba, last 2h, all containers
#   ./run_report.sh "/ as sysdba" 2026-05-20T10:00:00 2026-05-20T14:00:00
#   ./run_report.sh 'rep/pw@//dbhost:1521/cdb1.world' AUTO AUTO report.html
#
# The report always covers every container in the connected CDB (AWR/ASH lives
# in CDB$ROOT; connect there). To target a different database, point the
# connect string at it — there is no per-container argument.
#
# The first argument is the sqlplus connect string ('AUTO' = '/ as sysdba', i.e.
# OS auth to CDB$ROOT). A named user needs CREATE SESSION and
# SELECT_CATALOG_ROLE on a common account connected to CDB$ROOT — nothing else.
# Quote the whole string so it stays one argument.
#
# Time arguments are ISO 'YYYY-MM-DDTHH24:MI:SS' (uppercase T, no spaces).
#
# Plain POSIX sh: runs under AIX /bin/sh (ksh), ksh93, and bash alike.

set -eu
[ "$#" -le 4 ] || { echo "ERROR: expected at most four arguments" >&2; exit 2; }
CONN=${1:-AUTO}
BEGIN_TIME=${2:-AUTO}
END_TIME=${3:-AUTO}
OUT_FILE=${4:-AUTO}
[ "$CONN" != AUTO ] || CONN='/ as sysdba'
SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
# Strict calendar validation before any SQL*Plus substitution. No quotes,
# ampersands, whitespace or SQL fragments can pass this grammar.
ASH_BEGIN_TIME="$BEGIN_TIME" ASH_END_TIME="$END_TIME" awk -f scripts/validate-times.awk
case "$OUT_FILE" in
 AUTO) OUT_FILE="ash_blocking_$(date '+%Y%m%d_%H%M%S')_$$.html" ;;
 ''|.*|*[!A-Za-z0-9_.-]*|ash_blocking_demo.html) echo 'ERROR: unsafe or reserved output basename' >&2; exit 2 ;;
esac
case "$OUT_FILE" in *.html) ;; *) echo 'ERROR: output must end in .html' >&2; exit 2 ;; esac
[ ! -L reports ] || { echo 'ERROR: reports must not be a symlink' >&2; exit 2; }
mkdir -p reports
[ ! -e "reports/$OUT_FILE" ] && [ ! -L "reports/$OUT_FILE" ] || { echo 'ERROR: output already exists' >&2; exit 2; }
command -v sqlplus >/dev/null 2>&1 || { echo 'ERROR: sqlplus not found on PATH' >&2; exit 1; }
umask 077
TMPD="reports/.build.$$"
mkdir "$TMPD"
trap 'rm -rf "$TMPD"' 0
trap 'exit 130' INT
trap 'exit 143' TERM
echo '==> Querying ASH (read-only)'
# Disable pathname expansion while splitting the traditional / as sysdba form.
set -f
RC=0
sqlplus -S -L $CONN @build_report.sql "$BEGIN_TIME" "$END_TIME" > "$TMPD/out.log" 2>&1 || RC=$?
if [ "$RC" -ne 0 ]; then
 echo "ERROR: sqlplus failed (exit $RC)" >&2
 cat "$TMPD/out.log" >&2
 exit "$RC"
fi
LC_ALL=C awk -v mf="$TMPD/meta.json" -v df="$TMPD/data.json" -f scripts/split-protocol.awk "$TMPD/out.log"
scripts/assemble-report.sh assets/template.html "$TMPD/meta.json" "$TMPD/data.json" "$TMPD/report.html"
# Open the exact destination exclusively. Unlike ln, redirection never treats
# a destination directory as a container for a new report.html child.
(set -C; cat "$TMPD/report.html" > "reports/$OUT_FILE") || { echo 'ERROR: output creation failed (possibly already exists)' >&2; exit 1; }
echo "==> Report: $SCRIPT_DIR/reports/$OUT_FILE"
