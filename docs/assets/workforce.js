/* Workforce calculations: ratios from totals. No page code, so it can be tested on its own. */
(function (root) {
  'use strict';
  const add = (p, q, keys) => { for (const k of keys) p[k] = (p[k] || 0) + (q[k] || 0); return p; };
  const DAY = ['n', 'nabs', 'npto', 'sched', 'worked', 'li', 'adh', 'av', 'occ', 'late', 'early', 'ext', 'aux', 'brk', 'lun', 'trn', 'coa', 'mtg', 'abs'];
  const IV = ['open', 'sbrk', 'slun', 'smtg', 'absent', 'avail', 'aux', 'abrk', 'alun', 'amtg'];
  // shrinkage reasons: key(s) in the daily table, label, planned or not
  const REASONS = [['brk', 'Breaks', true], ['lun', 'Lunch', true], ['aux', 'Unplanned unavailable', false], ['abs', 'Absence', false], ['coa', 'Coaching', true], ['mtg', 'Meetings', true], ['trn', 'Training', true]];
  const shrink = (p) => REASONS.reduce((s, r) => s + (p[r[0]] || 0), 0);
  const pct = (a, b) => (b > 0 ? (a / b) * 100 : null);
  // p is a day total; staffing also needs { open, req } in agent-minutes; forecast needs { o, f }
  const VALUE = { adherence: (p) => pct(p.adh, p.worked), conformance: (p) => pct(p.li, p.worked), shrinkage: (p) => pct(shrink(p), p.sched), occupancy: (p) => (p.av > 0 ? p.occ / p.av : null),
    staffing: (p) => (p.req > 0 && p.open > 0 ? ((p.open - p.req) / p.req) * 100 : null), forecast: (p) => (p.f > 0 ? ((p.o - p.f) / p.f) * 100 : null) };
  const N = { adherence: (p) => p.n || 0, conformance: (p) => p.n || 0, occupancy: (p) => p.n || 0, shrinkage: (p) => (p.n || 0) + (p.nabs || 0), staffing: (p) => p.req || 0, forecast: (p) => p.f || 0 };
  root.Workforce = { DAY, IV, REASONS, add, shrink, value: (m, p) => VALUE[m](p), n: (m, p) => N[m](p) };
})(typeof window !== 'undefined' ? window : globalThis);
