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
   - Substitutes the placeholders `__META_JSON__` and `__DATA_JSON__` via the local `replace_tag` procedure, which splices `prefix ‖ value ‖ suffix` with `DBMS_LOB.COPY`/`APPEND`. **These two literal tokens are the contract between the SQL and the HTML.** It does **not** use SQL `REPLACE()` — that caps its replacement argument at 32K and raises `ORA-22828` once the data JSON exceeds it (which happens well under the 100k-sample guard, ~a few hundred samples).
   - Writes the result with `DBMS_XSLPROCESSOR.CLOB2FILE` to `ASH_REPORTS`.
4. **`run_report.sh`** rsyncs `reports/` back (excluding `ash_blocking_demo.html`, see gotchas) and prints the newest file.

`sql/take_snap.sql` calls `DBMS_WORKLOAD_REPOSITORY.CREATE_SNAPSHOT` to force ASH → `DBA_HIST_ASH` flushing — without this, freshly seeded sessions won't be in the report query yet.

`sql/seed_blocking.sql` (run from `run_seed.sh`) clears any prior demo state, recreates `ASH_TEST` in PDB1, then submits `DBMS_SCHEDULER` jobs that produce four concurrent patterns spanning **multiple chains and more than one wait event at once**:
- **Pattern A**: one blocker holding row 1 of `LOCK_TARGET` + three waiters fighting for it (`enq: TX - row lock contention`, fan-in).
- **Pattern B**: A → B → C chain on rows 2/3 of `LOCK_TARGET` where B holds row 3 then waits on row 2 which A holds (`enq: TX - row lock contention`).
- **Pattern C**: one session holds `LOCK TABLE … EXCLUSIVE` on the **separate** `LOCK_TARGET_TM` table + two waiters doing DML on it (`enq: TM - contention`).
- **Pattern D**: one session holds a `DBMS_LOCK` user lock (`ALLOCATE_UNIQUE` + `REQUEST(X_MODE)`) + two waiters requesting the same lock (`enq: UL - contention`).

A real run therefore shows TX + TM + UL active simultaneously across several chains. **Note:** all three are the `Application` wait *class* — distinct wait *classes* (Concurrency/buffer-busy, Cluster/gc, etc.) can't be produced deterministically from sleeping jobs, so the offline demo (`reports/ash_blocking_demo.html`) carries synthetic data covering 5 wait classes for color/UI work.

**Pattern C MUST use its own table.** A `LOCK TABLE … EXCLUSIVE` on the shared `LOCK_TARGET` would block the TX patterns' DML on the table lock itself, collapsing every chain into a single `enq: TM` wait. Keep TM contention isolated on `LOCK_TARGET_TM`.

The job-submission block also **stops any running `ASH_DEMO_*` jobs and kills lingering `ASH_TEST` sessions before `DROP USER`** — otherwise a prior run's still-sleeping session causes `ORA-01940: cannot drop a user that is currently connected`, leaving a dirty schema (e.g. a leaked table lock).

Each seeded job tags itself with `DBMS_APPLICATION_INFO.SET_MODULE(...)` (e.g. `ETL_LOAD/HOLD_ROW1`, `ORDERS_API/POST_INVOICE_*`, `NIGHTLY_BATCH/CHAIN_ROOT|CHAIN_MID|CHAIN_LEAF`, `MAINT_REORG/LOCK_TABLE_EXCL`, `PRICING_SVC/HOLD_USER_LOCK`) so the identifier toggles in the UI show meaningful per-SID variation. **If you add a new seed job, give it a distinctive `MODULE/ACTION` pair** or it'll look identical to existing jobs in the report.

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
3. **Key-findings summary + charts**, each in its own `render*()` function:
   - `renderSummary()` — computes window-level KPIs (blocked samples, waiting/blocking session counts, distinct chains, deepest chain depth, peak concurrent waiters) into `#kpis` and auto-generated finding sentences into `#findings`. Always runs on the **full** dataset (it's the report's overall verdict), even when a single sample is focused.
   - `renderOverview()` — **one stacked bar per individual ASH sample** (≈10s; DBA_HIST ASH cadence), stacked by the chosen "Color by" dimension, on a `type:'time'` x-axis with inside+slider `dataZoom`. **Clicking a bar focuses that single sample** and cross-filters every other chart (see cross-filter below). This chart always plots the full dataset so any sample stays clickable while a focus is active.
   - `renderTopRoots()` — ranks ultimate root-cause blockers by transitive downstream blocked-sample count (horizontal bar); clicking a bar drills to that root's rows.
   - `renderSwimlane()` — top-N waiters as a custom-series Gantt; runs of same-color buckets are coalesced into single bars.
   - `renderTree()` / `drawTreeAt(idx)` — deterministic layered (tidy-tree) chain map at one bucket, scrubbable via `#treeScrub` (with `#treePlay`). Edges draw root blocker → waiter. Three node colors: blue (waiter only), orange `#e67e22` (chain middle: blocks **and** is blocked — use the literal, not a CSS var, since canvas can't resolve it), red (root blocker). Node size ∝ √(downstream impact).
   - `renderChainTimeline()` — Gantt where each row is one SID, grouped by walking each waiter's *dominant parent* across the whole window to its ultimate root (cycle-guarded), then indented by depth. Filled cells = waiting that bucket; outlined cells = blocking others.
   - `renderSankey()` — blocker → waiter flow; grouping (`#sankeyGroup`) by session/user/module/program, capped by `#sankeyTopN`.
4. **Cross-filter** (`applySelection(t)` / `highlightOverview()` / `updateSelectionBanner()`): module-level `activeData` (full set, or one focused `selectedT` sample) and `selectedT`. Each cross-filtered render function shadows `data` with `activeData` on its first line (`const data = activeData;`), so re-pointing `activeData` once filters them all. `applySelection` also drives the `#sampleSel` banner (with `#sampleSelClear`), the `#sampleTableWrap` detail table (`showSamples()`), and the overview highlight band. `renderSummary` and `renderOverview` deliberately stay on the full dataset.
5. **`renderAll()`** wires the summary and charts to controls (`#bucket`, `#colorBy`, `#topN`, `#sankeyGroup`, `#sankeyTopN`, `#idToggles`).

When changing the template:
- Preserve the two placeholders `__META_JSON__` and `__DATA_JSON__` verbatim — the PL/SQL emitter REPLACEs them.
- If you add a new field to the chart data, also add it to the `JSON_OBJECT(...)` in `sql/20_emit_html.sql`.
- `assets/template.html` is the source of truth shipped to the DB host. `reports/ash_blocking_demo.html` is a snapshot with sample data inlined for offline UI work; remember to mirror non-data changes back to the template.

## Testing the report

There is no checked-in test runner — testing is done with throwaway Node scripts in `/tmp` plus, for end-to-end confidence, a live DB run. The four levels below go from fastest/cheapest to slowest/most-real. Use the lower levels for almost all iteration; reach for the live run only to validate the SQL emitter and real ASH shapes.

### 1. Eyeball in a browser (fastest UI loop)

`reports/ash_blocking_demo.html` is structurally identical to a freshly-rendered report — same `<script>`, same chart code — but `window.ASH_DATA` is already inlined with a representative dataset (currently **8 concurrent chains across 5 wait classes / 8 events**, covering Patterns A–D plus synthetic Concurrency/Cluster/User-I/O variety the live seed can't make). Edit it, refresh, look. No DB round-trip. Mirror non-data changes back into `assets/template.html` when the UI is right.

### 2. Headless harness (assert on what *would* render)

The report is one IIFE in the last `<script>` block (no `src`), preceded by a small `<script>` that sets `window.ASH_META`/`window.ASH_DATA`. To test render logic without a browser, run both scripts under Node with a stubbed DOM + ECharts and assert on the captured `setOption` payloads. Recipe (write to `/tmp`, e.g. `/tmp/harness.js`):

1. **Read the HTML**, then **inject test data** by regex-replacing the two assignments — this works for both the demo (`= {...};`) and the shipped template (`= __META_JSON__;`):
   ```js
   html = html.replace(/window\.ASH_META\s*=\s*[\s\S]*?;\s*\n/, `window.ASH_META = ${JSON.stringify(meta)};\n`);
   html = html.replace(/window\.ASH_DATA\s*=\s*[\s\S]*?;\s*\n/, `window.ASH_DATA = ${JSON.stringify(data)};\n`);
   ```
2. **Extract scripts**: `[...html.matchAll(/<script>([\s\S]*?)<\/script>/g)]`; the data script is the one matching `window.ASH_DATA`, the IIFE is the one matching `function render`. Do **not** strip the `(function(){…})()` wrapper — run it whole.
3. **Stub ECharts**: `echarts.init(el)` returns a fake chart whose `setOption(o)` pushes into a per-chart capture array and merges into `_last`; also stub `on('click', fn)` (capture handlers), `off`, `resize`, `getZr().on`, `dispatchAction`, and `graphic.LinearGradient`.
4. **Stub the DOM**: a `getElementById` that lazily returns fake elements with getters/setters for `textContent`/`innerHTML`/`value`, an `appendChild`, `addEventListener` (no-op), and — for `<select>` reads — an `options` getter returning `[{text:value}]` and a `selectedIndex`. Seed control defaults (`bucket`, `colorBy`, `topN`, `sankeyGroup`, `sankeyTopN`, `treeScrub`). `querySelectorAll` can return `[]`. Provide a `window` with a no-op `addEventListener`.
5. **Run** both scripts in a `vm` context, then **assert** on captures. Useful invariants:
   - Overview is a `type:'time'` chart, so bars live in `series[0].data` (one point per distinct sample), **not** `xAxis.data`. Assert `series[0].data.length === new Set(data.map(d=>d.t)).size`.
   - **Cross-filter**: grab `charts['chart-overview'].clicks[0]` and call it with `{value:[tms, count]}` where `tms = new Date(sample.t).getTime()`. After clicking a sample, the tree node count / top-roots total / detail table should shrink to that sample's rows; clicking again (or `applySelection(null)`) restores the full set. Click a **sparse** sample to prove the tree shrinks (the busiest sample can legitimately equal the full graph).
   - Tree node colors include `#e67e22` (chain-middle) when chains are ≥3 deep.

Run the same harness against **both** `reports/ash_blocking_demo.html` and `assets/template.html` (with data injected) — they must behave identically, or the two files have drifted.

### 3. Synthetic datasets (exercise variety the live seed can't)

To test multiple concurrent chains and multiple wait *classes* (colors), generate a JSON array matching the emitter's field shape and feed it to the harness or inline it into a copy of the demo. Each row needs at least: `t` (`YYYY-MM-DDTHH:MM:SS`), `inst`, `sid`, `serial`, `bInst`, `bSid`, `bSer`, `ev`, `wc`, `sqlId`, `module`/`user`/`prog`/`mach`/`action`, and the blocker-enrichment `b*` fields (`bUser`, `bMod`, `bAct`, `bProg`, `bMach`, `bSqlId`). Model each chain as `{waiter, blocker, ev, wc, span:[startSampleIdx, endSampleIdx]}` and emit one row per active waiter per sample in its span; stagger spans so the overview has shape and the cross-filter is meaningful. Use `wc` values that match the keys in `OEM_WAIT_CLASS` (`Application`, `Concurrency`, `Configuration`, `Cluster`, `User I/O`, …) so colors render. Avoid `Date.now()`/`Math.random()` if you want reproducible output.

### 4. Live end-to-end run (validates the SQL emitter + real ASH)

```bash
./run_seed.sh                 # seed Patterns A–D, wait 240s, force an AWR snapshot
                              # (./run_seed.sh 60 for a quick, lower-sample smoke test)
# copy the suggested window it prints, then:
./run_report.sh <begin> <end> 3   # CON_ID 3 = PDB1
```

Then **verify the real data mix** before trusting the render — extract the embedded `window.ASH_DATA` from the generated `reports/ash_blocking_<ts>.html` and tally distinct `ev`/`wc` and how many samples carry >1 wait event at once. A healthy run shows `enq: TX - row lock contention`, `enq: TM - contention`, and `enq: UL - contention` overlapping across multiple samples. If everything collapsed to a single event, a lock leaked across runs (see gotchas) — re-seed. Finally, run the level-2 harness against the generated report to confirm it renders without throwing.

**Seeding/reporting hit the remote DB** (`dbmint`) — it creates the `ASH_TEST` schema, holds locks for ~4 minutes, and forces an AWR snapshot. Confirm before running if that matters in your context. The jobs `auto_drop` and roll back, so no manual cleanup is needed.

## Operational gotchas

- `sql/01_dirs.sql` paths are hardcoded to `/home/oracle/ash_blocking_sessions/{assets,reports}`. If the project is synced elsewhere on the DB host, update this file.
- `build_report.sql` must connect as SYSDBA in `CDB$ROOT` because `DBA_HIST_ACTIVE_SESS_HISTORY` lives there. The `CON_ID` argument filters at query time.
- `run_report.sh` rsync `--delete`s the remote project tree (excluding `reports/` and `.git/`). Don't leave anything on the host that isn't in the repo.
- The 100k-sample guard in `20_emit_html.sql` is a safety against running a multi-day window. Narrow the window or filter by `CON_ID` rather than raising the limit.
- Seed jobs (`ASH_TEST.ASH_DEMO_*`) are created with `auto_drop => TRUE`; they vanish after their `DBMS_LOCK.SLEEP` completes. No cleanup step needed.
- **Placeholder substitution must not use SQL `REPLACE()`** — its replacement arg is capped at 32K (`ORA-22828`), which the data JSON exceeds at a few hundred samples. The emitter uses the `DBMS_LOB`-based `replace_tag` procedure instead. Don't "simplify" it back to `REPLACE`.
- **`run_report.sh` excludes `ash_blocking_demo.html` from the rsync-back.** The curated demo lives in `reports/` (which the up-sync excludes), so a stale copy lingering on the host would otherwise overwrite your local source-of-truth demo on every report build. If you ever rename the demo, update that exclude.
- **Don't lock the shared `LOCK_TARGET` table in EXCLUSIVE mode** in any seed pattern — it starves the TX row-lock patterns and collapses all chains into one `enq: TM` wait. The TM pattern uses a dedicated `LOCK_TARGET_TM`.
- A prior seed run's still-sleeping sessions can cause `ORA-01940` on `DROP USER`; the seed now kills `ASH_TEST` sessions and stops `ASH_DEMO_*` jobs first. If you see a dirty schema, that teardown is where to look.
