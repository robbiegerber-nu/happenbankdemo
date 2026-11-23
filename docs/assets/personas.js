/* Customer and persona calculations from totals. No page code, so it can be tested on its own.
   A total t holds: o contacts, a answered, f resolved, e repeated, dg digital contacts, sv surveys, sat, net, nn (surveys not passive),
   cp complaints, cust customers, mon months, who customers who contacted, k contacts and k4 contacts of heavy users. */
(function (root) {
  'use strict';
  // [numerator, base, scale]; rates with a mix effect say so
  const M = {
    rate: { x: 'o', n: 'cm', scale: 100 }, reach: { x: 'who', n: 'cust', scale: 100 }, digital: { x: 'dg', n: 'o', scale: 100 },
    csat: { x: 'sat', n: 'sv', scale: 100, mix: true }, nps: { x: 'net', n: 'sv', scale: 100, sq: 'nn', mix: true }, fcr: { x: 'f', n: 'a', scale: 100, mix: true },
    repeat: { x: 'e', n: 'o', scale: 100, mix: true }, complaints: { x: 'cp', n: 'o', scale: 1000 }
  };
  const METRICS = Object.keys(M);
  const add = (p, q) => { for (const k in q) p[k] = (p[k] || 0) + (q[k] || 0); return p; };
  const n = (m, t) => (t && t[M[m].n]) || 0;
  const value = (m, t) => (n(m, t) > 0 ? ((t[M[m].x] || 0) / t[M[m].n]) * M[m].scale : null);
  // variance of the unscaled rate; contact and complaint rates are counts (a customer can contact more than once)
  function variance(m, t) { const d = M[m], b = n(m, t); if (!b) return 0; const r = (t[d.x] || 0) / b; if (m === 'rate' || m === 'complaints') return (t[d.x] || 0) / (b * b); const sq = (d.sq ? t[d.sq] : t[d.x]) / b; return Math.max(0, sq - r * r) / b; }
  function beyond(m, a, b, limit = 3) { if (!n(m, a) || !n(m, b)) return false; const s = Math.sqrt(variance(m, a) + variance(m, b)), d = (value(m, a) - value(m, b)) / M[m].scale; return s > 0 && Math.abs(d) >= limit * s; }
  function minus(all, t) { const o = {}; for (const k in all) o[k] = all[k] - (t[k] || 0); o.mon = all.mon; return o; }
  // Split a group's gap into what it contacts about and through which channel (mix), and the rest.
  // byGroup and byAll are Maps of channel|reason -> total. Everyone's result for the same mix = expected.
  function mixGap(m, byGroup, byAll, all) {
    if (!M[m].mix) return null; const d = M[m]; let nn = 0, ex = 0;
    for (const [k, t] of byGroup) { const b = t[d.n] || 0; if (!b) continue; const a = byAll.get(k); nn += b; ex += b * (a[d.x] || 0) / a[d.n]; }
    return nn ? (ex / nn) * d.scale - value(m, all) : null;
  }
  root.Personas = { METRICS, M, add, n, value, variance, beyond, minus, mixGap };
})(typeof window !== 'undefined' ? window : globalThis);
