# ASH Blocking Sessions Timeline

Turn Oracle `DBA_HIST_ACTIVE_SESS_HISTORY` blocking samples into a single,
self-contained, interactive HTML report — a per-session timeline of every
session that was blocking or blocked in a time window, with a click-through
blocking tree for any 10-second ASH sample.

No application server, no agents, and **no database objects at all**:
SQL\*Plus runs one read-only PL/SQL block that prints the data as JSON, and
the shell script splices it into an HTML template on the client side. Open
the result in any browser.

Everything runs locally where the repo lives — a plain `sqlplus` call, no ssh
and no rsync. The shell scripts are POSIX `sh`, so they run unchanged under the
AIX `/bin/sh` (ksh), ksh93, or bash.

**Website & live demo:** <https://davidbudac.github.io/ash_blocking_sessions/> —
a project overview plus the full interactive report running on sample data, right
in the browser (no database, no install).

## What the report shows

- **Key findings** — estimated blocked session-time, the biggest observed root
  blocker, sampled blocker activity (ON CPU, waiting, or unknown), peak
  concurrency, and the last observed blocking sample. Missing ASH evidence
  does not prove idleness or establish when contention resolved.
- **Investigation scope** — exact, combined filters for container ID, service,
  module, object and SQL ID. Summaries, timelines and details recalculate for
  matching waiter samples, retaining their referenced blocker context.
- **Contention episodes** — observed bursts separated by gaps longer than two
  bounded sample intervals, with recurrence counts, weighted blocked time,
  peak waiters and observed blocker changes. Select an episode to restrict the
  investigation; gaps do not prove resolution.
- **Incident brief** — download Markdown containing the current scope,
  selected sample/chain evidence and investigation SQL. Optional redaction
  exports aggregate counts and estimates only, omitting identifiers, timestamps
  and SQL. A selectable text fallback works when downloads are unavailable.
- **Session timeline** — one lane per session that ever blocked or waited,
  grouped by wait chain. Filled cells = waiting (colored by wait event/class),
  outlined cells = holding a lock, both = mid-chain. One cell = one ASH sample.
- **Blocking tree** — click any sample (or any session's cell) to see the exact
  chain shape at that instant: root blockers, fan-in, chain depth, per-edge wait
  events. Step sample-by-sample to watch chains form and collapse.
- **Sample detail** — per session: `SID,SERIAL#`, user, module/action, program,
  machine, service, client id, session type, the **contended object**, SQL id +
  operation + exec start + plan hash, top-level SQL, **PL/SQL entry point**,
  **transaction XID**, decoded enqueue (type / resource / requested mode —
  e.g. `TX-usn.slot.seq mode X`), current file/block/row, time in wait, plus a
  short **root-cause hint** per wait. SQL text is embedded in the report, so it
  reads fully offline.
- **Do it yourself SQL** — every sample (and the whole window) comes with a
  copy-paste `SELECT *` set against `DBA_HIST_ACTIVE_SESS_HISTORY`: the
  depth-indented blocking tree at that instant, all chain sessions, the root
  blocker's history across the window, everything its transaction (XID) did,
  the full SQL text, and the exact row the waiter was stuck on (via
  `DBMS_ROWID.ROWID_CREATE`).

## Requirements

- Oracle 12.2+ with the **Diagnostics Pack** license (the report reads
  `DBA_HIST_*`).
- `sqlplus` on `PATH` (set your Oracle environment, e.g. `. oraenv`, first). The
  default connection is OS-authenticated `/ as sysdba` into `CDB$ROOT`; a named
  account or a remote EZConnect/TNS string works too (see below).
- The time window must still be inside AWR retention (default 8 days):
  `select min(begin_interval_time) from dba_hist_snapshot;`

## Setup

None beyond a working `sqlplus`. The scripts run from wherever the repo is
checked out; the report is assembled and written locally into `reports/`, so
nothing in the database needs to know where the checkout lives.

## Usage

```bash
./run_report.sh [connect_string] [begin_time] [end_time] [out_file]
```

All arguments are positional; `AUTO` falls back to defaults. Times are
ISO `YYYY-MM-DDTHH24:MI:SS` (uppercase `T`, no spaces), interpreted in the
**database server's** timezone. The report always covers **every container** in
the connected CDB — AWR/ASH lives in `CDB$ROOT`, so the report reads all
containers at once and each row is tagged with its own container. To target a
different database, point the connect string at it.

`run_report.sh` is **fully read-only against the database**: the PL/SQL only
`SELECT`s (`DBA_HIST_*` and catalog views, plus session-scoped NLS settings)
and prints JSON; the HTML file is assembled and written by the shell script on
the machine you run it from. No DDL, no DML, no directory objects, no
server-side file access. That also means it works unchanged against a
**remote** database — point the connect string at any host and the report
still lands in the local `reports/`. All lock-generating demo tooling lives
separately under `demo/`.

```bash
# Last 2 hours, all containers, / as sysdba
./run_report.sh

# A specific past incident window
./run_report.sh "/ as sysdba" 2026-07-01T13:30:00 2026-07-01T15:30:00

# Named user, custom output name
./run_report.sh 'c##ashreport/pw@//localhost/cdb1.world' AUTO AUTO report.html

# Open the newest report
open "$(ls -1t reports/*.html | head -n1)"
```

The script runs the PL/SQL emitter with local `sqlplus` and writes the finished
HTML into `reports/`. ECharts is embedded, so opening a generated report needs
no network connection. Output names must be simple `.html` basenames; existing
files and the curated demo cannot be overwritten. AUTO names contain the
timestamp and process ID. See [packaging details](PACKAGING.md).

### Investigating a past incident

1. Confirm the window is inside AWR retention.
2. Run with the incident window padded by ±30 minutes; keep windows to a few
   hours (the emitter refuses > 100k blocking samples — narrow the window
   rather than raising the guard). The report spans all containers; blocking
   chains never cross a container, so per-PDB chains stay cleanly separated.
3. Read top-down: key findings for the evidence, timeline for who suffered and
   who held the locks, then click into samples for the tree and the
   object/SQL detail.

Caveats: `DBA_HIST` keeps roughly one ASH sample every 10 seconds, so sub-10s
blips can be invisible. Blocked session-time is a sample-weight estimate:
new reports retain `USECS_PER_ROW` and use an explicitly recorded historical
retention factor of 10; older reports assume 10 seconds per retained row.
Gaps between blocking observations never become the sampling interval. An empty
report means no *blocking* samples were captured in the requested window.
Session identities include instance, SID and serial number; an unresolved
blocker serial stays explicitly unknown instead of joining a reused SID.

### Using a named account instead of SYSDBA

The report itself only needs a **common user** connected to `CDB$ROOT` with
`CREATE SESSION` and `SELECT_CATALOG_ROLE` (for `DBA_HIST_*`, `V$DATABASE`,
`CDB_USERS`, `CDB_OBJECTS`). Nothing else — no directory objects, no quotas,
no DDL privileges.

## Demo / test data (test databases only)

Everything test-related lives under `demo/` and is kept strictly separate from
the production-safe report path. `demo/run_seed.sh` seeds four concurrent
blocking patterns in a PDB — TX row-lock
fan-in, a three-level TX chain, TM table-lock contention, and UL user-lock
contention — waits for ASH to sample them, forces an AWR snapshot, and prints
a ready-to-paste `run_report.sh` invocation. It creates and drops an
`ASH_TEST` schema and kills its leftover sessions: **never run it against a
real database.**

It prompts for confirmation before touching the database (type `seed`);
set `ASH_SEED_FORCE=1` to skip the prompt in scripted test runs.

```bash
./demo/run_seed.sh                    # ~4 min of held locks
./demo/run_seed.sh "/ as sysdba" 60   # quick smoke test (60s wait)
```

For UI work without any database, open `reports/ash_blocking_demo.html` — the
same report with a rich synthetic dataset inlined.

Edit `assets/template.html`, then run `./scripts/regenerate-demos.sh` to update
both the local and website demos from the maintained synthetic fixtures.
Do not edit generated demos by hand.

Local validation (Node 18+ and Python 3; no Oracle required):

```sh
node --test tests/*.test.cjs
python3 -m unittest discover -s tests/packaging -v
ASH_TEST_DEMO_PARITY=1 node --test tests/report.test.cjs
```

These checks exercise report behavior and packaging. Live Oracle SQL and AIX
execution require validation on the appropriate host.

## Repository layout

| Path | Purpose |
| --- | --- |
| `run_report.sh` | Build the report locally with SQL\*Plus (production-safe) |
| `build_report.sql` | SQL\*Plus driver |
| `sql/20_emit_html.sql` | The emitter: ASH query → JSON → template → HTML |
| `demo/run_seed.sh` | Seed demo blocking patterns — **test DBs only** |
| `demo/seed_blocking.sql` | Demo blocking patterns (A–D) |
| `assets/template.html` | Report template (single file, ECharts) |
| `reports/ash_blocking_demo.html` | Offline demo with sample data inlined |
| `docs/index.html` | Project website / landing page (served on GitHub Pages) |
| `docs/architecture.html` | Visual architecture overview (open in a browser) |

Contributor documentation — architecture, template internals, and the testing
workflow — lives in [CLAUDE.md](CLAUDE.md). For a visual overview of the
pipeline (diagrams of the report flow, the stdout contract, and the seed flow),
open [docs/architecture.html](docs/architecture.html) in a browser.
