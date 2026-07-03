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
#   ./run_report.sh [connect_string] [begin_time] [end_time] [con_id] [out_file]
#
#   ./run_report.sh                                        # / as sysdba, last 2h, all containers
#   ./run_report.sh "/ as sysdba" 2026-05-20T10:00:00 2026-05-20T14:00:00
#   ./run_report.sh AUTO AUTO AUTO 3                       # default conn, last 2h, only CON_ID=3
#   ./run_report.sh 'rep/pw@//dbhost:1521/cdb1.world' AUTO AUTO ALL report.html
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

CONN="${1:-AUTO}"
BEGIN_TIME="${2:-AUTO}"
END_TIME="${3:-AUTO}"
CON_ID="${4:-ALL}"
OUT_FILE="${5:-AUTO}"

# Catch the pre-connect-string calling convention (times used to come first).
case "$CONN" in
  [0-9][0-9][0-9][0-9]-*)
    echo "ERROR: the first argument is the connect string, not the begin time." >&2
    echo "       ./run_report.sh \"/ as sysdba\" $*" >&2
    exit 2
    ;;
esac

if [ "$CONN" = AUTO ] || [ -z "$CONN" ]; then
  CONN="/ as sysdba"
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"

if ! command -v sqlplus >/dev/null 2>&1; then
  echo "ERROR: sqlplus not found on PATH. Set your Oracle environment first" >&2
  echo "       (e.g. '. oraenv'), then re-run." >&2
  exit 1
fi

if [ "$OUT_FILE" = AUTO ] || [ -z "$OUT_FILE" ]; then
  OUT_FILE="ash_blocking_$(date '+%Y%m%d_%H%M%S').html"
fi

# Mask the password when echoing a user/pw@service connect string.
CONN_DISPLAY="$CONN"
case "$CONN" in
  */*@*) CONN_DISPLAY="${CONN%%/*}/***@${CONN#*@}" ;;
esac

mkdir -p "$SCRIPT_DIR/reports"
TMPD="$SCRIPT_DIR/reports/.build.$$"
mkdir "$TMPD"
trap 'rm -rf "$TMPD"' EXIT INT TERM

echo "==> Querying ASH (read-only)"
echo "    conn=$CONN_DISPLAY  begin=$BEGIN_TIME  end=$END_TIME  con_id=$CON_ID  out=$OUT_FILE"

# $CONN is expanded unquoted on purpose: '/ as sysdba' must reach sqlplus as
# three words. A user/pw@service string has no spaces, so it stays one word.
RC=0
sqlplus -S -L $CONN @build_report.sql \
  "$BEGIN_TIME" "$END_TIME" "$CON_ID" > "$TMPD/out.log" 2>&1 || RC=$?
if [ "$RC" -ne 0 ]; then
  echo "ERROR: sqlplus failed (exit $RC). Output follows:" >&2
  cat "$TMPD/out.log" >&2
  exit "$RC"
fi

# Split the captured output: JSON chunk lines into meta/data files (kept as
# <=500-char lines so no tool ever sees an over-long record — matters on AIX),
# everything else is progress info for the user. Chunk lines arrive wrapped in
# '#' sentinels (#chunk#) protecting whitespace from SQL*Plus line trimming;
# strip them here. Boundaries can fall mid-token; the splice below joins the
# chunks WITHOUT newlines.
awk -v mf="$TMPD/meta.json" -v df="$TMPD/data.json" '
  /^__META_JSON_BEGIN__$/ { s=1; next }
  /^__META_JSON_END__$/   { s=0; next }
  /^__DATA_JSON_BEGIN__$/ { s=2; next }
  /^__DATA_JSON_END__$/   { s=0; next }
  s==1 { print substr($0, 2, length($0) - 2) > mf; next }
  s==2 { print substr($0, 2, length($0) - 2) > df; next }
  { print "    " $0 }
' "$TMPD/out.log"

if [ ! -s "$TMPD/meta.json" ] || [ ! -s "$TMPD/data.json" ]; then
  echo "ERROR: did not find the JSON payload in the sqlplus output." >&2
  echo "       Full output follows:" >&2
  cat "$TMPD/out.log" >&2
  exit 1
fi

# The placeholders must sit ALONE on their own lines in the template, exactly
# once each (checked on the template, whose lines are short — never on the
# rendered file, whose JSON line is huge and can upset line-based AIX tools).
PLACEHOLDERS=$(awk '$0=="__META_JSON__" || $0=="__DATA_JSON__"' assets/template.html | sort -u | wc -l)
if [ "$PLACEHOLDERS" -ne 2 ]; then
  echo "ERROR: assets/template.html must contain __META_JSON__ and __DATA_JSON__" >&2
  echo "       each alone on its own line (found $PLACEHOLDERS of 2)." >&2
  exit 1
fi

# Splice the JSON into the template: each placeholder line is replaced by its
# JSON chunks joined WITHOUT newlines (one long line — fine for browsers).
awk -v mf="$TMPD/meta.json" -v df="$TMPD/data.json" '
  function insert(f,  line) {
    while ((getline line < f) > 0) printf "%s", line
    close(f)
    printf "\n"
  }
  $0 == "__META_JSON__" { insert(mf); next }
  $0 == "__DATA_JSON__" { insert(df); next }
  { print }
' assets/template.html > "$TMPD/report.html"

mv "$TMPD/report.html" "$SCRIPT_DIR/reports/$OUT_FILE"

echo
echo "==> Report: $SCRIPT_DIR/reports/$OUT_FILE"
echo "    open $SCRIPT_DIR/reports/$OUT_FILE"
