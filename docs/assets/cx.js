/* Customer experience calculations: every result is x / n from totals. No page code, so it can be tested on its own.
   A part is { n, x, xx } for one KPI: n the base, x the sum, xx the sum of squares (equal to x for yes/no measures). */
(function (root) {
  'use strict';
  const SCALE = { csat: 100, nps: 100, ces: 1, fcr: 100, repeat: 100, complaints: 1000, response: 100 };
  const METRICS = Object.keys(SCALE);
  const blank = () => { const o = {}; for (const m of METRICS) o[m] = { n: 0, x: 0, xx: 0 }; return o; };
  const put = (p, n, x, xx) => { p.n += n; p.x += x; p.xx += xx; };
  // one month file row into a part set
  function contact(t, c, j) { put(t.fcr, c.a[j], c.f[j], c.f[j]); put(t.repeat, c.i[j], c.e[j], c.e[j]); put(t.complaints, c.o[j], 0, 0); put(t.response, c.a[j], 0, 0); }
  function survey(t, v, j) {
    const sat = v.cs[j] >= 4 ? 1 : 0, net = v.np[j] >= 9 ? 1 : v.np[j] <= 6 ? -1 : 0, e = v.ce[j];
    put(t.csat, 1, sat, sat); put(t.nps, 1, net, net * net); put(t.ces, 1, e, e * e); t.response.x++; t.response.xx++;
  }
  function complaint(t) { t.complaints.x++; t.complaints.xx++; }
  const value = (m, t) => (t && t[m].n > 0 ? (t[m].x / t[m].n) * SCALE[m] : null);
  // variance of the rate (not scaled). Complaints can exceed one per contact group, so they are treated as counts.
  function variance(m, t) { const p = t[m]; if (!(p.n > 1)) return 0; const r = p.x / p.n; return m === 'complaints' ? p.x / (p.n * p.n) : Math.max(0, p.xx / p.n - r * r) / p.n; }
  // is the difference between two independent groups beyond chance (3 standard errors)?
  function beyond(m, a, b, limit = 3) { if (!a || !b || !(a[m].n > 0) || !(b[m].n > 0)) return false; const d = a[m].x / a[m].n - b[m].x / b[m].n, s = Math.sqrt(variance(m, a) + variance(m, b)); return s > 0 && Math.abs(d) >= limit * s; }
  // everyone except this group, for a fair comparison of a group with the rest
  function minus(all, t) { const o = blank(); for (const m of METRICS) for (const k of ['n', 'x', 'xx']) o[m][k] = all[m][k] - t[m][k]; return o; }
  // how far the group moves the overall result, in the KPI's unit: its share of the base times its gap
  function pull(m, t, all) { const a = all[m], p = t[m]; return a.n > 0 && p.n > 0 ? (p.n / a.n) * (p.x / p.n - a.x / a.n) * SCALE[m] : 0; }
  root.CX = { METRICS, SCALE, blank, contact, survey, complaint, value, variance, beyond, minus, pull };
})(typeof window !== 'undefined' ? window : globalThis);
