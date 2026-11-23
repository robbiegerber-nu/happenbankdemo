/* Performance driver calculations: KPI parts from cube columns, and what drove a change. No page code, so it can be tested on its own. */
(function (root) {
  'use strict';
  // Each KPI as numerator x and denominator n of one cube row; ch limits it to channels. scale null means a total.
  const PARTS = {
    sl_phone: { x: 'met', n: 'elig', ch: [1], scale: 100 }, sl_chat: { x: 'met', n: 'elig', ch: [2], scale: 100 },
    sl_email: { x: 'met', n: 'elig', ch: [3, 5], scale: 100 }, sl_callback: { x: 'met', n: 'elig', ch: [4], scale: 100 },
    asa_phone: { x: 'wait', n: 'ans', ch: [1], scale: 1 }, abandon: { x: 'aband', n: 'offered', ch: [1, 2], scale: 100 },
    fcr: { x: 'resolved', n: 'ans', scale: 100, agent: true }, csat: { x: 'sat', n: 'sv', scale: 100, agent: true },
    nps: { x: 'net', n: 'sv', scale: 100, agent: true }, volume: { x: 'offered', n: 'offered', scale: null },
    aht_phone: { x: 'handle', n: 'ans', ch: [1], scale: 1, agent: true }, digital_share: { x: 'digital', n: 'offered', scale: 100 }
  };
  const value = (p, scale) => (!p ? null : scale == null ? p.x : p.n > 0 ? (p.x / p.n) * scale : null);

  /* Sum x and n of the rows that pass every test, grouped by keyOf(i). channelOf(i) gives a row's channel. */
  function group(cols, kpi, tests, keyOf, channelOf) {
    const d = PARTS[kpi], out = new Map(), N = cols.q ? cols.q.length : 0, n = cols[d.n];
    for (let i = 0; i < N; i++) {
      const c = channelOf(i);
      if (d.ch && !d.ch.includes(c)) continue;
      let ok = true;
      for (const t of tests) if (!t(i)) { ok = false; break; }
      if (!ok) continue;
      const x = d.x === 'digital' ? (c === 2 || c === 3 || c === 5 ? cols.offered[i] : 0) : cols[d.x][i];
      if (!x && !n[i]) continue;
      const k = keyOf(i), p = out.get(k);
      if (p) { p.x += x; p.n += n[i]; } else out.set(k, { x, n: n[i] });
    }
    return out;
  }
  const sum = (map) => { const t = { x: 0, n: 0 }; for (const p of map.values()) { t.x += p.x; t.n += p.n; } return t; };

  /* Split the change between two periods across members. The parts add up to the change exactly.
     mix  : the member's share of contacts changed, valued at how far it sits from the overall average
     rate : the member's own result changed, weighted by its average share
     A member present in only one period is all mix. Totals (scale null) have one part: the member's own change. */
  function decompose(now, before, scale) {
    const T1 = sum(now), T0 = sum(before), R1 = value(T1, scale), R0 = value(T0, scale), rows = [];
    for (const k of new Set([...now.keys(), ...before.keys()])) {
      const a = now.get(k), b = before.get(k), v1 = value(a, scale), v0 = value(b, scale);
      if (scale == null) { const t = (a ? a.x : 0) - (b ? b.x : 0); rows.push({ key: k, v1: a ? a.x : 0, v0: b ? b.x : 0, n1: a ? a.n : 0, n0: b ? b.n : 0, s1: T1.x ? (a ? a.x : 0) / T1.x : 0, s0: T0.x ? (b ? b.x : 0) / T0.x : 0, mix: 0, rate: t, total: t }); continue; }
      const s1 = a && T1.n ? a.n / T1.n : 0, s0 = b && T0.n ? b.n / T0.n : 0;
      // no denominator in a period: use the other period's value, so nothing is called a rate change
      const r1 = v1 ?? v0, r0 = v0 ?? v1;
      if (r1 == null || R1 == null || R0 == null) continue;
      const mix = (s1 - s0) * ((r1 + r0) / 2 - (R1 + R0) / 2), rate = ((s1 + s0) / 2) * (r1 - r0);
      rows.push({ key: k, v1, v0, n1: a ? a.n : 0, n0: b ? b.n : 0, s1, s0, mix, rate, total: mix + rate });
    }
    return { R1, R0, n1: T1.n, n0: T0.n, change: R1 == null || R0 == null ? null : R1 - R0, rows };
  }
  root.Drivers = { PARTS, value, group, sum, decompose };
})(typeof window !== 'undefined' ? window : globalThis);
