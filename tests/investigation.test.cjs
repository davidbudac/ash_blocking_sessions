'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { renderReport } = require('./report-harness.cjs');
const f = require('./fixtures.cjs');
const render = rows => renderReport({ data: rows, meta: f.meta });
const click = (r, id) => r.get(id).dispatch('click');
function brief(r, redact) { r.get('briefRedact').checked = !!redact; click(r, 'briefDownload'); return r.get('briefText').value; }

test('exact AND filters rebuild summaries, identities, details and recover from empty', () => {
  const r = render([f.row(0, {svc: 'a', sampleWeightMs: 2500}), f.row(10, {svc: 'b', module: 'OTHER'}), f.row(20, {svc: 'a', conId: 4})]);
  assert.match(r.get('filterService').innerHTML, /value="a"/);
  r.change('filterService', 'a'); r.change('filterContainer', '3');
  assert.match(r.get('scopeCount').textContent, /^1 matching/);
  assert.match(brief(r), /seconds\): 2.5/);
  assert.doesNotMatch(r.get('sampleTableWrap').innerHTML, /OTHER/);
  assert.ok(r.graph().data.some(n => /ROOT/.test(n.name)), 'referenced blocker identity retained');
  r.change('filterModule', 'OTHER');
  assert.match(r.get('scopeCount').textContent, /^0 matching/);
  assert.match(r.get('findings').textContent, /Reset scope/);
  r.change('colorBy', 'module'); r.change('topN', '20');
  assert.match(brief(r), /Waiter rows: 0/);
  click(r, 'scopeReset');
  assert.match(r.get('scopeCount').textContent, /^3 matching/);
  assert.ok(r.lanes().data.length);
  assert.match(brief(r), /Waiter rows: 3/);
});

test('episodes separate recurrence and compare per-sample parent changes with weighted time', () => {
  const r = render([f.row(0, {sampleWeightMs: 1000}), f.row(10, {bSid: 30, bSer: 300, sampleWeightMs: 2000}), f.row(100, {sampleWeightMs: 4000})]);
  assert.match(r.get('episodeNote').textContent, /2 episode\(s\); 1 recurrence/);
  assert.match(r.get('episodeSelect').innerHTML, /1 observed parent changes/);
  r.change('episodeSelect', '0');
  const b = brief(r);
  assert.match(b, /Waiter rows: 2/); assert.match(b, /seconds\): 3/);
  assert.match(b, /Observed parent changes: 1/);
  assert.match(b, /Investigation SQL/); assert.match(b, /Evidence rows: 1/);
  assert.match(r.get('scopeCount').textContent, /episode 1/);
  r.change('episodeSelect', '1'); assert.match(brief(r), /seconds\): 4/);
  click(r, 'episodeClear'); assert.match(brief(r), /Waiter rows: 3/);
});

test('export honors combined scope and redaction uses aggregate allowlist only', () => {
  const secret = 'PRIVATE_<>&"';
  const r = render([f.row(0, {module: secret, svc: secret, user: secret, obj: secret, sqlId: secret, client: secret, mach: secret}), f.row(10, {module: 'OTHER'})]);
  assert.match(r.get('filterModule').innerHTML, /PRIVATE_&lt;&gt;&amp;&quot;/);
  r.change('filterModule', secret); r.change('filterService', secret);
  assert.match(brief(r), /Waiter rows: 1/);
  const redacted = brief(r, true);
  assert.match(redacted, /REDACTED: aggregate-only/);
  for (const value of [secret, 'SYNTHETIC', '2026-', 'DBA_HIST', 'waitsql', 'APP.ORDERS', '20,200']) assert.ok(!redacted.includes(value), value);
  assert.doesNotMatch(redacted, /```/);
});

test('unknown serial references do not invent observed parent changes', () => {
  const r = render([f.row(0, { bSer: null }), f.row(10, { bSer: null }), f.row(20, { bSer: 100 })]);
  assert.match(brief(r), /Observed parent changes: 0/);
  const changed = render([f.row(0, { bSer: null }), f.row(10, { bSid: 99, bSer: null })]);
  assert.match(brief(changed), /Observed parent changes: 1/);
});

test('stack membership and separate session search refresh after filtering', () => {
  const r = render(f.fanIn);
  r.change('laneStack', 'always');
  r.get('sessSearch').value = 'FANIN'; r.get('sessSearch').dispatch('input'); r.flushTimers();
  r.change('filterModule', 'OTHER');
  assert.match(r.get('scopeCount').textContent, /^3 matching/);
  assert.equal(r.get('sessMatch').textContent, '0 sessions match');
  const runs = r.lanes().data.filter(d => d._run).map(d => d._run);
  assert.ok(runs.every(run => !run.stack), 'excluded fan-in stack cache discarded');
  click(r, 'scopeReset');
  assert.match(r.get('sessMatch').textContent, /6 sessions match/);
  assert.match(r.get('scopeCount').textContent, /^21 matching/);
});
