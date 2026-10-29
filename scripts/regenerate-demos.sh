#!/bin/sh
# Developer-only: deliberately refresh BOTH curated snapshots from one fixture.
set -eu
ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/ash-demos.XXXXXX")
trap 'rm -rf "$TMPD"' 0
trap 'exit 130' INT
trap 'exit 143' TERM
scripts/assemble-report.sh assets/template.html scripts/demo-fixture/meta.chunks scripts/demo-fixture/data.chunks "$TMPD/demo.html"
cp "$TMPD/demo.html" reports/ash_blocking_demo.html
cp "$TMPD/demo.html" docs/demo.html
printf '%s\n' 'Regenerated reports/ash_blocking_demo.html and docs/demo.html'
