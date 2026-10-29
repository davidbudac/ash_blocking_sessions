#!/bin/sh
# Input JSON is short, newline-free chunks, not ordinary pretty-printed JSON.
set -eu
[ "$#" -eq 4 ] || { echo 'Usage: assemble-report.sh template meta.chunks data.chunks output' >&2; exit 2; }
ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
VENDOR="$ROOT/assets/vendor/echarts-5.5.0.min.js.chunks"
# Validate ALL occurrences, including inline/duplicated placeholders, before output.
LC_ALL=C awk '
function count(s,t, n,p) { n=0; while((p=index(s,t))>0) { n++; s=substr(s,p+length(t)) } return n }
{ m+=count($0,"__META_JSON__"); d+=count($0,"__DATA_JSON__")
 if($0=="__META_JSON__") ml++; if($0=="__DATA_JSON__") dl++
 v+=count($0,"<script src=\"https://cdn.jsdelivr.net/npm/echarts@5.5.0/dist/echarts.min.js\"></script>")
}
END { if(m!=1 || d!=1 || ml!=1 || dl!=1 || v!=1) {print "ERROR: template requires exactly one standalone placeholder each and one pinned ECharts tag" > "/dev/stderr"; exit 1} }
' "$1"
# Every less-than is escaped independently; no cross-chunk lookbehind needed.
# This also prevents HTML comment/script tokenizer states, preserving JSON values.
LC_ALL=C awk -v mf="$2" -v df="$3" -v vf="$VENDOR" '
function insert(f, safe, line,r) {
 while((r=(getline line < f))>0) {
   if(safe) { gsub(/</,"\\u003c",line); printf "%s",line }
   else if(line=="N") printf "\n"
   else printf "%s",substr(line,2)
 }
 close(f); if(r<0) {print "ERROR: cannot read assembly input" > "/dev/stderr"; exit 1}
 print ""
}
$0=="__META_JSON__" {insert(mf,1); next}
$0=="__DATA_JSON__" {insert(df,1); next}
index($0,"<script src=\"https://cdn.jsdelivr.net/npm/echarts@5.5.0/dist/echarts.min.js\"></script>") {
 print "<script>"; insert(vf,0); print "</script>"; next
}
{print}
' "$1" > "$4"
