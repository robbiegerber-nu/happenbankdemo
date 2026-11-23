/* Coaching calculations: agent results against what the same contacts took their group. No page code, so it can be tested on its own.
   Every result comes from totals. A row is one agent and month; rows add up, after prepare() has put the group's
   adherence (ea) and quality (eq, vq) expectations on each row. */
(function (root) {
  'use strict';
  const NUM = ['n', 'sch', 'adh', 'ea', 'va', 'late', 'early', 'ext', 'aux', 'coa', 'trn', 'qn', 'qs', 'eq', 'vq', 'ans', 'h', 'eh', 'vh', 'tk', 'etk', 'hd', 'ehd', 'wr', 'ewr', 'res', 'eres', 'vres', 'tr', 'etr', 'vtr', 'sv', 'sat', 'esat', 'vsat'];
  const add = (p, q) => { for (const k of NUM) p[k] = (p[k] || 0) + (q[k] || 0); return p; };
  // num / den is the result, exp / den what the group would have had; vr is the variance of num; n is the sample size
  const M = {
    adherence: { num: 'adh', den: 'sch', exp: 'ea', vr: 'va', n: 'n', scale: 100, worse: -1 },
    aht: { num: 'h', den: 'ans', exp: 'eh', vr: 'vh', n: 'ans', scale: 1, worse: 1 },
    fcr: { num: 'res', den: 'ans', exp: 'eres', vr: 'vres', n: 'ans', scale: 100, worse: -1 },
    transfer: { num: 'tr', den: 'ans', exp: 'etr', vr: 'vtr', n: 'ans', scale: 100, worse: 1 },
    csat: { num: 'sat', den: 'sv', exp: 'esat', vr: 'vsat', n: 'sv', scale: 100, worse: -1 },
    quality: { num: 'qs', den: 'qn', exp: 'eq', vr: 'vq', n: 'qn', scale: 1, worse: -1 }
  };
  function prepare(rows, groupOf) {
    const g = new Map();
    for (const r of rows) {
      const k = r.m + '|' + groupOf(r.g), p = g.get(k) || (g.set(k, { sch: 0, adh: 0, qn: 0, qs: 0, qq: 0 }), g.get(k));
      for (const c in p) p[c] += r[c];
    }
    for (const r of rows) {
      const p = g.get(r.m + '|' + groupOf(r.g)), rate = p.sch ? p.adh / p.sch : 0, own = r.sch ? r.adh / r.sch : 0, qm = p.qn ? p.qs / p.qn : 0;
      r.ea = r.sch * rate;
      r.va = Math.max(0, r.aa - 2 * own * r.ab + own * own * r.bb) * (r.n > 1 ? r.n / (r.n - 1) : 1);   // day-to-day variation of the agent's own adherence
      r.eq = r.qn * qm;
      r.vq = p.qn ? r.qn * Math.max(0, p.qq / p.qn - qm * qm) : 0;
    }
    return rows;
  }
  const value = (m, p) => { const d = M[m]; return p[d.den] > 0 ? (p[d.num] / p[d.den]) * d.scale : null; };
  const expected = (m, p) => { const d = M[m]; return p[d.den] > 0 ? (p[d.exp] / p[d.den]) * d.scale : null; };
  const n = (m, p) => p[M[m].n] || 0;
  const z = (m, p) => { const d = M[m], s = Math.sqrt(p[d.vr] || 0); return s > 0 ? (p[d.num] - p[d.exp]) / s : 0; };
  // 'worse' or 'better' only when the gap is well beyond chance (3 standard errors); handle time is never praised for being short
  function signal(m, p, minN, limit = 3) {
    if (n(m, p) < minN || value(m, p) == null) return 'few';
    const s = z(m, p) * M[m].worse;
    return s >= limit ? 'worse' : s <= -limit && m !== 'aht' ? 'better' : 'similar';
  }
  root.Coaching = { NUM, METRICS: Object.keys(M), add, prepare, value, expected, n, z, signal, worse: (m) => M[m].worse };
})(typeof window !== 'undefined' ? window : globalThis);
