# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

A PL/SQL + HTML pipeline that turns Oracle `DBA_HIST_ACTIVE_SESS_HISTORY` blocking samples into a single self-contained interactive HTML report. There is no application server: SQL*Plus runs a PL/SQL block that fills JSON into a template and writes the result to disk.

Everything runs locally where the repo lives — a plain `sqlplus` invocation, no ssh and no rsync. `sqlplus` connects to whatever the connect string points at (local OS auth by default, or a remote DB via EZConnect/TNS); since the HTML is assembled client-side from the query output, the machine running the scripts and the database can freely differ. Seed data lives in PDB1 (`CON_ID=3`). The shell scripts are POSIX `sh` (no bash-isms) so they run unchanged under the AIX `/bin/sh` (ksh), ksh93, or bash.

## Common commands

```bash
# Seed realistic blocking scenarios in PDB1, wait, then force an AWR snapshot.
# DEMO/TEST ONLY — prompts for confirmation (type 'seed'); ASH_SEED_FORCE=1 skips it.
# Args: [connect_string] [wait_secs]; default wait is 240s.
./demo/run_seed.sh                        # / as sysdba, 240s wait
./demo/run_seed.sh "/ as sysdba" 60       # 60s wait (quick smoke test, less ASH data)

# Build the HTML report (runs sqlplus locally; writes into reports/).
# Args are positional: [connect_string] [begin] [end] [out_file];
# 'AUTO' falls back to defaults. Arg 1 is the sqlplus connect string
# ('AUTO' = '/ as sysdba'); quote it if it contains spaces. The report always
# covers every container in the connected CDB — there is no per-container arg.
./run_report.sh                                                    # / as sysdba, last 2h, all containers
./run_report.sh "/ as sysdba" 2026-05-20T10:00:00 2026-05-20T14:00:00  # explicit window
./run_report.sh 'c##rep/pw@//localhost/cdb1.world' AUTO AUTO report.html  # named common user

# Open the latest report locally
open "$(ls -1t reports/*.html | head -n1)"
```

Times are ISO `YYYY-MM-DDTHH24:MI:SS` (uppercase `T`, no spaces). `demo/run_seed.sh` prints a ready-to-paste `run_report.sh` invocation with the seed window.

**Production stance:** `run_report.sh` is **fully read-only against the database** — the PL/SQL only `SELECT`s (`DBA_HIST_*`, `CDB_USERS`, `CDB_OBJECTS`, `V$DATABASE`) plus session-scoped NLS `ALTER SESSION`s. No DDL, no DML, no directory objects, no server-side file access: the JSON is printed to stdout and the HTML is assembled client-side by the shell. This also means it works against a **remote** DB via EZConnect/TNS — the report always lands in the local `reports/`. Everything under `demo/` is test-database-only and gated behind a confirmation prompt.

There is **no build, no lint, no test runner**. UI iteration is done by editing `reports/ash_blocking_demo.html` (which has pre-baked sample data inlined as `window.ASH_DATA`) and opening it in a browser — no DB round-trip required. Once the UI is right, mirror the same edits into `assets/template.html`.

## How a report is produced

1. **`run_report.sh`** `cd`s to its own directory and runs `sqlplus -S -L <connect_string> @build_report.sql <begin> <end>` (connect string is arg 1; default `/ as sysdba`), capturing **all stdout** into `reports/.build.$$/out.log`. A named user must be a **common** user connected to `CDB$ROOT` with `CREATE SESSION` and `SELECT_CATALOG_ROLE` — nothing else; there are no directory objects and no DDL anywhere in the report path.
2. **`build_report.sql`** is the driver. It sources `sql/00_settings.sql` (non-interactive SQL*Plus settings, NLS formats, `WHENEVER SQLERROR EXIT FAILURE`, and **`SET TAB OFF`** — see gotchas), defines the two positional args (`begin_time`, `end_time`), then sources `sql/20_emit_html.sql`.
3. **`sql/20_emit_html.sql`** is the core PL/SQL block. It:
   - Counts blocking samples in the window. Refuses to render if `> 100000` (raises `-20001`).
   - Builds the data CLOB with `JSON_ARRAYAGG(JSON_OBJECT(... ABSENT ON NULL ... RETURNING CLOB))`. The query **left-joins `DBA_HIST_ACTIVE_SESS_HISTORY` to itself** on `(dbid, snap_id, sample_id, blocking_inst_id, blocking_session, blocking_session_serial#)` to enrich each row with what the blocker was doing in the same sample (fields prefixed `b*`: `bEv`, `bSqlId`, `bMod`, `bAct`, `bProg`, `bMach`, `bUser`, …). Usernames and the waiter's contended object (`obj`, from `CURRENT_OBJ#`) come from **`CDB_USERS`/`CDB_OBJECTS` joined on `(con_id, id)`** — the plain `DBA_*` views in `CDB$ROOT` can't see PDB users/objects, so don't "simplify" those joins back. The meta JSON additionally carries `sqlText`, a `sql_id → first-200-chars` map (from `DBA_HIST_SQLTEXT`) for every SQL that ran in the window, so the report can show statement text offline (`sqlSnip()` in the template; degrades gracefully when absent).
   - **Prints** both CLOBs to stdout via `DBMS_OUTPUT` between marker lines (`__META_JSON_BEGIN__/END__`, `__DATA_JSON_BEGIN__/END__`). Each chunk line is `#<≤500 chars>#` — the `#` sentinels protect leading/trailing whitespace from SQL\*Plus line trimming (a chunk ending in a space silently loses it otherwise; this corrupted event names in testing). 500 chars keeps every line under POSIX `LINE_MAX` even at 4-byte UTF-8, so AIX awk never sees an over-long record. Chunk boundaries can fall **mid-token**; the client joins them with NO newlines (safe because JSON generation escapes control characters, so the payload has no literal newlines). It touches **no server-side files**: no BFILE, no directory objects, no `CLOB2FILE`.
4. **`run_report.sh`** post-processes the captured stdout with two awk passes: the first splits marker-delimited chunk lines (sentinels stripped, still one chunk per line) into `meta.json`/`data.json` and echoes everything else as progress output; the second streams `assets/template.html` and replaces each placeholder line with the concatenated chunks. **The placeholders `__META_JSON__` and `__DATA_JSON__` sit ALONE on their own lines in the template — that line-based layout is the contract with the shell splice** (checked before splicing; the build fails if a placeholder line is missing). The finished HTML lands in `reports/<out_file>` on the machine running the script — which is why the tool works unchanged against a remote DB.

`demo/take_snap.sql` calls `DBMS_WORKLOAD_REPOSITORY.CREATE_SNAPSHOT` to force ASH → `DBA_HIST_ASH` flushing — without this, freshly seeded sessions won't be in the report query yet.

`demo/seed_blocking.sql` (run from `demo/run_seed.sh`) clears any prior demo state, recreates `ASH_TEST` in PDB1, then submits `DBMS_SCHEDULER` jobs that produce four concurrent patterns spanning **multiple chains and more than one wait event at once**:
- **Pattern A**: one blocker holding row 1 of `LOCK_TARGET` + three waiters fighting for it (`enq: TX - row lock contention`, fan-in).
- **Pattern B**: A → B → C chain on rows 2/3 of `LOCK_TARGET` where B holds row 3 then waits on row 2 which A holds (`enq: TX - row lock contention`).
- **Pattern C**: one session holds `LOCK TABLE … EXCLUSIVE` on the **separate** `LOCK_TARGET_TM` table + two waiters doing DML on it (`enq: TM - contention`).
- **Pattern D**: one session holds a `DBMS_LOCK` user lock (`ALLOCATE_UNIQUE` + `REQUEST(X_MODE)`) + two waiters requesting the same lock (`enq: UL - contention`).

A real run therefore shows TX + TM + UL active simultaneously across several chains. **Note:** all three are the `Application` wait *class* — distinct wait *classes* (Concurrency/buffer-busy, Cluster/gc, etc.) can't be produced deterministically from sleeping jobs, so the offline demo (`reports/ash_blocking_demo.html`) carries synthetic data covering 5 wait classes for color/UI work.

**Pattern C MUST use its own table.** A `LOCK TABLE … EXCLUSIVE` on the shared `LOCK_TARGET` would block the TX patterns' DML on the table lock itself, collapsing every chain into a single `enq: TM` wait. Keep TM contention isolated on `LOCK_TARGET_TM`.

The job-submission block also **stops any running `ASH_DEMO_*` jobs and kills lingering `ASH_TEST` sessions before `DROP USER`** — otherwise a prior run's still-sleeping session causes `ORA-01940: cannot drop a user that is currently connected`, leaving a dirty schema (e.g. a leaked table lock).

The seed **submits the jobs from a dedicated `ASH_TEST` connection** (`CONNECT ash_test/...@//localhost/pdb1.world` mid-script), not from the SYSDBA session that does schema setup. A scheduler job created from a SYSDBA session runs its slave with **session user SYS** — only the schema is ASH_TEST — so ASH records `USER_ID=0` and the whole report shows user `SYS`. Jobs created by ASH_TEST itself run (and get sampled) as ASH_TEST. This adds a dependency on the PDB's default service `pdb1.world` being registered with the local listener on the DB host.

Each seeded job tags itself with `DBMS_APPLICATION_INFO.SET_MODULE(...)` (e.g. `ETL_LOAD/HOLD_ROW1`, `ORDERS_API/POST_INVOICE_*`, `NIGHTLY_BATCH/CHAIN_ROOT|CHAIN_MID|CHAIN_LEAF`, `MAINT_REORG/LOCK_TABLE_EXCL`, `PRICING_SVC/HOLD_USER_LOCK`) so the identifier toggles in the UI show meaningful per-SID variation. **If you add a new seed job, give it a distinctive `MODULE/ACTION` pair** or it'll look identical to existing jobs in the report.

## Template architecture (`assets/template.html`)

Single HTML file, one IIFE, ECharts 5.5.0 from CDN. Pure-static — no fetches at runtime. Data arrives at load time via:

```html
<script>
  window.ASH_META =
__META_JSON__
  ;
  window.ASH_DATA =
__DATA_JSON__
  ;
</script>
```

(The placeholders sit alone on their own lines so `run_report.sh` can splice
them with a line-based awk; JS is fine with the newline before `;`.)

The IIFE structure (top → bottom in `assets/template.html`):

1. **Identity helpers**: `colorKey(d)`, `waiterKey(d)`, `blockerKey(d)` derive the per-row category for color/grouping. `buildIdentityCache()` walks the dataset once, picks the *dominant* (most-frequent) value of each identifier (`user`, `prog`, `module`, `action`, `mach`) per SID, considering both the waiter row and the enriched blocker fields (`bUser`, `bProg`, `bMod`, `bAct`, `bMach`) — this is how a session that only appears as a blocker still gets a label. `decorateSidLabel(sid)` appends the user-selected identifier toggles to a SID for display; the **`user` and `module` toggles default to checked** so charts are readable without discovering the toggles. `SAMPLE_MS` (median gap between distinct sample times, ≈10s) converts sample counts into approximate blocked session-time via `fmtDur()`.
2. **OEM color palette**: `OEM_WAIT_CLASS` maps wait classes to OEM Top Activity colors. For event-mode coloring, `oemColorForKey()` first looks the event up in `OEM_WAIT_EVENT` — a curated table of OEM-style colors for common specific events (reds = Application, blues = I/O, maroons = Concurrency, purples = Configuration, yellows = Cluster, …), each a distinct shade within its class family. Events not in the table fall back to `spreadWithinClass()`, which rotates hue and varies lightness/saturation deterministically (`hexToHsl`/`hslToHex` + `strHash01`) so siblings in the same class stay clearly distinct rather than near-identical. (`shiftLightness()` is the older, subtler helper, now unused by event mode.)
3. **Window-level chain structure** (`CHAIN`, computed once): each SID's *dominant* (most-frequent) blocker across the whole window, walked to its ultimate root with a cycle guard → `sidInfo` (root/depth/activity per SID), `groups` (root → members), `rootOf(sid)`. This is deliberately window-level, not per-instant: per-instant parents can flap between samples, and both the lane grouping and "isolate this chain" need one stable answer. `allTs` (sorted distinct sample times) + `snapT(t)` snap any x-coordinate to a real ASH sample; `peakT` is the sample with the most distinct blocked sessions.
4. **Key-findings summary + the two panels**, each in its own `render*()` function:
   - `renderSummary()` — computes window-level KPIs (blocked samples, ≈ blocked session-time, waiting/blocking session counts, distinct chains, deepest chain depth, peak concurrent waiters) into `#kpis` and auto-generated finding sentences into `#findings`: top root with session-time, an **idle-vs-active blocker verdict** (dominant `bEv`/`bSqlId` where the root is the direct blocker; no `bEv` ⇒ "idle while holding the lock — likely an uncommitted transaction"), the root chain's active span, and a **resolved-or-ongoing line** (last blocking sample within 2×`SAMPLE_MS` of `meta.endTime` ⇒ "still active at window end"). Always runs on the **full** dataset (it's the report's overall verdict), regardless of the selection.
   - `renderLanes()` — **the primary chart**: a custom-series Gantt with one lane per session that ever waited *or* blocked, grouped by chain (◆ root first, members indented by depth, separator rows between chains), busiest chains first until the `#topN` "Max lanes" cap (whole chains only — never split one across the cap; `#laneNote` reports hidden chains). Cells are per-ASH-sample; adjacent same-state samples coalesce into runs. **Filled cell** = waiting (color = `colorKey`), **outlined** = blocking-only (holding a lock), filled + dark stroke = both at once. Container height grows with lane count (`interval: 0` on the y-axis — never let ECharts auto-skip labels, it makes lanes look dropped). Clicks: **a cell** → `applySelection(snapT(clickX), rootOf(sid))` (focus that sample + isolate that chain); **empty plot space** (a `getZr()` click with no target, wired once via `laneClickWired`) → `applySelection(snapT(x), null)` (whole instant).
   - `renderTreePanel()` — deterministic layered (tidy-tree) chain map at the **selected sample** (`selectedT`), optionally filtered to the selected chain. Header shows `#treeTime`/`#treeStat`, `#treeChain` (isolation state + "show all chains" link) and `#treePrev`/`#treePlay`/`#treeNext` which step the selection through `allTs`. Edges draw waiter → blocker; **edge event labels show on hover only** (always-on labels collide at fan-in). Three node categories: blue "waiter", orange `#e67e22` "blocks & waits" (use the literal, not a CSS var, since canvas can't resolve it), red "root blocker". Node size ∝ √(downstream impact). **Clicking a node shows its own + all transitively downstream samples**, so a pure root blocker drills to its whole chain instead of "No samples". `XGAP` widens when identity toggles are active.
5. **Selection model** (`applySelection(t, root)` / `selectedSamples()` / `updateBanner()`): module-level `selectedT` (focused sample_time, defaults to `peakT` on load — never null after init) and `selectedRoot` (chain to isolate, or null for all). `applySelection` re-feeds the lanes chart via `refreshLanesSelection()` — a merge-mode `setOption` that re-sends the same run data (so `renderItem` re-runs and out-of-chain lanes dim) and moves the focus band **without resetting the user's zoom** — then re-renders the tree, the `#sampleSel` banner (with "All chains" / "Jump to peak" buttons), and the `#sampleTableWrap` detail table (`showSamples()`).
6. **`renderAll()`** wires the summary and panels to controls (`#colorBy`, `#topN`, `#idToggles`); full `renderLanes()` re-runs (which do reset zoom) happen only on control changes, not on selection.

When changing the template:
- Preserve the two placeholders `__META_JSON__` and `__DATA_JSON__` verbatim, **each alone on its own line** — `run_report.sh` does a line-based splice (the emitter no longer substitutes anything server-side).
- If you add a new field to the chart data, also add it to the `JSON_OBJECT(...)` in `sql/20_emit_html.sql`.
- `assets/template.html` is the source of truth the emitter loads at build time. `reports/ash_blocking_demo.html` is a snapshot with sample data inlined for offline UI work; remember to mirror non-data changes back to the template.

## Testing the report

There is no checked-in test runner — testing is done with throwaway Node scripts in `/tmp` plus, for end-to-end confidence, a live DB run. The four levels below go from fastest/cheapest to slowest/most-real. Use the lower levels for almost all iteration; reach for the live run only to validate the SQL emitter and real ASH shapes.

### 1. Eyeball in a browser (fastest UI loop)

`reports/ash_blocking_demo.html` is structurally identical to a freshly-rendered report — same `<script>`, same chart code — but `window.ASH_DATA` is already inlined with a representative dataset (currently **8 concurrent chains across 5 wait classes / 8 events**, covering Patterns A–D plus synthetic Concurrency/Cluster/User-I/O variety the live seed can't make). Edit it, refresh, look. No DB round-trip. Mirror non-data changes back into `assets/template.html` when the UI is right.

### 2. Headless harness (assert on what *would* render)

The report is one IIFE in the last `<script>` block (no `src`), preceded by a small `<script>` that sets `window.ASH_META`/`window.ASH_DATA`. To test render logic without a browser, run both scripts under Node with a stubbed DOM + ECharts and assert on the captured `setOption` payloads. Recipe (write to `/tmp`, e.g. `/tmp/harness.js`):

1. **Read the HTML**, then **inject test data** by regex-replacing the two assignments — this works for the demo (`= {...};`), the shipped template (token alone on the next line), and generated reports (JSON on the next line):
   ```js
   html = html.replace(/window\.ASH_META\s*=\s*[\s\S]*?;\s*\n/, `window.ASH_META = ${JSON.stringify(meta)};\n`);
   html = html.replace(/window\.ASH_DATA\s*=\s*[\s\S]*?;\s*\n/, `window.ASH_DATA = ${JSON.stringify(data)};\n`);
   ```
2. **Extract scripts**: `[...html.matchAll(/<script>([\s\S]*?)<\/script>/g)]`; the data script is the one matching `window.ASH_DATA`, the IIFE is the one matching `function render`. Do **not** strip the `(function(){…})()` wrapper — run it whole.
3. **Stub ECharts**: `echarts.init(el)` returns a fake chart whose `setOption(o)` pushes into a per-chart capture array and merges into `_last`; also stub `on('click', fn)` (capture handlers), `off`, `resize`, `getZr().on`, `dispatchAction`, and `graphic.LinearGradient`.
4. **Stub the DOM**: a `getElementById` that lazily returns fake elements with getters/setters for `textContent`/`innerHTML`/`value`, an assignable `onclick`, an `appendChild`, `addEventListener` (no-op), and — for `<select>` reads — an `options` getter returning `[{text:value}]` and a `selectedIndex`. Seed control defaults (`colorBy`, `topN`). `querySelectorAll` can return `[]`. Provide a `window` with a no-op `addEventListener`. In the ECharts stub, `setOption(o, notMerge)` must **merge series by index when `notMerge` isn't true** (like real ECharts) — the selection refresh sends a partial series and would otherwise clobber the captured series type. Also stub `convertFromPixel` (return the input, so pixel x == time in tests) and `containPixel` (return true).
5. **Run** both scripts in a `vm` context, then **assert** on captures. Useful invariants:
   - **Lanes**: `charts['chart-lanes']._last.series[0].type === 'custom'`; non-separator `yAxis.data` rows == distinct sessions appearing as waiter *or* blocker; at least one `(root)` label; both filled (`_run.filled === true`) and outlined (`false`) runs exist.
   - **Default selection**: on load the tree is rendered at the peak sample — `#treeTime` is set and the graph's node count == sessions involved at that instant.
   - **Chain isolation**: call `charts['chart-lanes'].clicks[0]` with `{data: seriesItem, event: {offsetX: tms, offsetY: 0}}` for a run that spans the peak; the tree must shrink (pick a chain that isn't the biggest, or iterate runs until it does) and `#treeChain` must say "only".
   - **Background click**: call the captured `getZr()` click handler with `{target: null, offsetX: tms, offsetY: y}` — the tree must grow back to the whole instant.
   - **Stepping**: `#treePrev`/`#treeNext` `.onclick()` moves `#treeTime` to the adjacent sample and back.
   - Tree node colors include `#e67e22` (chain-middle) when chains are ≥3 deep.

Run the same harness against **both** `reports/ash_blocking_demo.html` and `assets/template.html` (with data injected) — they must behave identically, or the two files have drifted.

### 3. Synthetic datasets (exercise variety the live seed can't)

To test multiple concurrent chains and multiple wait *classes* (colors), generate a JSON array matching the emitter's field shape and feed it to the harness or inline it into a copy of the demo. Each row needs at least: `t` (`YYYY-MM-DDTHH:MM:SS`), `inst`, `sid`, `serial`, `bInst`, `bSid`, `bSer`, `ev`, `wc`, `sqlId`, `module`/`user`/`prog`/`mach`/`action`, and the blocker-enrichment `b*` fields (`bUser`, `bMod`, `bAct`, `bProg`, `bMach`, `bSqlId`); optionally `obj` (`OWNER.OBJECT_NAME` the waiter was on) and a `meta.sqlText` map (`sql_id → text`) to exercise the object/SQL-text display. Model each chain as `{waiter, blocker, ev, wc, span:[startSampleIdx, endSampleIdx]}` and emit one row per active waiter per sample in its span; stagger spans so the lanes timeline has shape and the sample selection is meaningful. Use `wc` values that match the keys in `OEM_WAIT_CLASS` (`Application`, `Concurrency`, `Configuration`, `Cluster`, `User I/O`, …) so colors render. Avoid `Date.now()`/`Math.random()` if you want reproducible output.

### 4. Live end-to-end run (validates the SQL emitter + real ASH)

```bash
./demo/run_seed.sh            # seed Patterns A–D, wait 240s, force an AWR snapshot
                              # (./demo/run_seed.sh "/ as sysdba" 60 for a quick smoke test;
                              #  it prompts for confirmation — ASH_SEED_FORCE=1 to skip)
# copy the suggested window it prints, then:
./run_report.sh AUTO <begin> <end>   # AUTO = / as sysdba; covers all containers
```

Then **verify the real data mix** before trusting the render — extract the embedded `window.ASH_DATA` from the generated `reports/ash_blocking_<ts>.html` and tally distinct `ev`/`wc` and how many samples carry >1 wait event at once. A healthy run shows `enq: TX - row lock contention`, `enq: TM - contention`, and `enq: UL - contention` overlapping across multiple samples. If everything collapsed to a single event, a lock leaked across runs (see gotchas) — re-seed. Finally, run the level-2 harness against the generated report to confirm it renders without throwing.

**Seeding hits whatever DB the connect string targets** — it creates the `ASH_TEST` schema, holds locks for ~4 minutes, and forces an AWR snapshot. Confirm before running if that matters in your context. The jobs `auto_drop` and roll back, so no manual cleanup is needed.

## Operational gotchas

- `build_report.sql` must connect as SYSDBA in `CDB$ROOT` (or a common user with `SELECT_CATALOG_ROLE`) because `DBA_HIST_ACTIVE_SESS_HISTORY` lives there. The report reads **all containers** (no `CON_ID` filter); each emitted row still carries its own `conId`, and blocking chains never cross a container.
- The scripts are POSIX `sh` for AIX: no `set -o pipefail`, no `[[ ... ]]`/`=~` (uses `case`), no arrays. Keep them bash-free so they run under the AIX `/bin/sh` (ksh88). They rely on `sqlplus` being on `PATH` — set the Oracle env (`. oraenv`) first.
- The 100k-sample guard in `20_emit_html.sql` is a safety against running a multi-day window. Narrow the window rather than raising the limit.
- Seed jobs (`ASH_TEST.ASH_DEMO_*`) are created with `auto_drop => TRUE`; they vanish after their `DBMS_LOCK.SLEEP` completes. No cleanup step needed.
- **`SET TAB OFF` in `sql/00_settings.sql` is load-bearing.** SQL\*Plus's default `TAB ON` rewrites runs of output spaces into literal TAB characters at tab stops — an unescaped control character inside the JSON payload, which breaks `JSON.parse` in the report (bit us live: a `sqlText` snippet with two consecutive spaces). Similarly, the `#` sentinels around chunk lines exist because SQL\*Plus strips trailing whitespace from output lines. Don't remove either.
- **The stdout protocol is the contract** between `sql/20_emit_html.sql` and `run_report.sh`: marker lines, `#`-wrapped ≤500-char chunks, no-newline joining. If you change one side, change the other; the chunk size must stay ≤500 chars so AIX line-based tools never see a record over `LINE_MAX`.
- The curated `reports/ash_blocking_demo.html` is source-controlled and shares the `reports/` dir with generated reports. There is no rsync anymore, so nothing overwrites it; `run_report.sh` just prints the newest `reports/*.html`, which is the fresh build (generated reports always get a newer mtime than the committed demo).
- **Don't lock the shared `LOCK_TARGET` table in EXCLUSIVE mode** in any seed pattern — it starves the TX row-lock patterns and collapses all chains into one `enq: TM` wait. The TM pattern uses a dedicated `LOCK_TARGET_TM`.
- A prior seed run's still-sleeping sessions can cause `ORA-01940` on `DROP USER`; the seed now kills `ASH_TEST` sessions and stops `ASH_DEMO_*` jobs first. If you see a dirty schema, that teardown is where to look.
