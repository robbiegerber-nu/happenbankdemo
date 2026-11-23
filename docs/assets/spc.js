/* Statistical process control: limits and run rules. No page code here, so it can be tested on its own.
   A point is { x, n, k }: numerator, denominator, sample count. A KPI's value is x ÷ n × scale (or x when scale is null). */
(function (root) {
  'use strict';
  const D2 = 1.128;          // moving range of two points → standard deviation
  const MIN_BASELINE = 20;   // fewest points that can set limits

  const valueOf = (p, scale) => (p.x == null ? null : scale == null ? p.x : p.n > 0 ? (p.x / p.n) * scale : null);
  const usable = (p, scale, minN) => valueOf(p, scale) != null && p.k >= minN;
  const mean = (a) => a.reduce((s, v) => s + v, 0) / a.length;
  const movingRangeSigma = (a) => { let s = 0; for (let i = 1; i < a.length; i++) s += Math.abs(a[i] - a[i - 1]); return s / (a.length - 1) / D2; };

  /* Limits from baseline points. Returns null when there are too few, otherwise { center, at(point) → { sd, lcl, ucl } }.
     p   : Laney p-prime. Binomial spread for each day's volume, widened (or narrowed) by the day-to-day variation actually seen.
     xmr : individuals chart. Spread from the average moving range. */
  function limits(type, points, scale, minN, sigma, bounds) {
    const base = points.filter((p) => usable(p, scale, minN));
    if (base.length < MIN_BASELINE) return null;
    const [lo, hi] = bounds || [-Infinity, Infinity];
    const clamp = (v) => Math.min(hi, Math.max(lo, v));
    let center, sdAt;
    if (type === 'p') {
      const pbar = base.reduce((s, p) => s + p.x, 0) / base.reduce((s, p) => s + p.n, 0);
      const binom = (n) => Math.sqrt((pbar * (1 - pbar)) / n);
      if (!(pbar > 0 && pbar < 1)) return null;
      const sigmaZ = movingRangeSigma(base.map((p) => (p.x / p.n - pbar) / binom(p.n)));
      center = pbar * scale;
      sdAt = (p) => binom(p.n) * sigmaZ * scale;
    } else {
      const v = base.map((p) => valueOf(p, scale)), sd = movingRangeSigma(v);
      center = mean(v);
      sdAt = () => sd;
    }
    return { center, count: base.length, at: (p) => { const sd = sdAt(p); return { sd, lcl: clamp(center - sigma * sd), ucl: clamp(center + sigma * sd) }; } };
  }

  /* Run rules. Points below the minimum sample are skipped. A pattern flags the point that completes it and every
     point that continues it. Returns one array of reasons per point: 'outside', 'run8', 'trend6', 'two3'. */
  function signals(points, scale, minN, lim) {
    const out = points.map(() => []);
    if (!lim) return out;
    const seq = [];
    points.forEach((p, i) => { if (usable(p, scale, minN)) { const v = valueOf(p, scale), l = lim.at(p); seq.push({ i, v, l, side: Math.sign(v - lim.center), far: Math.abs(v - lim.center) > 2 * l.sd }); } });
    let run = 0, up = 1, down = 1;
    seq.forEach((s, j) => {
      const prev = seq[j - 1];
      run = s.side !== 0 && prev && prev.side === s.side ? run + 1 : s.side !== 0 ? 1 : 0;
      up = prev && s.v > prev.v ? up + 1 : 1;
      down = prev && s.v < prev.v ? down + 1 : 1;
      if (s.v > s.l.ucl || s.v < s.l.lcl) out[s.i].push('outside');
      if (run >= 8) out[s.i].push('run8');
      if (up >= 6 || down >= 6) out[s.i].push('trend6');
      if (s.far && seq.slice(Math.max(0, j - 2), j + 1).filter((q) => q.far && q.side === s.side).length >= 2) out[s.i].push('two3');
    });
    return out;
  }

  /* One category over the whole period: its value, and the standard error of that value from its own daily variation
     (ratio estimator with days as clusters). Used to ask: is this category further from the center than day-to-day variation explains? */
  function category(points, scale) {
    const p = points.filter((q) => q.x != null && q.n > 0), days = p.length;
    if (days < 2) return null;
    const X = p.reduce((s, q) => s + q.x, 0), N = p.reduce((s, q) => s + q.n, 0), K = p.reduce((s, q) => s + q.k, 0), r = X / N;
    const ss = p.reduce((s, q) => s + Math.pow(q.x - r * q.n, 2), 0);
    return { value: r * scale, n: N, k: K, days, se: (Math.sqrt((ss * days) / (days - 1)) / N) * scale };
  }

  root.SPC = { MIN_BASELINE, valueOf, usable, limits, signals, category };
})(typeof window !== 'undefined' ? window : globalThis);
