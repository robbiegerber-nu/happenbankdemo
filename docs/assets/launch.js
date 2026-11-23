/* Launch impact calculations. No page code, so it can be tested on its own.
   Baseline: weeks -8 to -3, before the announcement. Affected reasons are the ones planned for the launch; "other" reasons
   are those no launch in the window is expected to touch.
   Volume: expected = baseline x how the other reasons moved that week, so seasonality and holidays are not credited to the launch.
   Rates:  expected = the baseline rate; the other reasons are shown beside it. */
(function (root) {
  'use strict';
  const BASE = [-8, -7, -6, -5, -4, -3], KEYS = ['o', 'a', 'h', 'f', 'g', 'met', 'i', 'e', 'sv', 'sat', 't'];
  const RATE = { aht: ['h', 'a', 1], fcr: ['f', 'a', 100], csat: ['sat', 'sv', 100], repeat: ['e', 'i', 100], sl: ['met', 'g', 100] };
  const METRICS = ['volume', ...Object.keys(RATE)];
  const add = (p, q) => { for (const k of KEYS) p[k] = (p[k] || 0) + (q[k] || 0); return p; };
  const n = (m, p) => (m === 'volume' ? p.o || 0 : p[RATE[m][1]] || 0);
  const rate = (m, p) => { const [x, d, s] = RATE[m]; return p[d] > 0 ? (p[x] / p[d]) * s : null; };
  const total = (by, ws) => { const t = {}; for (const w of ws) if (by.has(w)) add(t, by.get(w)); return t; };
  // by-week maps of parts for a set of reasons
  function weeks(rows, keep) { const o = new Map(); for (const r of rows) if (keep(r.r)) add(o.get(r.w) || (o.set(r.w, {}), o.get(r.w)), r); return o; }
  // one launch, one metric: weekly actual, expected and the range the baseline weeks normally stay in
  function series(m, aff, oth) {
    const ws = [...aff.keys()].sort((a, b) => a - b), base = BASE.filter((w) => aff.has(w)), tb = total(aff, base), ob = total(oth, base), out = [];
    if (base.length < 4) return { pts: [], base: null, sd: null };
    let bv, sd;
    const exp = (w) => (m === 'volume' ? (tb.o / base.length) * (ob.o > 0 ? (oth.get(w) || { o: 0 }).o / (ob.o / base.length) : 1) : bv);
    const act = (w) => (m === 'volume' ? (aff.get(w) || {}).o || 0 : rate(m, aff.get(w)));
    if (m === 'volume') {
      bv = tb.o / base.length;
      const q = base.map((w) => act(w) / exp(w) - 1); sd = Math.max(Math.sqrt(q.reduce((s, x) => s + x * x, 0) / (q.length - 1)), 1 / Math.sqrt(bv || 1));   // relative
    } else {
      bv = rate(m, tb); const q = base.map(act).filter((x) => x != null);
      sd = q.length > 1 ? Math.sqrt(q.reduce((s, x) => s + (x - bv) ** 2, 0) / (q.length - 1)) : 0;
      if (m !== 'aht' && bv != null) { const per = n(m, tb) / base.length; sd = Math.max(sd, per > 0 ? Math.sqrt((bv / 100) * (1 - bv / 100) / per) * 100 : 0); }   // at least sampling error
    }
    for (const w of ws) { const e = exp(w), v = act(w), half = m === 'volume' ? 3 * sd * e : 3 * sd; out.push({ w, v, e, lo: e - half, hi: e + half, n: n(m, aff.get(w)), other: m === 'volume' ? null : rate(m, oth.get(w) || {}), out: v != null && (v > e + half || v < e - half) }); }
    return { pts: out, base: bv, sd };
  }
  // what the volume series says about the launch
  function summary(s, maxW = 12) {
    const post = s.pts.filter((p) => p.w >= 0 && p.w <= maxW); if (!post.length) return null;
    const peak = post.reduce((a, b) => (b.v / b.e > a.v / a.e ? b : a)), hit = post.filter((p) => p.v > p.hi);
    const ex = (a, b) => post.filter((p) => p.w >= a && p.w <= b).reduce((t, p) => t + p.v - p.e, 0), exE = (a, b) => post.filter((p) => p.w >= a && p.w <= b).reduce((t, p) => t + p.e, 0);
    // back to normal: the first of two weeks in a row inside the range, after the first week above it
    let back = null; if (hit.length) { const first = hit[0].w; for (let i = 0; i < post.length - 1; i++) if (post[i].w > first && post[i].v <= post[i].hi && post[i + 1].v <= post[i + 1].hi) { back = post[i].w; break; } }
    return { peakW: peak.w, peak: (peak.v / peak.e - 1) * 100, any: hit.length > 0, back, extra4: ex(0, 3), pct4: exE(0, 3) > 0 ? ex(0, 3) / exE(0, 3) * 100 : null, extra: ex(0, maxW), pct: exE(0, maxW) > 0 ? ex(0, maxW) / exE(0, maxW) * 100 : null, last: post[post.length - 1].w, weeks4: post.filter((p) => p.w <= 3).length };
  }
  // change of a rate in weeks 0-3 against the baseline, with its own sampling error (and the other reasons beside it)
  function change(m, aff, oth, ws = [0, 1, 2, 3]) {
    const have = ws.filter((w) => aff.has(w)); if (!have.length) return null;
    const p = total(aff, have), b = total(aff, BASE), q = total(oth, have), c = total(oth, BASE), v = rate(m, p), e = rate(m, b); if (v == null || e == null) return null;
    let sure; if (m === 'aht') { const s = series(m, aff, oth).sd || 0; sure = Math.abs(v - e) >= 3 * Math.max(s / Math.sqrt(have.length), 1e-9); }
    else { const vr = (x, t) => { const k = n(m, t); return k ? (x / 100) * (1 - x / 100) / k : 0; }; sure = Math.abs(v - e) / 100 >= 3 * Math.sqrt(vr(v, p) + vr(e, b)); }
    return { v, e, d: v - e, n: n(m, p), sure, other: rate(m, q) == null || rate(m, c) == null ? null : rate(m, q) - rate(m, c) };
  }
  root.Launch = { BASE, METRICS, KEYS, add, n, rate, total, weeks, series, summary, change };
})(typeof window !== 'undefined' ? window : globalThis);
