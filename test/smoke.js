#!/usr/bin/env node
'use strict';

// Dependency-free smoke test for app.html's pure core.
//
// There is no build step and no module system: app.html is a single file with
// one inline <script>. This harness reads that script out of the HTML, runs it
// in a Node `vm` sandbox behind a minimal DOM/localStorage stub, and asserts the
// pure functions that do the load-bearing data work — time math, legacy-data
// migration, day normalisation, and the share-link round-trip. If any of these
// regress, cloud sync and #s= share links silently corrupt user schedules, so
// they are exactly the parts worth guarding.
//
// Run: `node test/smoke.js` (exit 0 = pass, 1 = fail). No dependencies.

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

// --- Load app.html's inline script -----------------------------------------

const appHtml = fs.readFileSync(path.join(__dirname, '..', 'app.html'), 'utf8');
const scriptMatch = appHtml.match(/<script>([\s\S]*?)<\/script>/);
assert(scriptMatch, 'could not find inline <script> in app.html');
let scriptSrc = scriptMatch[1];

// Strip the auto-run entrypoints (the init() IIFE and setupCloudUI()) — they
// drive the full DOM render, which is out of scope for a pure-function smoke
// test. Everything above them is declarations + cheap top-level setup.
const initIdx = scriptSrc.indexOf('(function init()');
assert(initIdx !== -1, 'could not find init() IIFE to strip');
scriptSrc = scriptSrc.slice(0, initIdx);

// --- Minimal browser stubs --------------------------------------------------
// A permissive Proxy element absorbs any DOM access the top-level setup makes
// (classList, style, addEventListener, querySelector chains) without throwing.

function makeStubEl() {
  const target = function () {};
  return new Proxy(target, {
    get(_t, prop) {
      if (prop === 'style') return new Proxy({}, { get: () => () => {} });
      if (prop === 'classList') return { add() {}, remove() {}, toggle() {}, contains() { return false; } };
      if (prop === 'dataset') return {};
      if (prop === 'hidden') return false;
      if (prop === 'querySelectorAll') return () => [];
      if (prop === 'querySelector' || prop === 'closest') return () => makeStubEl();
      return makeStubEl();
    },
    set() { return true; },
    apply() { return makeStubEl(); }
  });
}

function makeLocalStorage() {
  const store = new Map();
  return {
    getItem: k => (store.has(k) ? store.get(k) : null),
    setItem: (k, v) => { store.set(k, String(v)); },
    removeItem: k => { store.delete(k); },
    clear: () => store.clear()
  };
}

const documentStub = {
  documentElement: makeStubEl(),
  body: makeStubEl(),
  title: '',
  getElementById: () => makeStubEl(),
  querySelector: () => makeStubEl(),
  querySelectorAll: () => [],
  addEventListener: () => {},
  createElement: () => makeStubEl()
};

const sandbox = {
  console,
  localStorage: makeLocalStorage(),
  document: documentStub,
  navigator: { language: 'en-US', clipboard: { writeText: async () => {} } },
  location: { hash: '', pathname: '/', search: '', origin: 'https://app.keepingcadence.com' },
  history: { replaceState() {}, pushState() {} },
  setTimeout: () => 0,
  clearTimeout: () => {},
  addEventListener: () => {},
  removeEventListener: () => {},
  requestAnimationFrame: () => 0,
  matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} }),
  btoa: s => Buffer.from(s, 'binary').toString('base64'),
  atob: s => Buffer.from(s, 'base64').toString('binary')
};
sandbox.window = sandbox;
sandbox.globalThis = sandbox;

const ctx = vm.createContext(sandbox);
vm.runInContext(scriptSrc, ctx, { filename: 'app.html#script' });

// Function declarations attach to the sandbox global; pull out the ones we test.
const {
  hhmmToMinutes, minutesToHhmm, normalizeRanges, legacyBlocksToRanges, normalizeDay,
  migrateState, encodeStateToHash, decodeStateFromHash, escapeHtml,
  daySegments, estimatedMinutes, fmtHoursNumber, isNetworkError, loadDirtyIds
} = ctx;

// --- Tiny test runner -------------------------------------------------------

let passed = 0;
const failures = [];
function test(name, fn) {
  try { fn(); passed++; }
  catch (e) { failures.push({ name, err: e }); }
}

// Values returned from the vm sandbox carry that realm's prototypes, so
// assert.deepStrictEqual rejects them as "not reference-equal". Re-serialise
// through JSON to compare structure in the host realm.
function deepEq(actual, expected, msg) {
  assert.strictEqual(JSON.stringify(actual), JSON.stringify(expected), msg);
}

// --- hhmm <-> minutes -------------------------------------------------------

test('hhmmToMinutes parses HH:MM', () => {
  assert.strictEqual(hhmmToMinutes('06:00'), 360);
  assert.strictEqual(hhmmToMinutes('00:00'), 0);
  assert.strictEqual(hhmmToMinutes('22:30'), 1350);
});

test('hhmmToMinutes rejects junk', () => {
  assert.strictEqual(hhmmToMinutes(''), null);
  assert.strictEqual(hhmmToMinutes(null), null);
  assert.strictEqual(hhmmToMinutes('nope'), null);
});

test('minutesToHhmm formats and wraps', () => {
  assert.strictEqual(minutesToHhmm(360), '06:00');
  assert.strictEqual(minutesToHhmm(1350), '22:30');
  assert.strictEqual(minutesToHhmm(0), '00:00');
  assert.strictEqual(minutesToHhmm(1440), '00:00'); // wraps a full day
  assert.strictEqual(minutesToHhmm(-30), '23:30');  // negative wraps forward
});

test('hhmm <-> minutes round-trips across the day', () => {
  for (let m = 0; m < 1440; m += 15) {
    assert.strictEqual(hhmmToMinutes(minutesToHhmm(m)), m, `round-trip @ ${m}`);
  }
});

// --- normalizeRanges (sort / clamp / merge) ---------------------------------

test('normalizeRanges sorts, clamps to the day window, and merges overlaps/adjacency', () => {
  // 1400>top(1320) clamped; unsorted; the 900-1020 and 1020-1080 ranges are adjacent -> merge.
  deepEq(normalizeRanges([{ s: 1020, e: 1080 }, { s: 900, e: 1020 }, { s: 60, e: 400 }]),
    [{ s: 360, e: 400 }, { s: 900, e: 1080 }]);
});

test('normalizeRanges drops invalid ranges (end <= start, NaN)', () => {
  deepEq(normalizeRanges([{ s: 600, e: 600 }, { s: 700, e: 600 }, { s: NaN, e: 5 }]), []);
});

// --- legacy blocks -> ranges (unambiguous: legacy blocks were 30-min slots) --

test('legacyBlocksToRanges converts 30-min slot starts to merged ranges', () => {
  // 480(8:00) + 510(8:30) each cover 30 min and are contiguous -> one 8:00-9:00 range.
  deepEq(legacyBlocksToRanges([480, 510]), [{ s: 480, e: 540 }]);
  // a gap survives: 480-510 and 600-630 stay separate.
  deepEq(legacyBlocksToRanges([600, 480]), [{ s: 480, e: 510 }, { s: 600, e: 630 }]);
});

// --- normalizeDay -----------------------------------------------------------

test('normalizeDay keeps a ranges payload (sorted/merged/clamped)', () => {
  const d = normalizeDay({ ranges: [{ s: 480, e: 960 }], actualHours: 3 });
  deepEq(d.ranges, [{ s: 480, e: 960 }]);
  assert.strictEqual(d.actualHours, '3'); // coerced to string
});

test('normalizeDay migrates legacy blocks to ranges', () => {
  const d = normalizeDay({ blocks: [540, 570] }); // 9:00 + 9:30 slots -> 9:00-10:00
  deepEq(d.ranges, [{ s: 540, e: 600 }]);
  assert.strictEqual(d.actualHours, '');
});

test('normalizeDay migrates oldest start/end shape to a range', () => {
  deepEq(normalizeDay({ start: '09:00', end: '10:00' }).ranges, [{ s: 540, e: 600 }]);
});

test('normalizeDay tolerates garbage input', () => {
  const d = normalizeDay(undefined);
  deepEq(d.ranges, []);
  assert.strictEqual(d.actualHours, '');
});

test('normalizeDay preserves an explicit zero actualHours', () => {
  assert.strictEqual(normalizeDay({ ranges: [], actualHours: 0 }).actualHours, '0');
});

test('estimatedMinutes sums range durations', () => {
  assert.strictEqual(estimatedMinutes({ ranges: [{ s: 480, e: 960 }, { s: 1020, e: 1080 }] }), 540);
  assert.strictEqual(estimatedMinutes({ ranges: [] }), 0);
});

test('daySegments returns the day ranges as {s,e} segments', () => {
  deepEq(daySegments(normalizeDay({ ranges: [{ s: 480, e: 510 }, { s: 600, e: 630 }] })),
    [{ s: 480, e: 510 }, { s: 600, e: 630 }]);
});

// --- migrateState -----------------------------------------------------------

test('migrateState returns null for non-state input', () => {
  assert.strictEqual(migrateState(null), null);
  assert.strictEqual(migrateState({}), null);
  assert.strictEqual(migrateState({ foo: 1 }), null);
});

test('migrateState upgrades the oldest single-days shape', () => {
  const legacy = { weekStart: '2026-07-06', days: Array.from({ length: 7 }, () => ({ blocks: [] })) };
  const s = migrateState(legacy);
  assert.strictEqual(s.weekStart, '2026-07-06');
  assert.strictEqual(s.schedules.length, 1);
  assert.strictEqual(s.schedules[0].days.length, 7);
  assert.strictEqual(s.activeId, s.schedules[0].id);
});

test('migrateState keeps multi-schedule state and fills missing days', () => {
  const data = {
    weekStart: '2026-07-06',
    activeId: 'sched-x',
    schedules: [{ id: 'sched-x', name: 'A', colorVar: 'h2', days: [{ blocks: [360] }] }]
  };
  const s = migrateState(data);
  assert.strictEqual(s.schedules[0].days.length, 7, 'short days array is backfilled to 7');
  assert.strictEqual(s.activeId, 'sched-x');
});

test('migrateState falls back activeId to first schedule when dangling', () => {
  const data = {
    weekStart: '2026-07-06',
    activeId: 'gone',
    schedules: [{ id: 'a', days: Array.from({ length: 7 }, () => ({ blocks: [] })) }]
  };
  assert.strictEqual(migrateState(data).activeId, 'a');
});

test('migrateState honours the master view sentinel', () => {
  const data = {
    weekStart: '2026-07-06',
    activeId: 'master',
    schedules: [{ id: 'a', days: Array.from({ length: 7 }, () => ({ blocks: [] })) }]
  };
  assert.strictEqual(migrateState(data).activeId, 'master');
});

// --- share-link hash round-trip ---------------------------------------------

test('encode -> decode round-trips a full state', () => {
  const original = {
    weekStart: '2026-07-06',
    activeId: 'sched-1',
    schedules: [{
      id: 'sched-1', name: 'Nanny · Ana', colorVar: 'h3',
      days: Array.from({ length: 7 }, (_, i) => ({ ranges: i === 0 ? [{ s: 480, e: 960 }] : [], actualHours: '' }))
    }]
  };
  const hash = encodeStateToHash(original);
  assert(hash.startsWith('#s='), 'hash begins with #s=');
  const decoded = decodeStateFromHash(hash);
  assert.strictEqual(decoded.weekStart, original.weekStart);
  assert.strictEqual(decoded.schedules[0].name, 'Nanny · Ana'); // unicode survives
  deepEq(decoded.schedules[0].days[0].ranges, [{ s: 480, e: 960 }]);
});

test('decodeStateFromHash rejects non-share hashes', () => {
  assert.strictEqual(decodeStateFromHash('#team=abc'), null);
  assert.strictEqual(decodeStateFromHash(''), null);
  assert.strictEqual(decodeStateFromHash('#s=%%%not-base64%%%'), null);
});

// --- escapeHtml (XSS hygiene on innerHTML sinks) ----------------------------

test('escapeHtml neutralises all five HTML-significant chars', () => {
  assert.strictEqual(
    escapeHtml(`<img src=x onerror="a" onload='b'>&`),
    '&lt;img src=x onerror=&quot;a&quot; onload=&#39;b&#39;&gt;&amp;'
  );
  assert.strictEqual(escapeHtml(null), '');
});

// --- fmtHoursNumber ---------------------------------------------------------

test('fmtHoursNumber trims trailing zeros and floors invalid input', () => {
  assert.strictEqual(fmtHoursNumber(2), '2');
  assert.strictEqual(fmtHoursNumber(2.5), '2.5');
  assert.strictEqual(fmtHoursNumber(2.25), '2.25');
  assert.strictEqual(fmtHoursNumber(-1), '0');
  assert.strictEqual(fmtHoursNumber('x'), '0');
});

// --- sync status: offline vs. server error classification -------------------

test('isNetworkError treats a failed fetch as offline, a bad status as error', () => {
  assert.strictEqual(isNetworkError(new TypeError('Failed to fetch')), true);
  assert.strictEqual(isNetworkError(new Error('network request failed')), true);
  assert.strictEqual(isNetworkError(new Error('Data API HTTP 500')), false);
  assert.strictEqual(isNetworkError(new Error('stale write')), false);
});

// --- dirty-set persistence (unsynced edits survive a reload) ----------------

test('loadDirtyIds restores the persisted set of unsynced schedule ids', () => {
  sandbox.localStorage.setItem('keepingcadence-dirty', JSON.stringify(['sched-a', 'sched-b']));
  const s = loadDirtyIds();
  assert.strictEqual(s.size, 2);
  assert(s.has('sched-a') && s.has('sched-b'));
  sandbox.localStorage.removeItem('keepingcadence-dirty');
});

test('loadDirtyIds tolerates a missing or corrupt entry', () => {
  assert.strictEqual(loadDirtyIds().size, 0);
  sandbox.localStorage.setItem('keepingcadence-dirty', 'not json');
  assert.strictEqual(loadDirtyIds().size, 0);
  sandbox.localStorage.removeItem('keepingcadence-dirty');
});

// --- Report -----------------------------------------------------------------

for (const { name, err } of failures) {
  console.error(`✗ ${name}`);
  console.error(`  ${err.message}`);
}
if (failures.length) {
  console.error(`\n${failures.length} failed, ${passed} passed`);
  process.exit(1);
}
console.log(`✓ ${passed} passed`);
