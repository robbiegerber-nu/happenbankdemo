/* The tools the dashboard chat may use. Each one runs the dashboards' own calculations on the dashboards' own data, so an
   answer is the number the dashboard shows. Every result says what it covers, how many records it rests on, whether that is
   too few, whether a change is beyond chance, and which dashboard to open. No page code and no AI here.
   Needs cx.js, drivers.js, workforce.js, selfservice.js, launch.js and Site (formatting and status rules). */
(function (root) {
  'use strict';
  const DASH = 'data/dashboards/', files = {};
  const get = async (u) => { const r = await fetch(u, { cache: 'no-cache' }); if (!r.ok) throw new Error(`${u}: ${r.status}`); const b = new Uint8Array(await r.arrayBuffer()); return JSON.parse(b[0] === 0x1f && b[1] === 0x8b ? await new Response(new Blob([b]).stream().pipeThrough(new DecompressionStream('gzip'))).text() : new TextDecoder().decode(b)); };
  const file = (u) => (files[u] ??= get(DASH + u).catch((e) => { delete files[u]; throw e; }));
  class ToolError extends Error {}
  const fail = (m) => { throw new ToolError(m); };
  const shift = (m, n) => { const [y, mo] = m.split('-').map(Number); return new Date(Date.UTC(y, mo - 1 + n, 1)).toISOString().slice(0, 7); };
  const lastDay = (m) => { const [y, mo] = m.split('-').map(Number); return new Date(Date.UTC(y, mo, 0)).toISOString().slice(0, 10); };
  const norm = (s) => String(s).toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();

  // metric -> where it comes from and the KPI definition it uses
  const M = {
    sl_phone: ['drivers', 'sl_phone'], sl_chat: ['drivers', 'sl_chat'], sl_email: ['drivers', 'sl_email'], sl_callback: ['drivers', 'sl_callback'], asa_phone: ['drivers', 'asa_phone'], abandon: ['drivers', 'abandon'],
    volume: ['drivers', 'volume'], aht_phone: ['drivers', 'aht_phone'], digital_share: ['drivers', 'digital_share'],
    csat: ['cx', 'csat'], nps: ['cx', 'nps'], ces: ['cx', 'ces'], fcr: ['cx', 'fcr'], repeat: ['cx', 'repeat'], complaints: ['cx', 'complaints'], response: ['cx', 'response'],
    adherence: ['workforce', 'adherence'], occupancy: ['workforce', 'occupancy'], conformance: ['workforce', 'conformance'], shrinkage: ['workforce', 'shrinkage'], staffing: ['scorecard', 'staffing'],
    ivr_containment: ['menu', 'ivr_containment'], no_agent: ['menu', 'no_agent'], contact_rate: ['customers', 'contact_rate']
  };
  const DIMS = { drivers: ['channel', 'queue', 'reason_group', 'reason', 'persona', 'segment', 'age_band'], cx: ['channel', 'queue', 'reason_group', 'reason', 'persona', 'segment'], workforce: ['agent_group', 'site', 'team'], scorecard: [], menu: ['persona'], customers: ['persona', 'segment', 'age_band'] };
  const SPLIT = { cx: ['complaint_category', 'root_cause', 'severity'] };

  // ---------- Names ----------
  let names = null;
  async function load() {
    if (names) return names;
    const [k, cx, dr, wf, si, pe, la] = await Promise.all([file('kpis.json'), file('cx/index.json'), file('drivers/index.json'), file('workforce/index.json.gz'), file('selfservice/index.json'), file('personas/index.json'), file('launch/index.json.gz')]);
    const kpi = Object.fromEntries([...k.kpis, ...k.extra].map((x) => [x.id, x])), list = (a) => a.map((x) => [x[0], x[1]]);
    const through = cx.data_through, months = cx.months.filter((m) => lastDay(m) <= through);
    names = { kpi, cx, dr, wf, si, pe, la, through, months, qch: Object.fromEntries(cx.queues.map((x) => [x[0], x[2]])), rgrp: Object.fromEntries(cx.reasons.map((x) => [x[0], x[2]])),
      dim: { channel: list(cx.channels), queue: list(cx.queues), reason: list(cx.reasons), reason_group: [...new Set(cx.reasons.map((x) => x[2]))].map((x) => [x, x]), persona: list(cx.personas),
        segment: Object.entries(cx.names.segment).map(([i, n]) => [+i, n]), age_band: dr.names.a.map((x) => [x.id, x.name]), agent_group: [[1, 'Phone'], [2, 'Chat'], [3, 'Email']], site: [...new Set(wf.teams.map((t) => t.site))].map((x) => [x, x]), team: wf.teams.map((t) => [t.id, t.name]) } };
    names.seg2 = { dr: Object.fromEntries(dr.names.s.map((x) => [x.name, x.id])), cx: Object.fromEntries(Object.entries(cx.names.segment).map(([i, n]) => [n, +i])), pe: Object.fromEntries(Object.entries(pe.names.s).map(([i, n]) => [n, +i])) };
    return names;
  }
  // a filter value given by name: exact, or the only one that contains it
  function resolve(dim, v) {
    const all = names.dim[dim]; if (!all) fail(`Unknown filter "${dim}".`);
    const n = norm(v), hit = all.filter((x) => norm(x[1]) === n), part = hit.length ? hit : all.filter((x) => norm(x[1]).includes(n));
    if (part.length === 1) return part[0];
    fail(`${part.length ? 'More than one' : 'No'} ${dim} matches "${v}". ${(part.length ? part : all).length <= 45 ? 'Choose from: ' + (part.length ? part : all).map((x) => x[1]).join('; ') + '.' : ''}`);
  }
  function period(from, to, what = 'period', most = 13) {
    if (!/^\d{4}-\d\d$/.test(from || '')) fail(`Give the ${what} as YYYY-MM months. Data is monthly here; days and weeks are not available to the chat.`);
    to = to || from; if (!/^\d{4}-\d\d$/.test(to) || to < from) fail(`The ${what} is not valid.`);
    const first = names.months[0], last = names.months[names.months.length - 1];
    if (from < first || to > last) fail(`The data has full months from ${Site.fmt.month(first)} to ${Site.fmt.month(last)}; ${from}${to !== from ? ' to ' + to : ''} is outside it.`);
    const ms = []; for (let m = from; m <= to; m = shift(m, 1)) ms.push(m); if (ms.length > most) fail(`At most ${most} months at a time.`); return ms;
  }
  const label = (ms) => (ms.length === 1 ? Site.fmt.month(ms[0]) : `${Site.fmt.month(ms[0])} – ${Site.fmt.month(ms[ms.length - 1])}`);
  function checkFilters(engine, f) {
    const out = []; for (const [d, v] of Object.entries(f || {})) { if (v == null || v === '') continue; if (!DIMS[engine].includes(d)) fail(`This metric cannot be filtered by ${d}. It can be filtered by: ${DIMS[engine].join(', ') || 'nothing'}.`); const r = resolve(d, v); out.push([d, r[0], r[1]]); } return out;
  }
  // ---------- Engines: each returns Map key -> { x, n, v, set } for one metric and a set of months ----------
  async function runDrivers(id, ms, flt, by) {
    const d = await Promise.all(ms.map((m) => file(`drivers/${m}.json.gz`))), K = Drivers.PARTS[id], out = new Map();
    for (const { cols: c } of d) {
      const val = { channel: (i) => names.qch[c.q[i]], queue: (i) => c.q[i], reason: (i) => c.r[i], reason_group: (i) => names.rgrp[c.r[i]], persona: (i) => c.p[i], segment: (i) => c.s[i], age_band: (i) => c.a[i] };
      const tests = flt.map(([k, v, nm]) => { const want = k === 'segment' ? names.seg2.dr[nm] : v; return (i) => val[k](i) === want; });
      for (const [k, p] of Drivers.group(c, id, tests, by ? val[by] : () => 'all', (i) => names.qch[c.q[i]])) { const t = out.get(k) || (out.set(k, { x: 0, n: 0 }), out.get(k)); t.x += p.x; t.n += p.n; }
    }
    for (const t of out.values()) { t.v = Drivers.value(t, K.scale); t.share = K.scale === 100; }
    return out;
  }
  async function runCx(id, ms, flt, by) {
    const d = await Promise.all(ms.map((m) => file(`cx/${m}.json.gz`))), out = new Map(), key = { channel: (c, j) => names.qch[c.q[j]] || 0, queue: (c, j) => c.q[j], reason: (c, j) => c.r[j], reason_group: (c, j) => names.rgrp[c.r[j]] || 0, persona: (c, j) => c.p[j], segment: (c, j) => c.s[j], complaint_category: (c, j) => c.cat && c.cat[j], root_cause: (c, j) => c.cause && c.cause[j], severity: (c, j) => c.sev && c.sev[j] };
    const ok = (c, j) => flt.every(([k, v, nm]) => key[k](c, j) === (k === 'segment' ? names.seg2.cx[nm] : v)), at = (k) => out.get(k) || (out.set(k, { set: CX.blank() }), out.get(k)), split = by && SPLIT.cx.includes(by); let offered = 0;
    for (const x of d) {
      for (let j = 0; j < x.c.q.length; j++) if (ok(x.c, j)) { if (split) offered += x.c.o[j]; else CX.contact(at(by ? key[by](x.c, j) : 'all').set, x.c, j); }
      if (!split) for (let j = 0; j < x.v.q.length; j++) if (ok(x.v, j)) CX.survey(at(by ? key[by](x.v, j) : 'all').set, x.v, j);
      for (let j = 0; j < (x.x.q || []).length; j++) if (ok(x.x, j)) CX.complaint(at(by ? key[by](x.x, j) : 'all').set);
    }
    for (const t of out.values()) { if (split) t.set.complaints.n = offered; const p = t.set[id]; t.x = p.x; t.n = p.n; t.v = CX.value(id, t.set); }
    return out;
  }
  async function runWorkforce(id, ms, flt, by) {
    const w = names.wf, col = Object.fromEntries(w.keys.map((k, i) => [k, i])), T = Object.fromEntries(w.teams.map((t) => [t.id, t])), out = new Map(), key = { agent_group: (t) => t.ch, site: (t) => t.site, team: (t) => t.id };
    for (const r of w.days) { if (!ms.includes(r[col.d].slice(0, 7))) continue; const t = T[r[col.t]]; if (!flt.every(([k, v]) => key[k](t) === v)) continue; const k = by ? key[by](t) : 'all', p = out.get(k) || (out.set(k, { p: {} }), out.get(k)); Workforce.add(p.p, Object.fromEntries(Workforce.DAY.map((c) => [c, r[col[c]]])), Workforce.DAY); }
    for (const t of out.values()) { t.v = Workforce.value(id, t.p); t.n = Workforce.n(id, t.p); }
    return out;
  }
  async function runScorecard(id, ms) {
    if (ms.length > 1) fail('This measure is available for one month at a time.'); const e = await file('executive.json'), r = e.rows.find((x) => x.k === id && x.g == null && x.m === ms[0]);
    return new Map(r ? [['all', { v: r.v, n: r.n }]] : []);
  }
  async function runMenu(id, ms, flt, by) {
    const out = new Map(), at = (k) => out.get(k) || (out.set(k, { done: 0, agent: 0, o: 0 }), out.get(k)), K = Object.fromEntries(names.si.ivr_keys.map((k, i) => [k, i])), p0 = flt.length ? flt[0][1] : null;
    for (const r of names.si.ivr) { if (!ms.includes(r[K.m]) || (p0 && r[K.p] !== p0)) continue; const t = at(by ? r[K.p] : 'all'); if (r[K.t]) t.done += r[K.n]; else t.agent += r[K.n]; }
    if (id === 'no_agent') for (const { cols: c } of await Promise.all(ms.map((m) => file(`selfservice/${m}.json.gz`)))) for (let j = 0; j < c.p.length; j++) if (!p0 || c.p[j] === p0) at(by ? c.p[j] : 'all').o += c.o[j];
    for (const t of out.values()) { t.x = t.done; t.n = t.done + (id === 'no_agent' ? t.o : t.agent); t.v = SelfService.ratio(t.x, t.n); t.share = true; }
    return out;
  }
  async function runCustomers(id, ms, flt, by) {
    const pe = names.pe, cell = new Map(pe.cells.map((c) => [c[0], { persona: c[1], segment: c[2], age_band: c[3] }])), want = flt.map(([k, v, nm]) => [k, k === 'segment' ? names.seg2.pe[nm] : v]), ok = (c) => want.every(([k, v]) => c[k] === v), out = new Map(), at = (k) => out.get(k) || (out.set(k, { x: 0, n: 0 }), out.get(k)), qOf = (m) => `${m.slice(0, 5)}${String(Math.floor((+m.slice(5) - 1) / 3) * 3 + 1).padStart(2, '0')}`;
    for (const m of ms) if (!pe.quarters.includes(qOf(m))) fail('The contact rate is available for full quarters only.');
    for (const { cols: c } of await Promise.all(ms.map((m) => file(`personas/${m}.json.gz`)))) for (let j = 0; j < c.x.length; j++) { const e = cell.get(c.x[j]); if (ok(e)) at(by ? e[by] : 'all').x += c.o[j]; }
    for (const m of ms) for (const [q, id2, n] of pe.customers) if (q === qOf(m)) { const e = cell.get(id2); if (ok(e)) at(by ? e[by] : 'all').n += n; }
    for (const t of out.values()) t.v = SelfService.ratio(t.x, t.n);
    return out;
  }
  const RUN = { drivers: runDrivers, cx: runCx, workforce: runWorkforce, scorecard: runScorecard, menu: runMenu, customers: runCustomers };
  function metric(id) { const m = M[id]; if (!m) fail(`Unknown metric "${id}". Choose from: ${Object.keys(M).join(', ')}.`); return { engine: m[0], kpi: names.kpi[m[1]] }; }
  // is a difference beyond chance (3 standard errors)? null when it cannot be tested from totals
  function beyond(engine, id, a, b) { if (!a || !b) return null; if (engine === 'cx') return CX.beyond(id, a.set, b.set); if (a.share && b.share) return SelfService.beyond(a.x, a.n, b.x, b.n); return null; }
  const basis = { drivers: (k) => (['csat', 'nps'].includes(k) ? 'surveys' : 'contacts'), cx: (k) => (['csat', 'nps', 'ces'].includes(k) ? 'surveys' : 'contacts'), workforce: () => 'agent-days', scorecard: () => null, menu: (k) => (k === 'no_agent' ? 'requests' : 'menu sessions'), customers: () => 'customer-months' };
  // how one period's result compares with another's, and whether the difference is beyond chance
  function compare(kpi, engine, id, t, b, few) {
    const c = Site.fmt.change(t.v, b.v, kpi.format), real = beyond(engine, id, t, b);
    return { change: c.flat ? 'no change' : c.text, beyond_chance: real, reading: few ? 'too few records to compare' : c.flat ? 'no change' : real === false ? 'within chance, so it can’t be told apart from no change' : real ? { better: 'improved, beyond chance', worse: 'slipped, beyond chance', neutral: 'changed, beyond chance' }[Site.changeQuality(kpi, t.v, b.v, c)] : 'chance not tested for this measure' };
  }
  // what the page draws. Hidden from JSON, so it is never sent to the AI and the AI cannot change it
  const withChart = (out, chart) => Object.defineProperty(out, 'chart', { value: chart, enumerable: false });
  const eventsIn = async (ms) => (await file('events.json')).events.filter((e) => e.start <= lastDay(ms[ms.length - 1]) && e.end >= ms[0] + '-01');
  const eventName = (e) => `${e.name} (${Site.fmt.date(e.start)}${e.end !== e.start ? ' – ' + Site.fmt.date(e.end) : ''})`;
  // KPIs that cover two channels together have one target, for the combined figure only
  const PAIRED = ['abandon', 'sl_email'];
  function show(kpi, engine, id, t, oneChannel) {
    const few = t.n != null && basis[engine](id) != null && t.n < kpi.minN, st = few ? 'none' : Site.statusOf(kpi, t.v);
    return { value: Site.fmt.value(t.v, kpi.format, true), raw: t.v, n: t.n == null || basis[engine](id) == null ? null : Math.round(t.n), counted: basis[engine](id), too_few: few, ...(few ? { minimum_n: kpi.minN } : {}), records: t.n == null || basis[engine](id) == null ? undefined : `${Site.fmt.count(t.n)} ${basis[engine](id)}`, ...(few ? { target: 'not applied, too few records' } : oneChannel && PAIRED.includes(id) ? { target: 'set for both channels together, not for one' } : kpi.target == null ? { target: 'this KPI has no target' } : { target: kpi.targetLabel, status: Site.STATUS_WORD[st] }) };
  }
  function link(engine, id, ms, flt) {
    const m = ms[ms.length - 1], p = new URLSearchParams(), f = Object.fromEntries(flt.map(([k, v]) => [k, v]));
    if (engine === 'cx') { p.set('m', m); p.set('metric', id); for (const [k, u] of [['channel', 'ch'], ['queue', 'q'], ['reason_group', 'rg'], ['reason', 'r'], ['segment', 's'], ['persona', 'p']]) if (f[k] != null) p.set(u, f[k]); return ['Customer experience', 'cx.html?' + p]; }
    if (engine === 'menu') { p.set('m', m); p.set('metric', id === 'no_agent' ? 'no_agent' : 'contain'); if (f.persona) p.set('p', f.persona); return ['Self-service & channel shift', 'selfservice.html?' + p]; }
    if (engine === 'customers') { p.set('q', `${m.slice(0, 5)}${String(Math.floor((+m.slice(5) - 1) / 3) * 3 + 1).padStart(2, '0')}`); p.set('metric', 'rate'); if (f.persona) p.set('p', f.persona); return ['Customer & persona insights', 'personas.html?' + p]; }
    // the scorecard and coaching pages show whole months; the workforce page shows 30 days, so its figure can differ slightly
    if (engine === 'workforce' && !flt.length && ['adherence', 'occupancy'].includes(id)) { p.set('m', m); p.set('kpi', id); return ['Executive scorecard', 'executive.html?' + p]; }
    if (engine === 'workforce' && id === 'adherence' && f.agent_group && ms.length === 1) { p.set('end', m); p.set('ch', f.agent_group); if (f.team) p.set('team', f.team); return ['Agent & team coaching', 'coaching.html?' + p]; }
    if (engine === 'workforce') { p.set('end', m); if (f.agent_group) p.set('ch', f.agent_group); if (f.team) p.set('team', f.team); p.set('metric', id); return ['Workforce management (shows 30 days to the month end, so it can differ slightly)', 'workforce.html?' + p]; }
    if (engine === 'drivers' && flt.length) { p.set('m', m); p.set('metric', id); return ['Performance driver explorer', 'drivers.html?' + p]; }
    p.set('m', m); p.set('kpi', id); return ['Executive scorecard', 'executive.html?' + p];
  }
  const source = (engine, id, ms, flt, kpi) => { const [name, href] = link(engine, id, ms, flt); return { dashboard: name, link: href, kpi: kpi.name, period: label(ms), filters: flt.map(([k, , n]) => `${k.replace('_', ' ')}: ${n}`), definition: kpi.definition }; };

  // ---------- Tools ----------
  async function get_metric(a) {
    await load(); const { engine, kpi } = metric(a.metric), ms = period(a.from, a.to), flt = checkFilters(engine, a.filters), t = (await RUN[engine](a.metric, ms, flt)).get('all');
    if (!t || t.v == null) fail('There are no records for that selection.');
    const out = { metric: kpi.name, ...show(kpi, engine, a.metric, t, flt.some((x) => x[0] === 'channel' || x[0] === 'queue')), source: source(engine, a.metric, ms, flt, kpi) };
    if (a.compare_from) {
      const cs = period(a.compare_from, a.compare_to, 'comparison period'), b = (await RUN[engine](a.metric, cs, flt)).get('all'); if (!b || b.v == null) fail('There are no records for the comparison period.');
      const s = show(kpi, engine, a.metric, b, flt.some((x) => x[0] === 'channel' || x[0] === 'queue'));
      out.comparison = { period: label(cs), ...s, ...compare(kpi, engine, a.metric, t, b, s.too_few || out.too_few) };
    }
    const ev = await eventsIn(ms); if (ev.length) out.events_in_period = ev.map(eventName);
    return out;
  }
  // One KPI by month. Totals are also given per day, because months differ in length (Style Guide).
  async function trend(a) {
    await load(); const { engine, kpi } = metric(a.metric), flt = checkFilters(engine, a.filters), one = flt.some((x) => x[0] === 'channel' || x[0] === 'queue'), total = kpi.format === 'count', surveys = ['csat', 'nps', 'ces'].includes(a.metric);
    const end = engine === 'customers' ? shift(names.pe.quarters[names.pe.quarters.length - 1], 2) : names.months[names.months.length - 1], to = a.to || end, first = engine === 'customers' ? names.pe.quarters[0] : names.months[0], from = a.from || (/^\d{4}-\d\d$/.test(to) && shift(to, -12) > first ? shift(to, -12) : first);
    const ms = period(from, to, 'period', engine === 'drivers' ? 13 : 36); if (ms.length < 3) fail('A trend needs at least 3 months. Use get_metric with a comparison for fewer.');
    const at = await Promise.all(ms.map(async (m) => (await RUN[engine](a.metric, [m], flt)).get('all')));
    const V = (v) => Site.fmt.value(v, kpi.format, true), pts = ms.map((m, i) => { const t = at[i]; if (!t || t.v == null) return { m, v: null, t: null }; const s = show(kpi, engine, a.metric, t, one); return { m, t, s, few: s.too_few, total: t.v, v: s.too_few ? null : total ? t.v / Site.monthDays(m) : t.v, n: s.n }; });
    const ok = pts.filter((p) => p.v != null); if (ok.length < 2) fail('There are too few records in too many months to show a trend for that selection. Offer a wider view.');
    const word = (p) => (total ? `${V(p.total)} (${V(p.v)} a day)` : V(p.v)), hi = ok.reduce((x, p) => (p.v > x.v ? p : x)), lo = ok.reduce((x, p) => (p.v < x.v ? p : x)), A = ok[0], Z = ok[ok.length - 1], aimed = kpi.target != null && !(one && PAIRED.includes(a.metric)), src = source(engine, a.metric, ms, flt, kpi);
    const cmp = compare(kpi, engine, a.metric, total ? { ...Z.t, v: Z.v } : Z.t, total ? { ...A.t, v: A.v } : A.t, false), ev = await eventsIn(ms);
    const out = { metric: kpi.name, months: pts.map((p) => (p.t == null ? { month: Site.fmt.month(p.m), value: 'no records' } : { month: Site.fmt.month(p.m), value: p.s.value, raw: p.total, ...(total && !p.few ? { per_day: V(p.v), raw_per_day: p.v } : {}), ...(p.n != null && !total ? { n: p.n } : {}), ...(p.few ? { too_few: true } : aimed ? { status: p.s.status } : {}) })),
      target: aimed ? kpi.targetLabel : kpi.target == null ? 'this KPI has no target' : 'set for both channels together, not for one', ...(aimed ? { months_on_target: `${ok.filter((p) => p.s.status === Site.STATUS_WORD.good).length} of ${ok.length}` } : {}), ...(surveys || pts.some((p) => p.few) ? { counted: basis[engine](a.metric) || undefined, minimum_n: kpi.minN } : {}),
      highest: `${word(hi)} in ${Site.fmt.month(hi.m)}`, lowest: `${word(lo)} in ${Site.fmt.month(lo.m)}`,
      first_to_last: { from: Site.fmt.month(A.m), from_value: word(A), to: Site.fmt.month(Z.m), to_value: word(Z), ...cmp, ...(total ? { change_is: 'in the average per day' } : {}) },
      events_in_period: ev.map(eventName), note: 'The page shows these months as a line chart. Only first_to_last has been tested for chance, where it says so: do not call other rises or falls real, and do not describe a steady direction.', source: src };
    return withChart(out, { kind: 'line', id: a.metric, kpi, total, target: aimed ? kpi.target : null, counted: basis[engine](a.metric), through: names.through, period: label(ms), filters: src.filters, pts: pts.map(({ m, v, total: whole, n, few }) => ({ m, v, total: whole ?? null, n: n ?? null, few: !!few })), events: ev });
  }
  async function breakdown(a) {
    await load(); const { engine, kpi } = metric(a.metric), ms = period(a.from, a.to), flt = checkFilters(engine, a.filters), dims = [...DIMS[engine], ...(a.metric === 'complaints' ? SPLIT.cx : [])];
    if (!dims.includes(a.by)) fail(`This metric cannot be split by ${a.by}. It can be split by: ${dims.join(', ') || 'nothing'}.`);
    const map = await RUN[engine](a.metric, ms, flt, a.by), split = SPLIT.cx.includes(a.by), lab = split ? names.cx.names[{ complaint_category: 'category', root_cause: 'cause', severity: 'severity' }[a.by]] : null, segs = a.by === 'segment' ? Object.fromEntries(Object.entries(names.seg2[{ drivers: 'dr', cx: 'cx', customers: 'pe' }[engine]]).map(([n, i]) => [i, n])) : null;
    const nm = (k) => (split ? lab[k] : segs ? segs[k] : (names.dim[a.by].find((x) => x[0] === k) || [])[1]) || 'Not identified';
    let rows = [...map].filter(([, t]) => t.v != null).map(([k, t]) => ({ name: nm(k), ...show(kpi, engine, a.metric, t, ['channel', 'queue'].includes(a.by) || flt.some((x) => x[0] === 'channel' || x[0] === 'queue')), ...(a.metric === 'volume' || split ? { count: t.x } : {}) }));
    const tot = rows.reduce((s, r) => s + (r.count || 0), 0); if (tot) rows.forEach((r) => { r.share = Site.fmt.value(r.count / tot * 100, 'pct'); });
    const dir = a.order === 'lowest' ? 1 : -1; rows.sort((x, y) => x.too_few - y.too_few || (x.too_few ? x.name.localeCompare(y.name) : dir * (x.raw - y.raw))); const n = Math.min(Math.max(1, a.limit || 10), 15); rows.forEach((r) => { if (r.count != null) r.count_shown = Site.fmt.count(r.count); });
    const pair = PAIRED.includes(a.metric) && a.by === 'channel' ? (await RUN[engine](a.metric, ms, flt)).get('all') : null;
    const src = source(engine, a.metric, ms, flt, kpi), out = { metric: kpi.name, ...(pair ? { combined: show(kpi, engine, a.metric, pair) } : {}), by: a.by, order: a.order === 'lowest' ? 'lowest first' : 'highest first', groups: rows.length, rows: rows.slice(0, n), shown: Math.min(n, rows.length), note: rows.length && rows.every((r) => r.too_few) ? 'Every group has too few records. Do not list their values or name a highest or lowest.' : rows.some((r) => r.too_few) ? 'Groups marked too_few are last, in name order, and must not be ranked.' : undefined, source: src };
    // no chart of teams: nothing here ranks them
    if (!a.chart || ['team', 'site', 'agent_group'].includes(a.by) || rows.filter((x) => !x.too_few).length < 2) return out;
    const aimed = kpi.target != null && !PAIRED.includes(a.metric); out.chart_note = 'The page shows these rows as a bar chart.';
    return withChart(out, { kind: 'bar', id: a.metric, kpi, title: split ? 'Complaints' : null, by: a.by.replace('_', ' '), order: out.order, groups: rows.length, target: aimed ? kpi.target : null, counted: basis[engine](a.metric), through: names.through, period: label(ms), filters: src.filters, rows: rows.slice(0, n).map((x) => ({ name: x.name, v: x.too_few ? null : x.count ?? x.raw, text: x.too_few ? '' : x.count != null ? Site.fmt.count(x.count) : x.value, share: x.share || '', n: x.n, few: x.too_few })) });
  }
  const HAP = [['Resolved on first contact', 1, true], ['Not transferred', 2, false], ['Not escalated', 4, false], ['Answered within the service level', 8, true], ['No repeat contact within 7 days', 16, false]];
  async function score_by_outcome(a) {
    await load(); const id = a.metric || 'csat'; if (!['csat', 'nps', 'ces'].includes(id)) fail('Choose csat, nps or ces.'); const ms = period(a.from, a.to), kpi = names.kpi[id], d = await Promise.all(ms.map((m) => file(`cx/${m}.json.gz`)));
    const rows = HAP.map(([name, bit, yes]) => { const g = CX.blank(), o = CX.blank(); for (const { v } of d) for (let j = 0; j < v.q.length; j++) CX.survey((!!(v.hap[j] & bit)) === yes ? g : o, v, j); const sh = (t) => { const p = t[id]; return { value: Site.fmt.value(CX.value(id, t), kpi.format, true), raw: CX.value(id, t), n: p.n, too_few: p.n < kpi.minN }; }; return { outcome: name, when_it_did: sh(g), when_it_did_not: sh(o), beyond_chance: CX.beyond(id, g, o) }; });
    return { metric: kpi.name, rows, note: 'These happened on the same contact or in the 7 days after. They show what goes together, not what causes what.', source: source('cx', id, ms, [], kpi) };
  }
  async function launch_impact(a) {
    await load(); const I = names.la, n = norm(a.launch || ''), hit = I.launches.filter((l) => norm(l.name) === n), part = hit.length ? hit : I.launches.filter((l) => n && norm(l.name).includes(n)); if (part.length !== 1) fail(`${part.length ? 'More than one launch matches' : 'No launch matches'} "${a.launch}". Choose from: ${I.launches.map((l) => l.name).join('; ')}.`);
    const l = part[0], DAY = 864e5, t = Date.parse(l.date), near = I.launches.filter((x) => x.id !== l.id && Date.parse(x.date) >= t - 70 * DAY && Date.parse(x.date) <= t + 91 * DAY), touched = new Set([...l.reasons, ...near.flatMap((x) => x.reasons)]), rows = I.rows.map((r) => Object.fromEntries(I.keys.map((k, i) => [k, r[i]]))).filter((r) => r.l === l.id), aff = Launch.weeks(rows, (r) => l.reasons.includes(r)), oth = Launch.weeks(rows, (r) => !touched.has(r)), s = Launch.summary(Launch.series('volume', aff, oth)), kp = { aht: 'aht', fcr: 'fcr', csat: 'csat', repeat: 'repeat' }, ch = {};
    if (!s) fail('That launch has no full week of data yet.');
    for (const [m, id] of Object.entries(kp)) { const c = Launch.change(m, aff, oth), k = names.kpi[id]; if (!c) continue; const d = Site.fmt.change(c.v, c.e, k.format), o = c.other == null ? null : Site.fmt.change(c.e + c.other, c.e, k.format); ch[m] = { metric: k.name, value: Site.fmt.value(c.v, k.format, true), raw: c.v, baseline: Site.fmt.value(c.e, k.format, true), raw_baseline: c.e, change: d.flat ? 'no change' : d.text, too_few: c.n < k.minN, reading: c.sure ? 'beyond chance' : 'within chance, so it can’t be told apart from no change', other_reasons_changed: o ? (o.flat ? 'no change' : o.text) : null }; }
    const pc = (v) => (v > 0 ? '+' : v < 0 ? '−' : '') + Math.abs(v).toFixed(1) + '%', sg = (v) => (v > 0 ? '+' : v < 0 ? '−' : '') + Site.fmt.count(Math.abs(v)), over = near.filter((x) => x.reasons.some((r) => l.reasons.includes(r)));
    return { launch: l.name, date: Site.fmt.date(l.date), type: l.type, planned_impact: l.planned, about: l.about, contacts: { extra_first_weeks: sg(s.extra4), against_expected: pc(s.pct4), weeks_counted: s.weeks4, peak: `${pc(s.peak)} in week ${s.peakW}`, back_to_normal: !s.any ? 'never above the normal range' : s.back != null ? `week ${s.back}` : `not for two weeks in a row by week ${s.last}` }, changes: ch, overlapping_launches: over.map((x) => x.name), note: `Weeks 0–3 after launch against the 6 weeks before it was announced, for the contact reasons it was expected to affect. It shows timing, not proof of cause.${over.length ? ' Other launches in the window share some of these reasons.' : ''}`, source: { dashboard: 'Product launch impact', link: `launch.html?l=${l.id}`, kpi: 'Launch impact', period: `8 weeks before to week ${s.last} after ${Site.fmt.date(l.date)}`, filters: [], definition: 'Expected volume follows contact reasons the launch did not touch.' } };
  }
  // who each persona is meant to be: definitions, not measured results
  async function describe_personas(a) {
    await load(); const all = names.pe.personas, n = norm((a && a.persona) || ''), hit = n ? all.filter((x) => norm(x.name) === n) : all, list = hit.length ? hit : all.filter((x) => norm(x.name).includes(n));
    if (!list.length || (n && list.length > 1)) fail(`${list.length ? 'More than one' : 'No'} persona matches "${a.persona}". Choose from: ${all.map((x) => x.name).join('; ')}.`);
    return { profile: true, personas: list.map((x) => ({ name: x.name, description: x.about, preferred_channel: x.channel, digital_comfort: x.digital, price_sensitivity: x.price, typical_ages: x.ages })), digital_comfort_scale: '1 (low) to 5 (high)', price_sensitivity_means: 'sensitivity to fees and rates',
      note: 'These say how each persona is defined. They are not measured results, and they do not explain why a result moved.',
      source: { dashboard: 'Customer & persona insights', link: 'personas.html' + (n ? '?p=' + list[0].id : ''), kpi: 'Persona profiles', period: 'Definitions, not results', filters: n ? [list[0].name] : [], definition: 'From the persona table.' } };
  }
  async function describe_data(a) {
    await load(); const one = a && a.metric ? [a.metric] : Object.keys(M);
    return { full_months: `${Site.fmt.month(names.months[0])} to ${Site.fmt.month(names.months[names.months.length - 1])}`, data_through: Site.fmt.date(names.through), metrics: one.map((id) => { const { engine, kpi } = metric(id); return { id, name: kpi.name, definition: kpi.definition, formula: kpi.formula, target: kpi.target == null ? 'no target' : kpi.targetLabel, filters: DIMS[engine], ...(id === 'complaints' ? { also_split_by: SPLIT.cx } : {}) }; }), launches: names.la.launches.map((l) => `${l.name} (${Site.fmt.date(l.date)})`), events: (await file('events.json')).events.filter((e) => e.span === 'Period').map((e) => `${e.name} (${Site.fmt.date(e.start)} – ${Site.fmt.date(e.end)})`),
      not_available: ['Days, weeks and times of day (see the Service & access and Workforce dashboards)', 'Individual agents or customers (personas are groups, so they are available)', 'Forecasts', 'Revenue, balances or any financial results', 'Definitions of the customer segments: only their names are recorded (personas do have profiles: use describe_personas)', 'Where in the phone menu a caller gave up', 'Anything before January 2024', 'Anything about the real Happen Bank: all data is simulated'] };
  }
  const str = (d, e) => ({ type: 'string', description: d, ...(e ? { enum: e } : {}) }), MON = 'Month as YYYY-MM', FIL = { type: 'object', description: 'Filters by name, e.g. {"channel":"Phone","persona":"Credit Builder"}. Allowed names depend on the metric; describe_data lists them.', properties: Object.fromEntries([...new Set(Object.values(DIMS).flat())].map((d) => [d, { type: 'string' }])), additionalProperties: false };
  const obj = (properties, required) => ({ type: 'object', properties, required, additionalProperties: false });
  const TOOLS = [
    { name: 'get_metric', description: 'One KPI for a month or range of months, with its target, status, number of records and, if a comparison period is given, the change and whether it is beyond chance.', input_schema: obj({ metric: str('KPI id', Object.keys(M)), from: str(MON), to: str(MON + '. Leave out for a single month'), filters: FIL, compare_from: str(MON + ' to compare with'), compare_to: str(MON) }, ['metric', 'from']), run: get_metric },
    { name: 'breakdown', description: 'One KPI split by a dimension, highest or lowest first. Groups with too few records come last and must not be ranked.', input_schema: obj({ metric: str('KPI id', Object.keys(M)), by: str('Dimension', [...new Set([...Object.values(DIMS).flat(), ...SPLIT.cx])]), from: str(MON), to: str(MON), filters: FIL, order: str('Order', ['highest', 'lowest']), limit: { type: 'integer', description: 'Rows, 1 to 15' }, chart: { type: 'boolean', description: 'Also show the rows on the page as a bar chart. Not available for teams, sites or agent groups' } }, ['metric', 'by', 'from']), run: breakdown },
    { name: 'trend', description: 'One KPI month by month, shown on the page as a line chart, with the highest and lowest month and whether the change from the first month to the last is beyond chance. At least 3 months; service level, speed of answer, abandon rate, contacts, handle time and digital share at most 13 at a time. Without dates it gives the last 13 full months.', input_schema: obj({ metric: str('KPI id', Object.keys(M)), from: str(MON), to: str(MON), filters: FIL }, ['metric']), run: trend },
    { name: 'score_by_outcome', description: 'Survey scores by what happened on the contact: resolved first time, transferred, escalated, within service level, contacted again. Association only, not cause.', input_schema: obj({ metric: str('Survey score', ['csat', 'nps', 'ces']), from: str(MON), to: str(MON) }, ['from']), run: score_by_outcome },
    { name: 'launch_impact', description: 'What happened to contacts, handle time, resolution, satisfaction and repeat contacts after a product launch, against its own baseline.', input_schema: obj({ launch: str('Launch name or part of it') }, ['launch']), run: launch_impact },
    { name: 'describe_personas', description: 'Who the customer personas are: the description, preferred channel, digital comfort, price sensitivity and typical ages of each. Definitions, not results.', input_schema: obj({ persona: str('One persona name, or leave out for all') }, []), run: describe_personas },
    { name: 'describe_data', description: 'What the data covers: months, KPIs with definitions, targets and allowed filters, launches, events, and what is not available.', input_schema: obj({ metric: str('One KPI id, or leave out for all', Object.keys(M)) }, []), run: describe_data }
  ];
  /* Runs a tool by name. Never throws: a problem the asker can fix comes back as { error }. */
  async function run(name, input) {
    const t = TOOLS.find((x) => x.name === name); if (!t) return { error: `There is no tool called ${name}.` };
    try { return await t.run(input || {}); } catch (e) { return { error: e instanceof ToolError ? e.message : 'The data could not be read. ' + e.message }; }
  }
  root.ChatTools = { TOOLS, run, definitions: TOOLS.map(({ name, description, input_schema }) => ({ name, description, input_schema })) };
})(typeof window !== 'undefined' ? window : globalThis);
