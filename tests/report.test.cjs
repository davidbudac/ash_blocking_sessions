'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { renderReport, embeddedData, TEMPLATE, merge } = require('./report-harness.cjs');
const f = require('./fixtures.cjs');
const file = process.env.ASH_TEST_REPORT ? path.resolve(process.env.ASH_TEST_REPORT) : TEMPLATE;
const render = (data, controls = {}, meta = f.meta) => renderReport({ file, data, meta, controls });
const names = r => r.graph().data.map(n => n.name).join('\n');
const laneSessions = r => new Set(r.lanes().data.filter(d => d._run).map(d => d._run.sid));
const text = html => html.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim();
function kpi(r, label) {
  const pairs = Array.from(r.get('kpis').innerHTML.matchAll(/class="num">([^<]*)<\/div>\s*<div class="lbl">([^<]*)/g));
  const pair = pairs.find(m => m[2].includes(label));
  assert.ok(pair, 'KPI should exist: ' + label);
  return pair[1];
}

test('capture merges partial series like ECharts without losing render callbacks', () => {
  const fn = () => {};
  const result = merge({ series: [{ type: 'custom', renderItem: fn, data: [1] }] }, { series: [{ data: [2] }] });
  assert.equal(result.series[0].type, 'custom');
  assert.equal(result.series[0].renderItem, fn);
  assert.deepEqual(result.series[0].data, [2]);
});

test('empty data renders a useful empty state without initializing charts', () => {
  const r = render([]);
  assert.match(r.get('chart-lanes').innerHTML, /No blocking samples/i);
  assert.match(r.get('findings').innerHTML, /no blocking/i);
  assert.equal(Object.keys(r.charts).length, 0);
});

test('reused instance/SID retains distinct serial identities and labels', () => {
  const r = render([f.row(0, { module: 'OLD_SESSION' }), f.row(10, { serial: 201, module: 'NEW_SESSION' })], { laneStack: 'never' });
  assert.equal(kpi(r, 'Waiting sessions'), '2');
  assert.equal(laneSessions(r).size, 3, 'two incarnations plus one root');
  r.get('treeNext').dispatch('click');
  assert.match(names(r), /NEW_SESSION/);
  assert.doesNotMatch(names(r), /OLD_SESSION/);
});

test('unknown blocker serial is explicit and never merged with known incarnations', () => {
  const unknown = f.row(0); delete unknown.bSer;
  const r = render([unknown, f.row(10), f.row(20, { bSer: 101 })], { laneStack: 'never' });
  assert.equal(kpi(r, 'Blocking sessions'), '3');
  assert.equal(laneSessions(r).size, 4, 'one waiter and three distinct blocker identities');
  assert.match(text(r.get('sampleTableWrap').innerHTML), /unknown|serial[^.]{0,35}\?/i);
});

test('ON CPU enrichment is positive activity evidence, never an idle verdict', () => {
  const r = render([f.row(0, { bState: 'ON CPU', bSqlId: 'rootsql' })]);
  const findings = text(r.get('findings').innerHTML);
  assert.match(findings, /ON CPU/i);
  assert.doesNotMatch(findings, /was idle|likely an uncommitted transaction/i);
  assert.match(text(r.get('sampleTableWrap').innerHTML), /ON CPU/i);
});

test('missing blocker evidence is uncertainty rather than proof of idleness', () => {
  const r = render([f.row(0)]);
  const findings = text(r.get('findings').innerHTML);
  assert.match(findings, /not sampled|not captured|unknown|no .*evidence|absent/i);
  assert.doesNotMatch(findings, /was idle|likely an uncommitted transaction/i);
});

test('sparse blocking observations do not turn a long gap into blocked duration', () => {
  const r = render([f.row(0), f.row(600)], { laneStack: 'never' });
  // Historical ASH coverage is nominally 10 seconds per observation, not the
  // distance between the only two blocking timestamps in the entire window.
  assert.equal(kpi(r, 'Blocked session-time'), '20s');
  const waiting = r.lanes().data.filter(d => d._run && d._run.filled);
  const widths = waiting.map(d => d.value[2] - d.value[1]);
  assert.ok(widths.every(ms => ms <= 10000), 'each sparse cell must represent at most one sample');
});

test('explicit row weights determine blocked time independently of cell cadence', () => {
  const r = render([f.row(0, { sampleWeightMs: 15000 }), f.row(10, { sampleWeightMs: 5000 })]);
  assert.equal(kpi(r, 'Blocked session-time'), '20s');
  const fallback = render([f.row(0, { usecsPerRow: 1200000 })], {}, Object.assign({}, f.meta, { sampleWeightFactor: 10 }));
  assert.equal(kpi(fallback, 'Blocked session-time'), '12s');
});

test('ON CPU overrides a stale event name in blocker evidence', () => {
  const r = render([f.row(0, { bState: 'ON CPU', bEv: 'db file sequential read' })]);
  assert.match(text(r.get('findings').innerHTML), /ON CPU/);
  assert.doesNotMatch(text(r.get('findings').innerHTML), /waiting: db file sequential read/);
});

test('selected-sample topology follows changing parents and survives cycles', () => {
  const r = render(f.changing, { treeGroup: 'off' });
  assert.equal(r.graph().data.length, 3);
  assert.ok(r.graph().data.some(n => n.itemStyle.color === '#e67e22'), 'middle session both waits and blocks');
  const first = r.get('treeTime').textContent;
  r.get('treeNext').dispatch('click');
  assert.notEqual(r.get('treeTime').textContent, first);
  assert.equal(r.graph().data.length, 2);
  assert.match(names(r), /1:30/);
  assert.doesNotMatch(names(r), /1:5\b/);
  r.get('treeNext').dispatch('click');
  assert.equal(r.graph().data.length, 2, 'cycle contains each session once');
  assert.equal(r.graph().links.length, 2, 'both sampled cycle edges remain visible');
  r.get('treePrev').dispatch('click');
  assert.match(names(r), /1:30/);
});

test('fan-in grouping expands, search rings matches, selection isolates and resets', () => {
  const r = render(f.fanIn);
  const grouped = r.graph().data.find(n => /×6/.test(n.name));
  assert.ok(grouped, 'six sibling waiters should form one visible group');
  assert.equal(r.graph().data.length, 4);
  r.charts['chart-tree'].emit('click', { dataType: 'node', data: grouped });
  assert.equal(r.graph().data.length, 9, 'group click expands all six waiters');
  assert.match(text(r.get('sampleTableWrap').innerHTML), /FANIN/);
  r.get('sessSearch').value = 'OTHER';
  r.get('sessSearch').dispatch('input'); r.flushTimers();
  assert.match(r.get('sessMatch').textContent, /1 session/);
  assert.ok(r.graph().data.some(n => n.itemStyle.borderColor === '#f1c40f'), 'matching node receives search ring');
  r.get('sessSearch').dispatch('keydown', { key: 'Enter' });
  assert.equal(r.graph().data.length, 2, 'search Enter isolates the matching chain');
  assert.match(text(r.get('treeChain').innerHTML), /only/i);
  const summary = r.get('kpis').innerHTML;
  r.background(new Date(f.time(0)).getTime());
  assert.equal(r.graph().data.length, 9);
  assert.equal(r.get('kpis').innerHTML, summary, 'selection keeps whole-window findings');
  assert.equal(r.lanes().type, 'custom', 'partial selection refresh preserves custom renderer');
  r.get('sessSearch').value = ''; r.get('sessSearch').dispatch('input'); r.flushTimers();
  assert.equal(r.get('sessMatch').textContent, '');
  assert.ok(r.graph().data.every(n => n.itemStyle.borderColor !== '#f1c40f'));
});

test('timeline click isolates a chain; background restores all; keyboard steps preserve isolation', () => {
  const r = render(f.fanIn);
  const lane = r.lanes().data.find(d => d._run && d._run.samples.some(s => s.module === 'OTHER'));
  assert.ok(lane);
  r.charts['chart-lanes'].emit('click', { data: lane, event: { offsetX: new Date(f.time(0)).getTime(), offsetY: 0 } });
  assert.equal(r.graph().data.length, 2);
  const before = r.get('treeTime').textContent;
  r.get('treePanel').dispatch('keydown', { key: 'ArrowRight', target: { tagName: 'SECTION' } });
  assert.notEqual(r.get('treeTime').textContent, before);
  assert.equal(r.graph().data.length, 2);
  const after = r.get('treeTime').textContent;
  r.get('treePanel').dispatch('keydown', { key: 'ArrowRight', target: { tagName: 'INPUT' } });
  assert.equal(r.get('treeTime').textContent, after, 'typing in search must not step the sample');
  r.background(new Date(f.time(10)).getTime());
  assert.equal(r.graph().data.length, 4);
});

test('stacking conserves fan-in membership and node drill-down includes downstream SQL evidence', () => {
  const r = render(f.fanIn, { laneStack: 'always' });
  const stack = r.lanes().data.find(d => d._run && d._run.stack);
  assert.ok(stack);
  assert.equal(stack._run.stack.members.length, 6);
  const root = r.graph().data.find(n => n._node && n._node.isBlocker && !n._node.isWaiter && /ROOT/.test(n.name));
  r.charts['chart-tree'].emit('click', { dataType: 'node', data: root });
  const details = r.get('sampleTableWrap').innerHTML;
  for (const required of [/CONNECT BY NOCYCLE/i, /HEXTORAW\(/, /DBMS_ROWID\.ROWID_CREATE/, /dba_hist_sqltext/i, /ct-hint/, /APP.ORDERS/, /waitsql/]) assert.match(details, required);
});

test('rich checked-in demo data renders through the current template', () => {
  const demo = embeddedData(path.resolve(__dirname, '../reports/ash_blocking_demo.html'));
  assert.ok(demo.data.length > 100, 'fixture should remain representative');
  const r = render(demo.data, {}, demo.meta);
  assert.equal(r.lanes().type, 'custom');
  assert.ok(r.graph().data.length > 5);
  assert.ok(r.lanes().data.some(d => d._run && d._run.filled));
  assert.ok(r.lanes().data.some(d => d._run && !d._run.filled));
  assert.match(r.get('findings').innerHTML, /windowSql/);
  assert.ok(!/NaN|Invalid Date/.test(r.get('kpis').innerHTML + r.get('treeTime').textContent));
});

// Enable after regenerating the checked-in demo. Template behavior remains the
// default test target while generated assets are being updated concurrently.
test('regenerated demo and injected template expose identical render output', { skip: !process.env.ASH_TEST_DEMO_PARITY }, () => {
  const demoFile = path.resolve(__dirname, '../reports/ash_blocking_demo.html');
  const fixture = embeddedData(demoFile);
  const a = renderReport({ file: TEMPLATE, ...fixture });
  const b = renderReport({ file: demoFile, ...fixture });
  for (const id of ['kpis', 'findings', 'treeTime', 'treeStat', 'treeChain', 'sampleSel', 'sampleTableWrap', 'laneNote']) {
    assert.equal(a.get(id).innerHTML, b.get(id).innerHTML, id + ' HTML');
    assert.equal(a.get(id).textContent, b.get(id).textContent, id + ' text');
  }
  // JSON compares public chart payloads across VM realms and omits callbacks.
  for (const id of Object.keys(a.charts)) assert.equal(JSON.stringify(a.charts[id]._last), JSON.stringify(b.charts[id]._last), id);
});
