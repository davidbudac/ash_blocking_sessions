# ASH Blocking Sessions Timeline

Turn Oracle `DBA_HIST_ACTIVE_SESS_HISTORY` blocking samples into a single,
self-contained, interactive HTML report — a per-session timeline of every
session that was blocking or blocked in a time window, with a click-through
blocking tree for any 10-second ASH sample.

No application server, no agents, no database objects beyond two directory
objects: SQL\*Plus runs one PL/SQL block that inlines the data as JSON into an
HTML template and writes the finished report to disk. Open it in any browser.

## What the report shows

- **Key findings** — blocked session-time, the biggest root blocker, whether it
  was *idle while holding the lock* (the classic uncommitted transaction) or
  actively running SQL, peak concurrency, and whether the contention resolved
  before the window ended or was still ongoing.
- **Session timeline** — one lane per session that ever blocked or waited,
  grouped by wait chain. Filled cells = waiting (colored by wait event/class),
  outlined cells = holding a lock, both = mid-chain. One cell = one ASH sample.
- **Blocking tree** — click any sample (or any session's cell) to see the exact
  chain shape at that instant: root blockers, fan-in, chain depth, per-edge wait
  events. Step sample-by-sample to watch chains form and collapse.
- **Sample detail** — per session: `SID,SERIAL#`, user, module/action, machine,
  the **contended object**, and the **SQL text** (embedded in the report, so it
  reads fully offline).

## Requirements

- Oracle 12.2+ with the **Diagnostics Pack** license (the report reads
  `DBA_HIST_*`).
- SSH access to the database host and `sqlplus` there. The default connection
  is OS-authenticated `/ as sysdba` into `CDB$ROOT`; a named account works too
  (see below).
- The time window must still be inside AWR retention (default 8 days):
  `select min(begin_interval_time) from dba_hist_snapshot;`

## Setup

Edit the header of `run_report.sh` for your environment (`HOST`, `SSH_PORT`,
`REMOTE_USER`, `ORACLE_SID` in `ENV_PREAMBLE`). If the project is synced to a
path other than `/home/oracle/ash_blocking_sessions` on the DB host, update the
hardcoded directory paths in `sql/01_dirs.sql`.

## Usage

```bash
./run_report.sh [connect_string] [begin_time] [end_time] [con_id] [out_file]
```

All arguments are positional; `AUTO` / `ALL` fall back to defaults. Times are
ISO `YYYY-MM-DDTHH24:MI:SS` (uppercase `T`, no spaces), interpreted in the
**database server's** timezone.

```bash
# Last 2 hours, all containers, / as sysdba
./run_report.sh

# A specific past incident, one PDB (CON_ID 3)
./run_report.sh "/ as sysdba" 2026-07-01T13:30:00 2026-07-01T15:30:00 3

# Named user, custom output name
./run_report.sh 'c##ashreport/pw@//localhost/cdb1.world' AUTO AUTO ALL report.html

# Open the newest report
open "$(ls -1t reports/*.html | head -n1)"
```

The script rsyncs the project to the DB host, runs the PL/SQL emitter there,
and rsyncs the finished HTML back into `reports/`.

### Investigating a past incident

1. Confirm the window is inside AWR retention.
2. Find the PDB's `CON_ID` (`select con_id, name from v$pdbs;`) — filtering to
   one container keeps the report focused.
3. Run with the incident window padded by ±30 minutes; keep windows to a few
   hours (the emitter refuses > 100k blocking samples — narrow the window or
   the container rather than raising the guard).
4. Read top-down: key findings for the verdict, timeline for who suffered and
   who held the locks, then click into samples for the tree and the
   object/SQL detail.

Caveats: `DBA_HIST` keeps roughly one ASH sample every 10 seconds, so sub-10s
blips can be invisible and "blocked session-time" is an estimate
(samples × sample interval). An empty report means no *blocking* samples were
captured in that window/container.

### Using a named account instead of SYSDBA

The report itself only needs a **common user** connected to `CDB$ROOT` with:

- `CREATE SESSION` and `SELECT_CATALOG_ROLE` (for `DBA_HIST_*`, `V$DATABASE`,
  `CDB_USERS`, `CDB_OBJECTS`), and
- access to the two directory objects: either `CREATE ANY DIRECTORY` (because
  `sql/01_dirs.sql` re-creates them each run), or have a DBA create
  `ASH_ASSETS` (READ) and `ASH_REPORTS` (READ, WRITE) once, grant them, and
  remove the `01_dirs.sql` include from `build_report.sql`.

## Demo / test data (test databases only)

`run_seed.sh` seeds four concurrent blocking patterns in a PDB — TX row-lock
fan-in, a three-level TX chain, TM table-lock contention, and UL user-lock
contention — waits for ASH to sample them, forces an AWR snapshot, and prints
a ready-to-paste `run_report.sh` invocation. It creates and drops an
`ASH_TEST` schema and kills its leftover sessions: **never run it against a
real database.**

```bash
./run_seed.sh        # ~4 min of held locks
./run_seed.sh 60     # quick smoke test
```

For UI work without any database, open `reports/ash_blocking_demo.html` — the
same report with a rich synthetic dataset inlined.

## Repository layout

| Path | Purpose |
| --- | --- |
| `run_report.sh` | Sync project to DB host, build report, pull it back |
| `run_seed.sh` | Seed demo blocking patterns on a test DB |
| `build_report.sql` | SQL\*Plus driver |
| `sql/20_emit_html.sql` | The emitter: ASH query → JSON → template → HTML |
| `sql/seed_blocking.sql` | Demo blocking patterns (A–D) |
| `assets/template.html` | Report template (single file, ECharts) |
| `reports/ash_blocking_demo.html` | Offline demo with sample data inlined |

Contributor documentation — architecture, template internals, and the testing
workflow — lives in [CLAUDE.md](CLAUDE.md).
