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

Edit `assets/template.html` as the source of truth. Run `./scripts/regenerate-demos.sh` to regenerate both curated demos from `scripts/demo-fixture/*.chunks`. Run the checked-in Node report tests and Python packaging tests described below. No database is needed for this development loop; do not hand-edit generated demos.

## How a report is produced

1. **`run_report.sh`** `cd`s to its own directory and runs `sqlplus -S -L <connect_string> @build_report.sql <begin> <end>` (connect string is arg 1; default `/ as sysdba`), capturing **all stdout** into `reports/.build.$$/out.log`. A named user must be a **common** user connected to `CDB$ROOT` with `CREATE SESSION` and `SELECT_CATALOG_ROLE` — nothing else; there are no directory objects and no DDL anywhere in the report path.
2. **`build_report.sql`** is the driver. It sources `sql/00_settings.sql` (non-interactive SQL*Plus settings, NLS formats, `WHENEVER SQLERROR EXIT FAILURE`, and **`SET TAB OFF`** — see gotchas), defines the two positional args (`begin_time`, `end_time`), then sources `sql/20_emit_html.sql`.
3. **`sql/20_emit_html.sql`** is the core PL/SQL block. It:
   - Counts blocking samples in the window. Refuses to render if `> 100000` (raises `-20001`).
   - Builds the data CLOB with `JSON_ARRAYAGG(JSON_OBJECT(... ABSENT ON NULL ... RETURNING CLOB))`. The query **left-joins `DBA_HIST_ACTIVE_SESS_HISTORY` to itself** on `(dbid, snap_id, sample_id, blocking_inst_id, blocking_session, blocking_session_serial#)` to enrich each row with what the blocker was doing in the same sample (fields prefixed `b*`: `bEv`, `bSqlId`, `bMod`, `bAct`, `bProg`, `bMach`, `bUser`, …). Usernames and the waiter's contended object (`obj`, from `CURRENT_OBJ#`) come from **`CDB_USERS`/`CDB_OBJECTS` joined on `(con_id, id)`** — the plain `DBA_*` views in `CDB$ROOT` can't see PDB users/objects, so don't "simplify" those joins back. The meta JSON additionally carries `sqlText`, a `sql_id → first-200-chars` map (from `DBA_HIST_SQLTEXT`) for every SQL (and top-level SQL) that ran in the window, so the report can show statement text offline (`sqlSnip()` in the template; degrades gracefully when absent).
   - **Root-cause fields** (all `ABSENT ON NULL`, every one optional on the client): per waiter `snapId`/`sampleId` (locators for the generated SQL), `sessType`, `state`, `sqlOp`, `sqlExec`, `phv`, `topSql` (only when ≠ `sqlId`), `plsql` (`OWNER.PKG.PROC` via **`CDB_PROCEDURES` on `(con_id, plsql_entry_object_id, plsql_entry_subprogram_id)`**), `xid` (`RAWTOHEX`), `p1t/p1/p2t/p2/p3t/p3`, `dObj` (data_object_id of `obj`, for `DBMS_ROWID.ROWID_CREATE`), `curFile/curBlock/curRow`, `tw` (time_waited µs), `client`, `svc` (via `DBA_HIST_SERVICE_NAME` on `(dbid, service_name_hash)`), `hang`, `inPlsql`, `inParse`; and the blocker-side mirrors `bSessType`, `bSqlOp`, `bSqlExec`, `bPhv`, `bTopSql`, `bPlsql`, `bXid`, `bObj`, `bP1t..bP3`, `bClient`, `bSvc`, `bInPlsql`.
   - **Prints** both CLOBs to stdout via `DBMS_OUTPUT` between marker lines (`__META_JSON_BEGIN__/END__`, `__DATA_JSON_BEGIN__/END__`). Each chunk line is `#<≤500 chars>#` — the `#` sentinels protect leading/trailing whitespace from SQL\*Plus line trimming (a chunk ending in a space silently loses it otherwise; this corrupted event names in testing). 500 chars keeps every line under POSIX `LINE_MAX` even at 4-byte UTF-8, so AIX awk never sees an over-long record. Chunk boundaries can fall **mid-token**; the client joins them with NO newlines (safe because JSON generation escapes control characters, so the payload has no literal newlines). It touches **no server-side files**: no BFILE, no directory objects, no `CLOB2FILE`.
4. **`run_report.sh`** validates literal timestamp arguments before SQL*Plus substitution, captures stdout and invokes `scripts/split-protocol.awk` to validate and split the marker/sentinel protocol. `scripts/assemble-report.sh` validates exact placeholder/tag occurrence counts, safely embeds JSON and reconstructs the pinned ECharts vendor from short records. It writes the assembled temporary report to a new `.html` basename using exclusive noclobber redirection; existing destinations (including directories/symlinks) are rejected. This copy is not atomic and an interrupted copy can leave a partial output. AUTO names contain timestamp and PID. `PACKAGING.md` is the detailed contract.

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

Single HTML file, one IIFE, ECharts 5.5.0 embedded by assembly. The pinned CDN tag in the source template is an assembly marker, replaced with the licensed vendored code; generated reports make no runtime fetches. See `PACKAGING.md` for the framing and embedding contract. Data arrives at load time via:

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

1. **Identity + root-cause helpers**: `colorKey(d)`, `waiterKey(d)`, `blockerKey(d)` derive the per-row category for color/grouping. `enqInfo(ev, p1, p2, p3)` decodes `enq: XX` parameters (lock type, requested mode via `ENQ_MODE`, and the resource — `TX-usn.slot.seq` for TX, `object_id` for TM, lock id for UL); `rootCauseHint(row)` turns event + mode + blocker activity evidence into a one-line heuristic hint (TX mode 6 = row lock / uncommitted txn, TX mode 4 = unique-key/ITL/bitmap, TM = LOCK TABLE/DDL/unindexed FK, UL = DBMS_LOCK, buffer busy, library cache, gc, …). `sqlForSample(samples, t)` / `sqlForWindow()` generate the copy-paste `SELECT *` scripts (blocking tree via `CONNECT BY NOCYCLE` over a `WITH a AS (…)` slice of `DBA_HIST_ACTIVE_SESS_HISTORY` at `sample_time ±1s` + `snap_id`, chain sessions by `(instance_number, session_id, session_serial#) IN (…)`, root-blocker history over the window, `xid IN (HEXTORAW(…))`, `DBA_HIST_SQLTEXT`, and `DBMS_ROWID.ROWID_CREATE(1, dObj, curFile, curBlock, curRow)` row lookups); `sqlBoxHtml()`/`wireCopyButtons()` render them with a Copy button. Keep the application script compatible with Node 12 syntax (no optional chaining); the checked-in test runner itself requires Node 18+. `buildIdentityCache()` walks the dataset once, picks the *dominant* (most-frequent) value of each identifier (`user`, `prog`, `module`, `action`, `mach`, plus `svc`, `client`, `sessType` for tooltips) per SID, considering both the waiter row and the enriched blocker fields (`bUser`, `bProg`, `bMod`, `bAct`, `bMach`) — this is how a session that only appears as a blocker still gets a label. `decorateSidLabel(sid)` appends the user-selected identifier toggles to a SID for display; the **`user` and `module` toggles default to checked** so charts are readable without discovering the toggles. `SAMPLE_MS` is bounded explicit cadence (10s fallback), never derived from blocking-only gaps. `sampleWeightMs()` / `blockedMs()` use emitted row weights for estimated blocked session-time; older reports assume 10s per row. Keys include instance, SID and serial; unresolved blocker serials remain sample-local and explicit.
2. **OEM color palette**: `OEM_WAIT_CLASS` maps wait classes to OEM Top Activity colors. For event-mode coloring, `oemColorForKey()` first looks the event up in `OEM_WAIT_EVENT` — a curated table of OEM-style colors for common specific events (reds = Application, blues = I/O, maroons = Concurrency, purples = Configuration, yellows = Cluster, …), each a distinct shade within its class family. Events not in the table fall back to `spreadWithinClass()`, which rotates hue and varies lightness/saturation deterministically (`hexToHsl`/`hslToHex` + `strHash01`) so siblings in the same class stay clearly distinct rather than near-identical. (`shiftLightness()` is the older, subtler helper, now unused by event mode.)
3. **Scope-level chain structure** (`CHAIN`, rebuilt after filter/episode changes): each SID's *dominant* (most-frequent) blocker across the whole window, walked to its ultimate root with a cycle guard → `sidInfo` (root/depth/activity per SID), `groups` (root → members), `rootOf(sid)`. This is deliberately window-level, not per-instant: per-instant parents can flap between samples, and both the lane grouping and "isolate this chain" need one stable answer. `allTs` (sorted distinct sample times) + `snapT(t)` snap any x-coordinate to a real ASH sample; `peakT` is the sample with the most distinct blocked sessions.
4. **Key-findings summary + the two panels**, each in its own `render*()` function:
   - `renderSummary()` — computes window-level KPIs (blocked samples, ≈ blocked session-time, waiting/blocking session counts, distinct chains, deepest chain depth, peak concurrent waiters) into `#kpis` and auto-generated finding sentences into `#findings`: top root with session-time, **blocker activity evidence** (`ON CPU` takes precedence over a stale event; missing enrichment is unknown), first/last observations, and an explicit statement that observations do not establish resolution or continuous activity. Runs on the current investigation scope (waiter filters plus optional episode), independent of the selected sample/chain.
   - `renderLanes()` — **the primary chart**: a custom-series Gantt with one lane per session that ever waited *or* blocked, grouped by chain (◆ root first, members indented by depth, separator rows between chains), busiest chains first until the `#topN` "Max lanes" cap (whole chains only — never split one across the cap; `#laneNote` reports hidden chains). **Stacked lanes (`#laneStack`: auto/always/never):** `laneStacks()` finds window-level groups of 3+ *pure waiters* (never a blocker) with the same dominant blocker (`CHAIN.parentOf`), `identityFor()` module/action and dominant wait event (key via `groupKey()`, shared with the tree's aggregates); a stack is ONE lane labelled `↳ ×N module/action` (rich style `stack`) where its first member would sit. `renderLanes()` runs `layoutLanes(stackOn)`: **auto** lays out unstacked first and re-lays out with stacking only if the cap hid a chain, **always**/**never** apply it directly (so output is byte-identical to the pre-stacking chart whenever nothing is stacked); the cap counts lanes, and `#laneNote` says how many waiters were stacked. A stack cell is one per sample with ≥1 member waiting: colour = dominant `colorKey` of that sample, bottom-anchored height ∝ waiting/total (min 30%), runs coalesce only on equal count+colour, tooltip "N of M waiting" + first 10 SIDs; its run carries `stack` (members) and `sid` = first member. Click → `rootOf(sid)` like any cell; chain isolation and search dim via `laneHit()` (a stack matches if any member does). Cells are per-ASH-sample; adjacent same-state samples coalesce into runs. **Filled cell** = waiting (color = `colorKey`), **outlined** = blocking-only (holding a lock), filled + dark stroke = both at once. Container height grows with lane count (`interval: 0` on the y-axis — never let ECharts auto-skip labels, it makes lanes look dropped). Clicks: **a cell** → `applySelection(snapT(clickX), rootOf(sid))` (focus that sample + isolate that chain); **empty plot space** (a `getZr()` click with no target, wired once via `laneClickWired`) → `applySelection(snapT(x), null)` (whole instant).
   - `renderTreePanel()` — deterministic layered (tidy-tree) chain map at the **selected sample** (`selectedT`), optionally filtered to the selected chain. Header shows `#treeTime`/`#treeStat`, `#treeChain` (isolation state + "show all chains" link) and `#treePrev`/`#treePlay`/`#treeNext` which step the selection through `allTs`. Edges draw waiter → blocker; **edge event labels show on hover only** (always-on labels collide at fan-in). Three node categories: blue "waiter", orange `#e67e22` "blocks & waits" (use the literal, not a CSS var, since canvas can't resolve it), red "root blocker". Node size ∝ √(downstream impact). **Clicking a node shows its own + all transitively downstream samples**, so a pure root blocker drills to its whole chain instead of "No samples". `XGAP` widens when identity toggles are active. **Keyboard:** `#treePanel` (the `<section>`, `tabindex=0`) has one `keydown` listener — ArrowLeft/ArrowRight call `#treePrev`/`#treeNext`'s `.onclick()` (chain isolation kept; stops auto-play first via `treeStopPlay`; ignores SELECT/INPUT/TEXTAREA targets and ctrl/meta/alt); a `mousedown` on `#chart-tree` focuses the panel since the canvas can't take focus. The layout is a pure `layoutTree(R)` that yields abstract (depth-axis, cross-axis) slots, mapped to pixels by `mapPos()`: a parent with more than `R` leaf children packs them into `ceil(n/R)` blocks along the depth axis (odd blocks offset half a slot); `R` is auto-picked from a ladder to maximise the fit scale of the *mapped* pixel box in `#chart-tree`'s size (`#treeWrap` = "No wrap" forces `R=∞`), and the `ResizeObserver` re-runs it (debounced) while the user hasn't zoomed/panned. **`#treeOrient`** picks the mapping: "Left → right" (default; depth on x via `XGAP`, siblings on y via `YGAP`, wrapped blocks are columns — positions identical to the original layout) or "Top → down" (depth on y via `DGAP`, siblings on x via `HGAP`, wrapped blocks are rows stacked downward; labels sit below leaves / right of parents, truncated to `HGAP-14`). `#treeWrap`/`#treeOrient`/`#treeGroup` changes reset zoom/centre and re-render.
   **Group similar waiters (`#treeGroup`, default on):** after `childrenOf` is built, 3+ sibling *leaf* waiters (no kids, not a blocker, one edge) under the same parent with the same dominant `module/action` (`identityFor()`) and edge event collapse into one aggregate node (`_node.agg`, `members`, summed `samples` ⇒ summed impact/edge; drawn as a stacked-cards `path://` symbol — front card plus two offset cards peeking out top-right, `symbolKeepAspect`, min size 28, waiter colour, darker `#1a5276` border (the `#f1c40f` search ring and fading still take precedence); rich-text label with a bold larger `×N` then `· module/action · event`; tooltip ends `Click to expand into N sessions`; own 4th legend category "similar waiters (stacked)", shown only when an aggregate is on screen). Aggregates are plain leaves to the layout, so they wrap like any leaf. Clicking one adds its key (`parent|module/action|event`) to the module-level `expandedGroups` Set (survives sample stepping) and calls `showSamples()` with the members' samples; a "re-group N" link in `#treeChain` clears the set. Real nodes' clicks/tooltips/edge tooltips are unchanged. **Sizing:** once at init `#chart-tree` gets `clamp(480, 200 + 14·maxNodes, 0.85·innerHeight)` px, `maxNodes` = most distinct sessions (waiters ∪ blockers, from `sessAtT`) at any one sample — computed once so stepping never jumps; CSS `resize: vertical` still works. **Full screen (`#treeFull`):** `requestFullscreen`/`webkitRequestFullscreen` on `#treePanel`, else a fixed overlay (`.tree-overlay`; button or Esc leaves it); both add `.tree-fs`, whose CSS makes the panel a white flex column so `#chart-tree` fills what the header/footnote leave (`height:auto !important`, so the inline height is untouched and "restored" for free). Enter/exit does `treeChart.resize()` + zoom reset + `renderTreePanel()` to re-fit; the panel keeps focus so ←/→ still work, and the Esc listener is a separate `document` keydown.
5. **Selection model** (`applySelection(t, root)` / `selectedSamples()` / `updateBanner()`): module-level `selectedT` (focused sample_time, defaults to `peakT` on load — never null after init) and `selectedRoot` (chain to isolate, or null for all). `applySelection` re-feeds the lanes chart via `refreshLanesSelection()` — a merge-mode `setOption` that re-sends the same run data (so `renderItem` re-runs and out-of-chain lanes dim) and moves the focus band **without resetting the user's zoom** — then re-renders the tree, the `#sampleSel` banner (with "All chains" / "Jump to peak" buttons), and the `#sampleTableWrap` detail (`showSamples()`: the blocker → waiter forest with per-session identity / session facts / SQL / lock-transaction lines and a `.ct-hint` root-cause line, the collapsible flat table, and a collapsible **"SQL to look at this sample yourself"** box from `sqlForSample()`). `renderSummary()` likewise ends with a collapsible window-level SQL box (`sqlForWindow()`) and a "Root-cause pointers" line (dominant enqueue/mode/object of the top root's waiters + blocker XID / PL/SQL entry / service / client).
6. **Session search (`#sessSearch` + `#sessMatch`, in the controls bar):** `searchSids` (module-level Set of matching session keys, or `null` when empty) is filled by `computeSearch()` — case-insensitive substring of the SID key, any `identityFor()` field, or any `sqlId`/`bSqlId` the session ran — after a 150ms debounce. Lanes read it in `renderItem` (non-matches dim like out-of-chain lanes, combined with `selectedRoot`) and in `lanesYFormatter()` (`hit`/`miss` rich styles on the y labels), applied via the merge-mode `refreshLanesSelection()` (a fresh formatter closure each time so labels redraw) so zoom is kept. The tree rings matching nodes (`borderColor '#f1c40f'`, width 4; an aggregate matches if any member does) and fades the rest and their edges to 0.25. **Enter** jumps (`jumpToMatch()`) to the first sample at/after `selectedT` (wrapping, using `sessAtT`) involving a match via `applySelection(t, rootOf(sid))`; repeating Enter on the same sample moves strictly past it. The panel's ←/→ handler still ignores INPUT targets.
7. **Investigation scope and incident export**: `sourceRows` retains all samples; native exact AND filters (`filterContainer/Service/Module/Object/Sql`) match waiter fields only. `rebuildScope()` stops playback, rebuilds time/session/chain/identity/search/stack/color caches, resets selection and redraws all charts. Referenced blocker enrichment remains context; unmatched waiter edges are excluded. `scopeReset` clears filters and episode restrictions, while the separate Find control remains highlighting. Zero matches clear the views and recover on reset. An initially empty report disables investigation controls.
   `makeEpisodes()` separates observed bursts at gaps greater than twice the bounded cadence; it records weighted session-time, peak distinct waiters and per-sample parent changes. Unknown serials alone do not count as a change. `episodeSelect` restricts scope, `episodeClear` restores all episodes within filters. These are sampled bursts, not proven continuous incidents or resolution.
   `incidentBrief()` downloads plain Markdown via Blob and also fills `briefText`. It includes current scope totals and selected sample/chain evidence plus SQL. Window SQL is explicitly a broader retrieval starting point. `briefRedact` uses an aggregate-only allowlist, omitting all identifiers, timestamps, SQL and descriptive fields, rather than trying to redact arbitrary SQL literals.
8. **`renderAll()`** wires the summary and panels to controls (`#colorBy`, `#topN`, `#laneStack`, `#idToggles`); full `renderLanes()` re-runs (which do reset zoom) happen only on control changes, not on selection.

When changing the template:
- Preserve the two placeholders `__META_JSON__` and `__DATA_JSON__` verbatim, **each alone on its own line** — `run_report.sh` does a line-based splice (the emitter no longer substitutes anything server-side).
- If you add a new field to the chart data, also add it to the `JSON_OBJECT(...)` in `sql/20_emit_html.sql`.
- `assets/template.html` is the source of truth the emitter loads at build time. `reports/ash_blocking_demo.html` and `docs/demo.html` are generated snapshots. Regenerate both from the maintained fixtures; never mirror edits from generated HTML back to the template.

## Testing the report

Use local tests for iteration. Live SQL and platform compatibility remain separate validation boundaries.

### 1. Regenerate and inspect

```sh
./scripts/regenerate-demos.sh
open reports/ash_blocking_demo.html
```

The maintained synthetic fixture is `scripts/demo-fixture/meta.chunks` plus
`data.chunks` (join records without newlines to parse). It contains nine chains,
five wait classes, root-cause evidence and a large fan-in for grouping/stacking.
Both generated demos must be byte-identical. Keep the source template's pinned
ECharts tag and each JSON placeholder exactly once; assembly embeds ECharts and
escapes JSON less-than characters safely across chunk boundaries.

### 2. Checked-in headless regression harness

```sh
node --test tests/*.test.cjs
ASH_TEST_DEMO_PARITY=1 node --test tests/report.test.cjs
```

Node 18+ is a development dependency only. `tests/report-harness.cjs` executes
the report with a stubbed DOM/ECharts boundary, including event handlers and
partial chart option merges. See `tests/README.md` for the harness API. Fixtures
cover SID reuse, absent/ambiguous serials, CPU/unknown activity, sparse samples,
changing chains, cycles, fan-in, search, keyboard stepping and drill-down SQL.
The harness tests application behavior, not real canvas layout or browser APIs.
Use a real browser for layout and interaction checks after UI changes.

### 3. Packaging and shell checks

```sh
python3 -m unittest discover -s tests/packaging -v
sh -n run_report.sh scripts/assemble-report.sh scripts/regenerate-demos.sh
```

Packaging tests use isolated temporary directories and fake SQL*Plus. They
cover framing, Unicode/whitespace, split script terminators, timestamp grammar,
placeholder counts, output collision/race rejection and deterministic demos.
No real connection or seed is used. Production requires only SQL*Plus, POSIX
shell, awk and ordinary Unix utilities; Node/Python are not runtime dependencies.
See `PACKAGING.md` for vendor provenance, commands and limitations.

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
- **There is no Oracle instance on this dev machine** (no `sqlplus`, no listener). The emitter SQL can only be validated on the user's DB host — after changing `sql/20_emit_html.sql`, say so explicitly and hand over the `demo/run_seed.sh` + `run_report.sh` commands rather than claiming it ran.
- The 100k-sample guard in `20_emit_html.sql` is a safety against running a multi-day window. Narrow the window rather than raising the limit.
- Seed jobs (`ASH_TEST.ASH_DEMO_*`) are created with `auto_drop => TRUE`; they vanish after their `DBMS_LOCK.SLEEP` completes. No cleanup step needed.
- **`SET TAB OFF` in `sql/00_settings.sql` is load-bearing.** SQL\*Plus's default `TAB ON` rewrites runs of output spaces into literal TAB characters at tab stops — an unescaped control character inside the JSON payload, which breaks `JSON.parse` in the report (bit us live: a `sqlText` snippet with two consecutive spaces). Similarly, the `#` sentinels around chunk lines exist because SQL\*Plus strips trailing whitespace from output lines. Don't remove either.
- **The stdout protocol is the contract** between `sql/20_emit_html.sql` and `run_report.sh`: marker lines, `#`-wrapped ≤500-char chunks, no-newline joining. If you change one side, change the other; the chunk size must stay ≤500 chars so AIX line-based tools never see a record over `LINE_MAX`.
- The curated `reports/ash_blocking_demo.html` is source-controlled and shares the `reports/` dir with generated reports. There is no rsync anymore, so nothing overwrites it; `run_report.sh` prints the exact new report path and refuses to overwrite existing files or the curated demo.
- **Don't lock the shared `LOCK_TARGET` table in EXCLUSIVE mode** in any seed pattern — it starves the TX row-lock patterns and collapses all chains into one `enq: TM` wait. The TM pattern uses a dedicated `LOCK_TARGET_TM`.
- A prior seed run's still-sleeping sessions can cause `ORA-01940` on `DROP USER`; the seed now kills `ASH_TEST` sessions and stops `ASH_DEMO_*` jobs first. If you see a dirty schema, that teardown is where to look.
