'use strict';
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const TEMPLATE = path.resolve(__dirname, '../assets/template.html');

function merge(a, b) {
  if (!b || typeof b !== 'object' || Array.isArray(b)) return b;
  const out = Object.assign({}, a);
  for (const k of Object.keys(b)) {
    // ECharts merges series by index; data and other arrays replace atomically.
    out[k] = k === 'series' && Array.isArray(b[k])
      ? Array.from({ length: Math.max(b[k].length, a && a[k] ? a[k].length : 0) }, (_, i) => i < b[k].length ? merge(a && a[k] && a[k][i], b[k][i]) : a[k][i])
      : b[k] && typeof b[k] === 'object' && !Array.isArray(b[k]) ? merge(a && a[k], b[k]) : b[k];
  }
  return out;
}
function embeddedData(file) {
  const html = fs.readFileSync(file, 'utf8');
  const script = Array.from(html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi), m => m[1]).find(s => /window\.ASH_DATA\s*=/.test(s));
  const context = { window: {} };
  vm.runInNewContext(script, context, { timeout: 1000 });
  return { meta: context.window.ASH_META, data: context.window.ASH_DATA };
}
function renderReport({ file = TEMPLATE, meta = {}, data = [], controls = {} } = {}) {
  let html = fs.readFileSync(file, 'utf8');
  for (const [key, value] of Object.entries({ META: meta, DATA: data })) {
    const re = new RegExp('window\\.ASH_' + key + '\\s*=\\s*[\\s\\S]*?;\\s*\\n');
    if (!re.test(html)) throw new Error('Missing ASH_' + key + ' assignment in ' + file);
    html = html.replace(re, () => 'window.ASH_' + key + ' = ' + JSON.stringify(value) + ';\n');
  }
  const elements = new Map(), charts = {}, timers = new Map();
  let timerId = 0;
  function element(id = '') {
    const listeners = {};
    return { id, style: {}, dataset: {}, value: '', checked: false, innerHTML: '', textContent: '', clientWidth: 1200, clientHeight: 600,
      selectedIndex: 0, get options() { return [{ text: this.value }]; },
      classList: { add() {}, remove() {}, contains() { return false; }, toggle() {} },
      addEventListener(type, fn) { (listeners[type] || (listeners[type] = [])).push(fn); },
      dispatch(type, event = {}) { const e = Object.assign({ target: this, preventDefault() {}, stopPropagation() {} }, event); for (const fn of listeners[type] || []) fn(e); const fn = this['on' + type]; if (fn) fn(e); },
      appendChild() {}, removeChild() {}, querySelectorAll() { return []; }, setAttribute() {}, focus() {}, select() {},
      getBoundingClientRect() { return { width: this.clientWidth, height: this.clientHeight, left: 0, top: 0 }; }
    };
  }
  const get = id => { if (!elements.has(id)) elements.set(id, element(id)); return elements.get(id); };
  // Parse defaults rather than silently assigning incorrect select values.
  for (const m of html.matchAll(/<select\b[^>]*id="([^"]+)"[^>]*>([\s\S]*?)<\/select>/gi)) {
    const opts = Array.from(m[2].matchAll(/<option\b([^>]*)value="([^"]+)"([^>]*)>/gi));
    const selected = opts.find(o => /\bselected\b/.test(o[1] + o[3])) || opts[0];
    if (selected) get(m[1]).value = selected[2];
  }
  for (const m of html.matchAll(/<input\b[^>]*id="([^"]+)"[^>]*>/gi)) get(m[1]).value = (m[0].match(/value="([^"]*)"/) || [,''])[1];
  const toggles = Array.from(html.matchAll(/<input\b[^>]*data-id="([^"]+)"[^>]*>/gi), m => Object.assign(element(), { dataset: { id: m[1] }, checked: /\bchecked\b/.test(m[0]) }));
  for (const [id, value] of Object.entries(controls)) get(id).value = String(value);
  const document = { getElementById: get, querySelectorAll: s => s.includes('#idToggles') ? toggles : [], createElement: () => element(), addEventListener() {}, createRange: () => ({ selectNodeContents() {} }), execCommand() {} };
  const echarts = { init(el) {
    const handlers = {}, zrHandlers = {};
    const chart = { _last: {}, captures: [], handlers, zrHandlers,
      setOption(o, notMerge) { this.captures.push(o); this._last = notMerge === true ? o : merge(this._last, o); },
      getOption() { return this._last; }, on(t, fn) { (handlers[t] || (handlers[t] = [])).push(fn); }, off(t) { delete handlers[t]; },
      emit(t, e) { for (const fn of handlers[t] || []) fn(e); }, resize() {}, dispatchAction() {},
      getZr() { return { on(t, fn) { (zrHandlers[t] || (zrHandlers[t] = [])).push(fn); } }; },
      convertFromPixel(_, v) { return v; }, containPixel() { return true; }, getWidth() { return el.clientWidth; }, getHeight() { return el.clientHeight; }
    }; charts[el.id] = chart; return chart;
  }, graphic: { LinearGradient: function () {}, clipRectByRect: r => r } };
  const window = { innerHeight: 1000, addEventListener() {}, getSelection: () => ({ removeAllRanges() {}, addRange() {} }) };
  const context = vm.createContext({ window, document, echarts, navigator: {}, console,
    setTimeout(fn) { const id = ++timerId; timers.set(id, fn); return id; }, clearTimeout(id) { timers.delete(id); },
    setInterval(fn) { const id = ++timerId; timers.set(id, fn); return id; }, clearInterval(id) { timers.delete(id); },
    ResizeObserver: class { observe() {} disconnect() {} } });
  // Generated reports embed ECharts itself. Keep the stub as the chart boundary;
  // execute only the data assignment and the report application in this harness.
  const scripts = Array.from(html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)).filter(m =>
    !/\bsrc=/.test(m[1]) && (/window\.ASH_DATA\s*=/.test(m[2]) || /function renderSummary\(/.test(m[2])));
  for (const script of scripts) vm.runInContext(script[2], context, { timeout: 5000, filename: file });
  return { charts, get, elements, change(id, value) { get(id).value = String(value); get(id).dispatch('change'); },
    flushTimers() { const pending = Array.from(timers.values()); timers.clear(); pending.forEach(fn => fn()); },
    graph() { return (charts['chart-tree']._last.series || []).find(s => s.type === 'graph'); },
    lanes() { return charts['chart-lanes']._last.series[0]; },
    background(t) { for (const fn of charts['chart-lanes'].zrHandlers.click || []) fn({ target: null, offsetX: t, offsetY: 0 }); }
  };
}
module.exports = { renderReport, embeddedData, TEMPLATE, merge };
