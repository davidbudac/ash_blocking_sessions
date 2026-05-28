# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

A PL/SQL + HTML pipeline that turns Oracle `DBA_HIST_ACTIVE_SESS_HISTORY` blocking samples into a single self-contained interactive HTML report. There is no application server: SQL*Plus runs a PL/SQL block that fills JSON into a template and writes the result to disk.

The runtime target is a remote Oracle CDB on host `dbmint:2201` (user `oracle`, SID `cdb1`). Seed data lives in PDB1 (`CON_ID=3`). The local repo is `rsync`ed to `~/ash_blocking_sessions` on the host on every run.

## Common commands

```bash
# Seed realistic blocking scenarios in PDB1, wait, then force an AWR snapshot.
# Default wait is 240s — use a smaller number for a quick smoke test (less ASH data).
./run_seed.sh              # 240s wait
./run_seed.sh 60           # 60s wait

# Build the HTML report (rsyncs project up, runs sqlplus as sysdba, rsyncs reports back).
# Args are positional; 'AUTO' / 'ALL' fall back to defaults.
./run_report.sh                                          # last 2h, all containers
./run_report.sh 2026-05-20T10:00:00 2026-05-20T14:00:00  # explicit window
./run_report.sh AUTO AUTO 3                              # last 2h, only PDB1
./run_report.sh AUTO AUTO ALL report.html                # custom output filename

# Open the latest report locally
open "$(ls -1t reports/*.html | head -n1)"
```

Times are ISO `YYYY-MM-DDTHH24:MI:SS` (uppercase `T`, no spaces). `run_seed.sh` prints a ready-to-paste `run_report.sh` invocation with the seed window.

There is **no build, no lint, no test runner**. UI iteration is done by editing `reports/ash_blocking_demo.html` (which has pre-baked sample data inlined as `window.ASH_DATA`) and opening it in a browser — no DB round-trip required. Once the UI is right, mirror the same edits into `assets/template.html`.

## How a report is produced

1. **`run_report.sh`** rsyncs the repo (excluding `reports/` and `.git/`) to `oracle@dbmint:~/ash_blocking_sessions`, then SSHes in and runs `sqlplus -S -L / as sysdba @build_report.sql ...`.
2. **`build_report.sql`** is the driver. It sources `sql/00_settings.sql` (non-interactive SQL*Plus settings, NLS formats, `WHENEVER SQLERROR EXIT FAILURE`), then `sql/01_dirs.sql` (creates Oracle directory objects `ASH_ASSETS` → `assets/` and `ASH_REPORTS` → `reports/` — paths are **hardcoded** to `/home/oracle/ash_blocking_sessions`), then `sql/20_emit_html.sql`.
3. **`sql/20_emit_html.sql`** is the core PL/SQL block. It:
   - Counts blocking samples in the window. Refuses to render if `> 100000` (raises `-20001`).
   - Builds the data CLOB with `JSON_ARRAYAGG(JSON_OBJECT(... ABSENT ON NULL ... RETURNING CLOB))`. The query **left-joins `DBA_HIST_ACTIVE_SESS_HISTORY` to itself** on `(dbid, snap_id, sample_id, blocking_inst_id, blocking_session, blocking_session_serial#)` to enrich each row with what the blocker was doing in the same sample (fields prefixed `b*`: `bEv`, `bSqlId`, `bMod`, `bAct`, `bProg`, `bMach`, `bUser`, …). Usernames come from `DBA_USERS`.
   - Loads `assets/template.html` via `BFILE` + `DBMS_LOB.LOADCLOBFROMFILE` (UTF-8).
   - Does two `REPLACE(...)` calls on the CLOB to substitute the placeholders `__META_JSON__` and `__DATA_JSON__`. **These two literal tokens are the contract between the SQL and the HTML.**
   - Writes the result with `DBMS_XSLPROCESSOR.CLOB2FILE` to `ASH_REPORTS`.
4. **`run_report.sh`** rsyncs `reports/` back and prints the newest file.

`sql/take_snap.sql` calls `DBMS_WORKLOAD_REPOSITORY.CREATE_SNAPSHOT` to force ASH → `DBA_HIST_ASH` flushing — without this, freshly seeded sessions won't be in the report query yet.

`sql/seed_blocking.sql` (run from `run_seed.sh`) drops and recreates `ASH_TEST` in PDB1, then submits `DBMS_SCHEDULER` jobs that produce two canonical patterns:
- **Pattern A**: one blocker holding row 1 + three waiters fighting for it (`enq: TX - row lock contention`, fan-in).
- **Pattern B**: A → B → C chain where B holds row 3 then waits on row 2 which A holds.

Each seeded job tags itself with `DBMS_APPLICATION_INFO.SET_MODULE(...)` (e.g. `ETL_LOAD/HOLD_ROW1`, `ORDERS_API/POST_INVOICE_*`, `NIGHTLY_BATCH/CHAIN_ROOT|CHAIN_MID|CHAIN_LEAF`) so the identifier toggles in the UI show meaningful per-SID variation. **If you add a new seed job, give it a distinctive `MODULE/ACTION` pair** or it'll look identical to existing jobs in the report.

## Template architecture (`assets/template.html`)

Single HTML file, one IIFE, ECharts 5.5.0 from CDN. Pure-static — no fetches at runtime. Data arrives at load time via:

```html
<script>
  window.ASH_META = __META_JSON__;
  window.ASH_DATA = __DATA_JSON__;
</script>
```

The IIFE structure (top → bottom in `assets/template.html`):

1. **Identity helpers**: `colorKey(d)`, `waiterKey(d)`, `blockerKey(d)` derive the per-row category for color/grouping. `buildIdentityCache()` walks the dataset once, picks the *dominant* (most-frequent) value of each identifier (`user`, `prog`, `module`, `action`, `mach`) per SID, considering both the waiter row and the enriched blocker fields (`bUser`, `bProg`, `bMod`, `bAct`, `bMach`) — this is how a session that only appears as a blocker still gets a label. `decorateSidLabel(sid)` appends the user-selected identifier toggles to a SID for display.
2. **OEM color palette**: `OEM_WAIT_CLASS` maps wait classes to OEM Top Activity colors. `oemColorForKey()` returns the class color (or, for events, the class color with a deterministic ±12% lightness shift from `shiftLightness()` + `strHash01()` so siblings in the same class share a hue but stay distinct).
3. **Summary + four charts**, each in its own `render*()` function:
   - `renderImpactSummary()` — root-cause summary tiles for top root blocker, peak blocked waiters, sample count, dominant workload, top wait event, and duration.
   - `renderOverview()` — stacked bars per time bucket. The default color dimension is root blocker, not wait event, because many blocking windows collapse to a single wait event.
   - `renderSwimlane()` — top-N waiters as a custom-series Gantt; rows are sorted by root blocker and impact, and runs of same-color buckets are coalesced into single bars.
   - `renderTree()` — deterministic layered chain map at one bucket, scrubbable via `#treeScrub`. Edges draw root blocker → waiter so root causes read left-to-right. Three node colors: blue (waiter only), orange (chain middle: blocks **and** is blocked), red (root blocker).
   - `renderChainTimeline()` — Gantt where each row is one SID. SIDs are grouped by walking each waiter's *dominant parent* across the entire window to its ultimate root (with a cycle guard), then indented by depth. Filled cells = SID was waiting that bucket; outlined cells = SID was blocking others. Mid-chain cells can be both filled and outlined.
4. **`renderAll()`** wires the summary and charts to controls (`#bucket`, `#colorBy`, `#topN`, `#idToggles`).

When changing the template:
- Preserve the two placeholders `__META_JSON__` and `__DATA_JSON__` verbatim — the PL/SQL emitter REPLACEs them.
- If you add a new field to the chart data, also add it to the `JSON_OBJECT(...)` in `sql/20_emit_html.sql`.
- `assets/template.html` is the source of truth shipped to the DB host. `reports/ash_blocking_demo.html` is a snapshot with sample data inlined for offline UI work; remember to mirror non-data changes back to the template.

## Testing UI changes without the DB

The demo report (`reports/ash_blocking_demo.html`) is structurally identical to a freshly-rendered report — same script, same chart code, but `window.ASH_DATA` already contains a representative 100+ samples covering Pattern A and Pattern B. Edit it directly, refresh in a browser.

For headless smoke-testing of the IIFE you can extract the last `<script>` block and run it under Node with stubbed DOM + ECharts: stub `echarts.init` to capture `setOption` calls, then read back the resulting `series`/`yAxis` to assert on what would render. There are no checked-in probes — write throwaway scripts in `/tmp` as needed. Make sure to strip the IIFE wrapper (`(function(){ … })();`) and the trailing `renderAll();` so you can call render functions externally and inspect captures.

## Operational gotchas

- `sql/01_dirs.sql` paths are hardcoded to `/home/oracle/ash_blocking_sessions/{assets,reports}`. If the project is synced elsewhere on the DB host, update this file.
- `build_report.sql` must connect as SYSDBA in `CDB$ROOT` because `DBA_HIST_ACTIVE_SESS_HISTORY` lives there. The `CON_ID` argument filters at query time.
- `run_report.sh` rsync `--delete`s the remote project tree (excluding `reports/` and `.git/`). Don't leave anything on the host that isn't in the repo.
- The 100k-sample guard in `20_emit_html.sql` is a safety against running a multi-day window. Narrow the window or filter by `CON_ID` rather than raising the limit.
- Seed jobs (`ASH_TEST.ASH_DEMO_*`) are created with `auto_drop => TRUE`; they vanish after their `DBMS_LOCK.SLEEP` completes. No cleanup step needed.
