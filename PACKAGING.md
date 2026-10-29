# Offline report packaging

`run_report.sh` uses POSIX sh and awk only, in addition to SQL*Plus and standard
Unix utilities. Python and Node are not production dependencies. The report
contains ECharts 5.5.0 inline; opening it needs no CDN or other runtime download.
The template's existing exact pinned CDN tag is replaced during assembly; no
template edit is required. Keep that tag once, and keep each JSON placeholder
once on its own line. Any additional occurrence of either placeholder fails.

The official npm distribution, license, notice, bundled d3 license and hashes
are recorded in `assets/vendor/PROVENANCE.md`. The original minified file is
unchanged. Its companion `.chunks` is a reversible short-record representation:
`C` introduces up to 500 original bytes and `N` restores one original newline.
This avoids feeding a megabyte JavaScript record to AIX awk.

SQL*Plus must emit one META section followed by one DATA section, with the
existing exact begin/end markers and nonempty `#payload#` records of at most
500 UTF-8 characters (2,000 bytes). Nested, repeated, missing or misordered
markers, missing sentinels, controls and out-of-section chunks are rejected.
Chunk whitespace and UTF-8 bytes survive concatenation exactly. Every `<` in
JSON is replaced with JSON's equivalent `\u003c` escape, independently per chunk;
this prevents HTML script termination and comment tokenizer states even across
chunk boundaries. This is transport framing validation, not a general JSON
parser: the SQL emitter remains responsible for producing valid JSON.

Explicit timestamps are checked for ISO syntax, calendar validity (including
leap years) and increasing order before SQL*Plus runs. AUTO remains supported.
Output names must be simple `.html` basenames, cannot select the curated demo,
and cannot overwrite any existing file or symlink. Publication uses an exclusive
shell noclobber redirection to the exact basename, rejecting directories too.
The final copy is not atomic: an interrupted copy may leave a partial output,
which must be removed or given a new name before retrying.
AUTO names include timestamp and process ID (database name is no longer used).
A symlinked `reports/` directory is refused. Temporary output is private and
removed on exit. Database queries and SQL files are unchanged by packaging.

## Regenerate curated demos (developer operation)

Run from the repository root, after template work is ready:

```sh
./scripts/regenerate-demos.sh
```

This deliberately replaces BOTH `reports/ash_blocking_demo.html` and
`docs/demo.html` with byte-identical snapshots assembled from the current
template. It does not query a database. `scripts/demo-fixture/meta.chunks` and
`data.chunks` preserve the existing curated synthetic dataset (1,028 rows),
including all root-cause fields. They are newline-separated pieces of JSON;
join without newlines to parse or edit them, then split the resulting compact
JSON into pieces of at most 500 characters. Do not use pretty-printed JSON.
These fixture files are the maintained demo data source, not generated HTML.
The generator uses exactly the same assembly path as production.

## Local tests

```sh
python3 -m unittest discover -s tests/packaging -v
sh -n run_report.sh scripts/assemble-report.sh scripts/regenerate-demos.sh
```

Tests copy scripts into an isolated temporary directory and provide fake
SQL*Plus. They cover Unicode and preserved whitespace, split mixed-case script
terminators, reversible vendor assembly, malformed framing, SQL*Plus failures,
placeholder errors, timestamp validation, output traversal/overwrite/symlink
rejection, fixture parsing and deterministic regeneration. No database or seed
is used. AIX execution and a live SQL emitter round trip still require the
appropriate host; local tests do not establish either.
