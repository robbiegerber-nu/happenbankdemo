/* Self-service and channel shift calculations from totals. No page code, so it can be tested on its own. */
(function (root) {
  'use strict';
  const add = (p, q) => { for (const k in q) p[k] = (p[k] || 0) + (q[k] || 0); return p; };
  const DIGITAL = [2, 3, 5];
  const ratio = (a, b, s = 100) => (b > 0 ? (a / b) * s : null);
  // Split a change in a share into: what customers asked about (or who asked) and a real move within each group.
  // a and b are Maps of key -> { n, x }: b the earlier period. Exact: mix + within = total change (points).
  function split(a, b) {
    const sum = (mp, k) => [...mp.values()].reduce((s, v) => s + v[k], 0), na = sum(a, 'n'), nb = sum(b, 'n'); if (!na || !nb) return null;
    const ra = sum(a, 'x') / na, rb = sum(b, 'x') / nb, rows = []; let mix = 0, within = 0;
    for (const k of new Set([...a.keys(), ...b.keys()])) {
      const p = a.get(k) || { n: 0, x: 0 }, q = b.get(k) || { n: 0, x: 0 }, wa = p.n / na, wb = q.n / nb, va = p.n ? p.x / p.n : q.n ? q.x / q.n : 0, vb = q.n ? q.x / q.n : va;
      const m = (wa - wb) * ((va + vb) / 2 - (ra + rb) / 2), w = ((wa + wb) / 2) * (va - vb); mix += m; within += w; rows.push({ k, n: p.n, va, vb, mix: m * 100, within: w * 100 });
    }
    return { total: (ra - rb) * 100, mix: mix * 100, within: within * 100, rows };
  }
  // is the difference between two shares beyond chance (3 standard errors)?
  function beyond(x1, n1, x2, n2, limit = 3) { if (!n1 || !n2) return false; const p1 = x1 / n1, p2 = x2 / n2, s = Math.sqrt(p1 * (1 - p1) / n1 + p2 * (1 - p2) / n2); return s > 0 && Math.abs(p1 - p2) >= limit * s; }
  root.SelfService = { add, DIGITAL, ratio, split, beyond };
})(typeof window !== 'undefined' ? window : globalThis);
