# Offline report regressions

Run from the repository root with Node 18+ (Node's built-in test runner):

```sh
node --test tests/report.test.cjs
```

No npm install, Oracle connection, seed, browser, network request, or HTTP server
is used. The default suite injects synthetic fixtures and the existing rich demo
dataset into `assets/template.html`; it never rewrites either source file.

After the packaging workflow regenerates the checked-in demo, enable the
additional parity assertion:

```sh
ASH_TEST_DEMO_PARITY=1 node --test tests/report.test.cjs
```

To exercise another generated report's code with the same fixtures:

```sh
ASH_TEST_REPORT=/absolute/path/to/report.html node --test tests/report.test.cjs
```

`report-harness.cjs` exports `renderReport({file, meta, data, controls})` and
`embeddedData(file)`. The returned object exposes DOM elements through `get(id)`,
control changes through `change(id, value)`, captured chart options through
`charts[id]._last`, and chart events through `charts[id].emit(type, event)`.
`graph()`, `lanes()`, and `background(timestamp)` simplify common interactions.
Elements support `dispatch(type, event)`. `flushTimers()` advances pending
callbacks once, deterministically, for debounced search. This API can support
future filter, episode, and export assertions without exposing the report IIFE.

The harness executes inline scripts intact in a fresh VM per render. It parses
select/input defaults from HTML, models checked identity toggles, and merges
partial ECharts series updates by index while preserving callbacks. Fixtures
use fixed times and serial numbers. Tests inspect rendered labels, KPI/detail
HTML, graph nodes/edges, documented chart payloads, and actual event handlers.
They do not reimplement identity, chain, cadence, search, or grouping algorithms.

Coverage includes empty data, SID reuse across serials, unknown blocker serials,
ON CPU versus absent enrichment, sparse blocking observations, changing parents
and cycles, fan-in grouping/expansion/stacking, search and chain selection,
keyboard stepping, drill-down SQL evidence, and the rich demo dataset.

`node --test tests/*.test.cjs` also runs investigation regressions: combined
filters and reset, empty-scope recovery, scoped caches/search, episodes and
parent changes, weighted exports, and aggregate-only redaction. Unknown serials
must not invent blocker changes between samples. Run Python packaging tests
with `python3 -m unittest discover -s tests/packaging -v`.

This validates render logic and interaction wiring, not browser layout, canvas
painting, clipboard/fullscreen APIs, or live Oracle SQL. No browser dependency
is required. Demo parity is opt-in because generated snapshots can temporarily
lag concurrent template edits; ordinary template regressions always run.

Optional real-browser validation uses an already installed Playwright and
Chromium (no HTTP server or database):

```sh
node tests/browser-smoke.cjs
```

If Playwright is outside the project's module path, set `ASH_PLAYWRIGHT_PATH`
to that package directory; `ASH_CHROMIUM_PATH` can select an existing Chromium
executable. `ASH_BROWSER_ARTIFACTS` selects the screenshot directory (defaults
to a new temporary directory). The test opens the curated demo through `file:`,
disables network access, checks all five filters, episode selection, actual
Markdown downloads/redaction, empty-scope recovery, search/keyboard stepping,
and narrow-screen overflow. It fails on page errors or HTTP requests.
