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
  hhmmToMinutes, minutesToHhmm, legacyRangeToBlocks, normalizeDay,
  migrateState, encodeStateToHash, decodeStateFromHash, escapeHtml,
  daySegments, toggleBlock, fmtHoursNumber, isNetworkError, loadDirtyIds
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

// --- legacy range -> 30-min blocks ------------------------------------------

test('legacyRangeToBlocks expands a span into aligned blocks', () => {
  // 09:00–11:00 => 09:00, 09:30, 10:00, 10:30 (end-exclusive)
  deepEq(legacyRangeToBlocks('09:00', '11:00'), [540, 570, 600, 630]);
});

test('legacyRangeToBlocks rejects empty/inverted ranges', () => {
  deepEq(legacyRangeToBlocks('10:00', '10:00'), []);
  deepEq(legacyRangeToBlocks('11:00', '09:00'), []);
  deepEq(legacyRangeToBlocks(null, null), []);
});

test('legacyRangeToBlocks never emits blocks before DAY_START', () => {
  const blocks = legacyRangeToBlocks('05:00', '07:00');
  assert(blocks.every(m => m >= 360), 'all blocks at/after 06:00');
});

// --- normalizeDay -----------------------------------------------------------

test('normalizeDay dedupes, sorts, and clamps blocks to the day window', () => {
  const d = normalizeDay({ blocks: [600, 360, 600, 60, 1400], actualHours: 3 });
  // 60 (before 06:00) and 1400 (after 22:00, top=1320) dropped; dupes removed; sorted.
  deepEq(d.blocks, [360, 600]);
  assert.strictEqual(d.actualHours, '3'); // coerced to string
});

test('normalizeDay migrates legacy start/end when blocks absent', () => {
  const d = normalizeDay({ start: '09:00', end: '10:00' });
  deepEq(d.blocks, [540, 570]);
  assert.strictEqual(d.actualHours, '');
});

test('normalizeDay tolerates garbage input', () => {
  const d = normalizeDay(undefined);
  deepEq(d.blocks, []);
  assert.strictEqual(d.actualHours, '');
});

test('normalizeDay preserves an explicit zero actualHours', () => {
  assert.strictEqual(normalizeDay({ blocks: [], actualHours: 0 }).actualHours, '0');
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
      days: Array.from({ length: 7 }, (_, i) => ({ blocks: i === 0 ? [360, 390] : [], actualHours: '' }))
    }]
  };
  const hash = encodeStateToHash(original);
  assert(hash.startsWith('#s='), 'hash begins with #s=');
  const decoded = decodeStateFromHash(hash);
  assert.strictEqual(decoded.weekStart, original.weekStart);
  assert.strictEqual(decoded.schedules[0].name, 'Nanny · Ana'); // unicode survives
  deepEq(decoded.schedules[0].days[0].blocks, [360, 390]);
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

// --- day segment merging (timeline display) ---------------------------------

test('daySegments merges contiguous blocks and splits on gaps', () => {
  const segs = daySegments({ blocks: [360, 390, 420, 480] }); // gap between 420->480
  deepEq(segs, [{ s: 360, e: 450 }, { s: 480, e: 510 }]);
});

// --- toggleBlock (tap-to-toggle grid) ---------------------------------------

test('toggleBlock adds then removes a block, keeping order', () => {
  const day = { blocks: [420] };
  toggleBlock(day, 0);           // idx 0 => 06:00 (360)
  deepEq(day.blocks, [360, 420]);
  toggleBlock(day, 0);           // toggle off
  deepEq(day.blocks, [420]);
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
