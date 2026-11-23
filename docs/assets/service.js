/* Service & access calculations from 15-minute interval rows. No page code, so it can be tested on its own. */
(function (root) {
  'use strict';
  const KEYS = ['o', 'a', 'w', 'b', 's', 'z', 'f', 'h', 'r'];
  const empty = () => ({ o: 0, a: 0, w: 0, b: 0, s: 0, z: 0, f: 0, h: 0, r: 0, rows: 0 });
  // Sum rows by key. rows: [{ t: day start (ms), dow, c: columns, j: index }] is too slow, so each block is one day's slice of a month.
  function group(blocks, test, keyOf) {
    const out = new Map();
    for (const k of blocks) for (let j = k.from; j < k.to; j++) {
      const c = k.cols;
      if (!test(k, c, j)) continue;
      const key = keyOf(k, c, j);
      if (key == null) continue;
      let p = out.get(key);
      if (!p) out.set(key, (p = empty()));
      for (const x of KEYS) p[x] += c[x][j];
      p.rows++;
    }
    return out;
  }
  function total(map) { const t = empty(); for (const p of map.values()) { for (const x of KEYS) t[x] += p[x]; t.rows += p.rows; } return t; }
  const eligible = (p) => p.a + p.b - p.s;
  // Every ratio from totals. n is the KPI's own denominator, used for the minimum sample.
  const VALUE = {
    sl: (p) => (eligible(p) > 0 ? (p.w / eligible(p)) * 100 : null), asa: (p) => (p.a > 0 ? p.z / p.a : null),
    abandon: (p) => (p.o > 0 ? (p.b / p.o) * 100 : null), volume: (p) => p.o,
    staffing: (p) => (p.r > 0 ? ((p.h - p.r) / p.r) * 100 : null), forecast: (p) => (p.f > 0 ? ((p.o - p.f) / p.f) * 100 : null)
  };
  const N = { sl: eligible, asa: (p) => p.a, abandon: (p) => p.o, volume: (p) => p.o, staffing: (p) => p.r, forecast: (p) => p.f };
  root.Service = { KEYS, empty, group, total, eligible, value: (m, p) => (p ? VALUE[m](p) : null), n: (m, p) => (p ? N[m](p) : 0) };
})(typeof window !== 'undefined' ? window : globalThis);
