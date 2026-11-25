// Works out, from the source tables (schema cc), what a logged chat request should have returned, and compares.
// The SQL is built from fixed templates: the AI writes none of it. It never reads the dash tables behind the dashboards.
// Only the display rules (rounding, target words) are shared with the page, through docs/assets/site.js.
import { spawnSync } from 'node:child_process'; import fs from 'node:fs'; import path from 'node:path'; import vm from 'node:vm'; import { fileURLToPath } from 'node:url';
const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..'), PSQL = 'C:\\Program Files\\PostgreSQL\\18\\bin\\psql.exe';
const box = vm.createContext({ window: {}, document: { documentElement: {}, addEventListener() {} }, localStorage: { getItem() { return null; } }, matchMedia: () => ({ matches: false, addEventListener() {} }) }); box.window = box;
vm.runInContext(fs.readFileSync(path.join(root, 'docs/assets/site.js'), 'utf8'), box); export const Site = box.Site;
const kj = JSON.parse(fs.readFileSync(path.join(root, 'docs/data/dashboards/kpis.json'), 'utf8')), KPI = Object.fromEntries([...kj.kpis, ...kj.extra].map((k) => [k.id, k]));

// ---------- The database ----------
export function psql(sql, readOnly = false) {
  const r = spawnSync(PSQL, ['-w', '-h', 'localhost', '-U', 'postgres', '-d', process.env.HAPPEN_DB || 'happen_demo', '-q', '-At', '-v', 'ON_ERROR_STOP=1', '-f', '-'], { input: sql, encoding: 'utf8', maxBuffer: 1e9, env: { ...process.env, PGCLIENTENCODING: 'UTF8', ...(readOnly ? { PGOPTIONS: '-c default_transaction_read_only=on' } : {}) } });
  if (r.status !== 0) throw new Error('Postgres: ' + (r.stderr || r.error)); return r.stdout.trim();
}
const cache = new Map();
function rows(sql) { if (!cache.has(sql)) cache.set(sql, JSON.parse(psql(`SELECT coalesce(json_agg(q), '[]') FROM (\n${sql}\n) q;`, true))); return cache.get(sql); }

// ---------- Templates ----------
// every fact row has x (numerator), den (denominator), n (records) and xx (sum of squares, for the chance test)
const q = (s) => "'" + String(s).replace(/'/g, "''") + "'", NI = 'Not identified';
const last = (m) => new Date(Date.UTC(+m.slice(0, 4), +m.slice(5), 0)).getUTCDate(), lo = (m) => m.replace('-', '') + '01', hi = (m) => m.replace('-', '') + last(m), iso = (m) => `${m}-${last(m)}`;
const ELIG = '(c.answered OR (c.abandoned AND NOT c.short_abandon))';
const contact = (cond, x, den) => ({ from: 'cc.contact c', key: 'c', cust: 'c.customer_id', cond, x, den });
const survey = (x, den, xx) => ({ from: 'cc.survey_response v JOIN cc.contact c USING (contact_id)', key: 'v', cust: 'v.customer_id', cond: '', x, den, xx });
const sl = (ch) => [contact(`c.channel_id IN (${ch}) AND ${ELIG}`, 'c.met_service_level::int', '1')];
// metric -> facts, scale, kind of chance test ('cx' = variance from xx, 'share' = two shares, null = not tested)
const F = {
  sl_phone: [sl('1'), 100, 'share'], sl_chat: [sl('2'), 100, 'share'], sl_email: [sl('3, 5'), 100, 'share'], sl_callback: [sl('4'), 100, 'share'],
  asa_phone: [[contact('c.channel_id = 1 AND c.answered', 'c.queue_wait_sec', '1')], 1, null], aht_phone: [[contact('c.channel_id = 1 AND c.answered', 'c.handle_sec', '1')], 1, null],
  abandon: [[contact('c.channel_id IN (1, 2)', 'c.abandoned::int', '1')], 100, 'share'], digital_share: [[contact('', '(c.channel_id IN (2, 3, 5))::int', '1')], 100, 'share'], volume: [[contact('', '1', '1')], null, null],
  csat: [[survey('(v.csat >= 4)::int', '1')], 100, 'cx'], ces: [[survey('v.ces', '1', 'v.ces * v.ces')], 1, 'cx'],
  nps: [[survey('CASE WHEN v.nps >= 9 THEN 1 WHEN v.nps <= 6 THEN -1 ELSE 0 END', '1', 'CASE WHEN v.nps >= 9 OR v.nps <= 6 THEN 1 ELSE 0 END')], 100, 'cx'],
  fcr: [[contact('c.answered', 'coalesce(c.first_contact_resolved, false)::int', '1')], 100, 'cx'], repeat: [[contact('c.customer_id IS NOT NULL', 'c.repeat_within_7d::int', '1')], 100, 'cx'],
  response: [[contact('c.answered', '0', '1'), survey('1', '0')], 100, 'cx'],
  complaints: [[contact('', '0', '1'), { from: 'cc.complaint k LEFT JOIN cc.contact c USING (contact_id)', key: 'k', cust: 'k.customer_id', cond: '', x: '1', den: '0' }], 1000, 'count'],
  ivr_containment: [[{ menu: true, x: 'i.contained::int', den: '1' }], 100, 'share'], no_agent: [[{ menu: true, cond: 'i.contained', x: '1', den: '1' }, contact('', '0', '1')], 100, 'share'],
  adherence: ['w', 100, null], conformance: ['w', 100, null], shrinkage: ['w', 100, null], occupancy: ['w', 1, null], staffing: ['s', 100, null], contact_rate: ['r', 100, null]
};
const W = { adherence: ['ad.in_adherence_min', 'ad.scheduled_min'], conformance: ['ad.logged_in_min', 'ad.scheduled_min'], occupancy: ['ad.occupancy_pct * ad.available_min', 'ad.available_min'] };
const DIM = { channel: 'ch.channel_name', queue: 'qu.queue_name', reason: 're.reason', reason_group: 're.reason_group', persona: 'pe.persona_name', segment: 'cu.segment', age_band: 'cu.age_band', agent_group: 'gc.channel_name', site: 'si.site_name', team: 't.team_name' };
const SPLIT = { complaint_category: 'category', root_cause: 'root_cause', severity: 'severity' };
const JOIN = `LEFT JOIN cc.dim_channel ch ON ch.channel_id = f.channel_id
LEFT JOIN cc.dim_queue qu ON qu.queue_id = f.queue_id
LEFT JOIN cc.dim_contact_reason re ON re.reason_id = f.reason_id
LEFT JOIN cc.customer cu ON cu.customer_id = f.customer_id
LEFT JOIN cc.dim_persona pe ON pe.persona_id = cu.persona_id`;

/* One query. months: list of YYYY-MM. filters: {dim: full name}. by: a dimension, 'month' or null.
   Columns: grp, x, den, n, xx and the value, worked out from totals. */
export function buildSql(metric, months, filters = {}, by = null) {
  if (!F[metric]) throw new Error('no template for ' + metric);
  const [facts, scale] = F[metric], a = months[0], z = months[months.length - 1], month = (k) => `left(${k}::text, 4) || '-' || substr(${k}::text, 5, 2)`;
  const value = scale == null ? 'sum(f.x)' : `sum(f.x)::numeric / nullif(sum(f.den), 0) * ${scale}`, range = (k) => `${k}.date_key BETWEEN ${lo(a)} AND ${hi(z)}`;
  const where = Object.entries(filters).map(([d, v]) => `coalesce(${DIM[d]}, ${q(NI)}) = ${q(v)}`), grp = by === 'month' ? month('f.date_key') : by ? `coalesce(${DIM[by]}, ${q(NI)})` : `'all'`;
  if (facts === 's') return `SELECT ${by === 'month' ? month('f.date_key') : `'all'`} AS grp, sum(f.scheduled_fte - f.required_fte) AS x, sum(f.required_fte) AS den, NULL::bigint AS n, NULL::numeric AS xx,
       sum(f.scheduled_fte - f.required_fte) / nullif(sum(f.required_fte), 0) * 100 AS value
FROM cc.interval_volume f JOIN cc.dim_queue qu USING (queue_id)
WHERE ${range('f')} AND qu.channel_id IN (1, 2)
GROUP BY 1 ORDER BY 1`;
  if (facts === 'w') {
    const day = 'NOT ad.is_pto AND NOT ad.is_absent', s = metric === 'shrinkage', [x, den] = W[metric] || [];
    return `SELECT ${grp.replace(/f\.date_key/g, 'ad.date_key')} AS grp,
       ${s ? 'sum(coalesce(ad.shrinkage_break_min, 0) + coalesce(ad.shrinkage_lunch_min, 0) + coalesce(ad.unplanned_aux_min, 0) + coalesce(ad.shrinkage_absence_min, 0)\n         + coalesce(ad.shrinkage_coaching_min, 0) + coalesce(ad.shrinkage_meeting_min, 0) + coalesce(ad.shrinkage_training_min, 0))' : `sum(${x}) FILTER (WHERE ${day})`} AS x,
       ${s ? 'sum(ad.scheduled_min) FILTER (WHERE NOT ad.is_pto)' : `sum(${den}) FILTER (WHERE ${day})`} AS den,
       count(*) FILTER (WHERE ${day} AND ad.scheduled_min > 0)${s ? ' + count(*) FILTER (WHERE ad.is_absent)' : ''} AS n, NULL::numeric AS xx,
       ${s ? 'sum(coalesce(ad.shrinkage_break_min, 0) + coalesce(ad.shrinkage_lunch_min, 0) + coalesce(ad.unplanned_aux_min, 0) + coalesce(ad.shrinkage_absence_min, 0)\n         + coalesce(ad.shrinkage_coaching_min, 0) + coalesce(ad.shrinkage_meeting_min, 0) + coalesce(ad.shrinkage_training_min, 0))::numeric\n         / nullif(sum(ad.scheduled_min) FILTER (WHERE NOT ad.is_pto), 0)' : `(sum(${x}) FILTER (WHERE ${day}))::numeric / nullif(sum(${den}) FILTER (WHERE ${day}), 0)`} * ${scale} AS value
FROM cc.agent_daily ad
JOIN cc.dim_agent g ON g.agent_id = ad.agent_id
JOIN cc.dim_team t ON t.team_id = g.team_id
JOIN cc.dim_site si ON si.site_id = t.site_id
JOIN cc.dim_channel gc ON gc.channel_id = t.primary_channel_id
WHERE ${range('ad')}${where.map((w) => '\n  AND ' + w).join('')}
GROUP BY 1 ORDER BY 1`;
  }
  if (facts === 'r') return `WITH f AS (   -- contacts of identified customers, and customers on the books at each month's quarter end
  SELECT c.date_key, c.customer_id, 1 AS x, 0 AS den FROM cc.contact c WHERE ${range('c')} AND c.customer_id IS NOT NULL
${months.map((m) => { const e = `${m.slice(0, 5)}${String(Math.ceil(+m.slice(5) / 3) * 3).padStart(2, '0')}`; return `  UNION ALL SELECT ${lo(m)}, customer_id, 0, 1 FROM cc.customer WHERE customer_since <= DATE '${iso(e)}'`; }).join('\n')}
)
SELECT ${grp} AS grp, sum(f.x) AS x, sum(f.den) AS den, sum(f.den) AS n, NULL::numeric AS xx, ${value} AS value
FROM f
JOIN cc.customer cu ON cu.customer_id = f.customer_id
LEFT JOIN cc.dim_persona pe ON pe.persona_id = cu.persona_id${where.length ? '\nWHERE ' + where.join('\n  AND ') : ''}
GROUP BY 1 HAVING sum(f.den) > 0 ORDER BY 1`;
  const extra = SPLIT[by] ? `, ${'SPLIT'} AS part` : '';
  const one = (t) => t.menu
    ? `  SELECT i.date_key, NULL::int AS channel_id, NULL::int AS queue_id, NULL::int AS reason_id, i.customer_id, ${t.x} AS x, ${t.den} AS den, ${t.x} AS xx\n  FROM cc.ivr_session i WHERE ${range('i')}${t.cond ? ' AND ' + t.cond : ''}`
    : `  SELECT ${t.key}.date_key, c.channel_id, c.queue_id, c.reason_id, ${t.cust} AS customer_id, ${t.x} AS x, ${t.den} AS den, ${t.xx || t.x} AS xx${extra.replace('SPLIT', t.key === 'k' ? 'k.' + SPLIT[by] : 'NULL')}\n  FROM ${t.from} WHERE ${range(t.key)}${t.cond ? ' AND ' + t.cond : ''}`;
  const f = `WITH f AS (\n${facts.map(one).join('\n  UNION ALL\n')}\n)`;
  if (SPLIT[by]) return `${f},
g AS (
  SELECT f.* FROM f
  ${JOIN.replace(/\n/g, '\n  ')}${where.length ? '\n  WHERE ' + where.join('\n    AND ') : ''}
)
SELECT part AS grp, sum(x) AS x, (SELECT sum(den) FROM g) AS den, (SELECT sum(den) FROM g) AS n, sum(xx) AS xx,
       sum(x)::numeric / (SELECT nullif(sum(den), 0) FROM g) * ${scale} AS value
FROM g WHERE part IS NOT NULL GROUP BY 1 ORDER BY 2 DESC`;
  return `${f}
SELECT ${grp} AS grp, sum(f.x) AS x, sum(f.den) AS den, sum(f.den) AS n, sum(f.xx) AS xx, ${value} AS value
FROM f
${JOIN}${where.length ? '\nWHERE ' + where.join('\n  AND ') : ''}
GROUP BY 1 HAVING sum(f.den) > 0 ORDER BY 1`;
}

// Survey scores by what happened on the contact
export const outcomeSql = (metric, months) => { const [[t]] = F[metric]; return `SELECT o.outcome, o.happened, sum(${t.x}) AS x, count(*) AS den, count(*) AS n, sum(${t.xx || t.x}) AS xx, sum(${t.x})::numeric / count(*) * ${F[metric][1]} AS value
FROM cc.survey_response v JOIN cc.contact c USING (contact_id)
CROSS JOIN LATERAL (VALUES ('Resolved on first contact', coalesce(c.first_contact_resolved, false)), ('Not transferred', NOT c.transferred), ('Not escalated', NOT c.escalated),
  ('Answered within the service level', c.met_service_level), ('No repeat contact within 7 days', NOT c.repeat_within_7d)) o(outcome, happened)
WHERE v.date_key BETWEEN ${lo(months[0])} AND ${hi(months[months.length - 1])}
GROUP BY 1, 2 ORDER BY 1, 2 DESC`; };

export const personaSql = () => `SELECT persona_name AS name, description, preferred_channel, digital_affinity AS digital_comfort, price_sensitivity, typical_age_band AS typical_ages
FROM cc.dim_persona ORDER BY persona_id`;

// One launch: 7-day weeks from launch day, weeks -8 to 12. Days after October 31, 2026 are left out (November replays October).
const USED = '2026-10-31';
const launchCte = (name) => `l AS (SELECT * FROM cc.product_launch WHERE launch_name = ${q(name)}),
affected AS (SELECT i.reason_id FROM cc.launch_reason_impact i JOIN l USING (launch_id)),   -- reasons the launch was expected to affect
touched AS (   -- reasons affected by this launch or any launch near its window
  SELECT i.reason_id FROM cc.launch_reason_impact i JOIN cc.product_launch o USING (launch_id) CROSS JOIN l
  WHERE o.launch_date BETWEEN l.launch_date - 70 AND l.launch_date + 91
),
days AS (
  SELECT d.date_key, floor((d.full_date - l.launch_date) / 7.0)::int AS week FROM cc.dim_date d CROSS JOIN l
  WHERE d.full_date BETWEEN l.launch_date - 56 AND l.launch_date + 90 AND l.launch_date + floor((d.full_date - l.launch_date) / 7.0)::int * 7 + 6 <= DATE '${USED}'
)`;
const launchPart = `count(*) AS contacts, count(*) FILTER (WHERE c.answered) AS answered, coalesce(sum(c.handle_sec) FILTER (WHERE c.answered), 0) AS handle_sec,
       count(*) FILTER (WHERE c.answered AND c.first_contact_resolved) AS resolved, count(c.customer_id) AS identified,
       count(*) FILTER (WHERE c.customer_id IS NOT NULL AND c.repeat_within_7d) AS repeated, count(v.survey_id) AS surveys, count(*) FILTER (WHERE v.csat >= 4) AS satisfied`;
const launchFrom = `FROM cc.contact c JOIN days USING (date_key) LEFT JOIN cc.survey_response v USING (contact_id)
WHERE (c.reason_id IN (SELECT reason_id FROM affected) OR c.reason_id NOT IN (SELECT reason_id FROM touched))`, side = `CASE WHEN c.reason_id IN (SELECT reason_id FROM affected) THEN 'affected' ELSE 'other' END`;
export const launchInfoSql = (name) => `WITH ${launchCte(name)}
SELECT l.launch_name, l.launch_date::text AS launch_date, l.launch_type, l.expected_contact_impact, l.description, l.launch_id,
       (SELECT json_agg(o.launch_name ORDER BY o.launch_date) FROM cc.product_launch o WHERE o.launch_id <> l.launch_id AND o.launch_date BETWEEN l.launch_date - 70 AND l.launch_date + 91
          AND EXISTS (SELECT 1 FROM cc.launch_reason_impact i WHERE i.launch_id = o.launch_id AND i.reason_id IN (SELECT reason_id FROM affected))) AS overlapping
FROM l`;
export const launchWeekSql = (name) => `WITH ${launchCte(name)}
SELECT days.week, ${side} AS reasons, ${launchPart}
${launchFrom}
GROUP BY 1, 2 ORDER BY 1, 2`;
export const launchRateSql = (name) => `WITH ${launchCte(name)},
x AS (
  SELECT ${side} AS reasons, CASE WHEN days.week >= 0 THEN 'weeks 0-3' ELSE 'baseline' END AS period, ${launchPart}
  ${launchFrom.replace('\n', '\n  ')}
    AND (days.week BETWEEN -8 AND -3 OR days.week BETWEEN 0 AND 3)
  GROUP BY 1, 2
)
SELECT x.*, handle_sec::numeric / nullif(answered, 0) AS aht, resolved::numeric / nullif(answered, 0) * 100 AS fcr, satisfied::numeric / nullif(surveys, 0) * 100 AS csat, repeated::numeric / nullif(identified, 0) * 100 AS repeat
FROM x ORDER BY 1, 2`;

// What the weekly counts say. Written separately from docs/assets/launch.js.
const LR = { aht: ['handle_sec', 'answered', 1], fcr: ['resolved', 'answered', 100], csat: ['satisfied', 'surveys', 100], repeat: ['repeated', 'identified', 100] };
function launchVolume(weeks) {
  const at = (s, w) => { const r = weeks.find((x) => x.reasons === s && x.week === w); return r ? +r.contacts : 0; }, has = [...new Set(weeks.filter((x) => x.reasons === 'affected').map((x) => x.week))].sort((a, b) => a - b), base = has.filter((w) => w >= -8 && w <= -3), mean = (s) => base.reduce((t, w) => t + at(s, w), 0) / base.length;
  const A = mean('affected'), O = mean('other'), expected = (w) => A * (O > 0 ? at('other', w) / O : 1), gap = base.map((w) => at('affected', w) / expected(w) - 1), sd = Math.max(Math.sqrt(gap.reduce((t, x) => t + x * x, 0) / (gap.length - 1)), 1 / Math.sqrt(A));
  const post = has.filter((w) => w >= 0 && w <= 12).map((w) => ({ w, v: at('affected', w), e: expected(w), high: expected(w) * (1 + 3 * sd) })), four = post.filter((p) => p.w <= 3), top = post.reduce((a, b) => (b.v / b.e > a.v / a.e ? b : a)), above = post.filter((p) => p.v > p.high);
  let back = null; if (above.length) for (let i = 0; i + 1 < post.length; i++) if (post[i].w > above[0].w && post[i].v <= post[i].high && post[i + 1].v <= post[i + 1].high) { back = post[i].w; break; }
  const sum = (f) => four.reduce((t, p) => t + f(p), 0); return { extra: sum((p) => p.v - p.e), pct: sum((p) => p.v - p.e) / sum((p) => p.e) * 100, weeks: four.length, peak: (top.v / top.e - 1) * 100, peakWeek: top.w, any: above.length > 0, back, last: post[post.length - 1].w };
}
function launchSpread(weeks, m) { // how far handle time normally moves from week to week in the baseline
  const [x, d] = LR[m], b = weeks.filter((r) => r.reasons === 'affected' && r.week >= -8 && r.week <= -3 && +r[d] > 0), all = b.reduce((t, r) => t + +r[x], 0) / b.reduce((t, r) => t + +r[d], 0); return b.length > 1 ? Math.sqrt(b.reduce((t, r) => t + (+r[x] / +r[d] - all) ** 2, 0) / (b.length - 1)) : 0;
}

// ---------- Checking one request ----------
const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'], toYm = (s) => { const [m, y] = String(s).split(' '); return `${y}-${String(MON.indexOf(m) + 1).padStart(2, '0')}`; };
const YM = /^\d{4}-(0[1-9]|1[0-2])$/;
function span(a, b) { b = b || a; if (!YM.test(a || '') || !YM.test(b) || b < a) throw new Error('the period could not be read'); const out = []; for (let m = a; m <= b && out.length < 60;) { out.push(m); const d = new Date(Date.UTC(+m.slice(0, 4), +m.slice(5), 1)); m = d.toISOString().slice(0, 7); } return out; }
const label = (ms) => (ms.length === 1 ? Site.fmt.month(ms[0]) : `${Site.fmt.month(ms[0])} – ${Site.fmt.month(ms[ms.length - 1])}`);
const norm = (s) => String(s).toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
const TOTAL = { count: 0, rate2: 0.001 };
const near = (a, b, f) => (a == null || b == null ? a == null && b == null : Math.abs(+a - +b) <= (TOTAL[f] ?? 0.005) + 1e-9);
function beyond(kind, a, b) {
  if (!kind) return null; const pa = a.x / a.den, pb = b.x / b.den;
  if (kind === 'share') { const s = Math.sqrt(pa * (1 - pa) / a.den + pb * (1 - pb) / b.den); return s > 0 && Math.abs(pa - pb) >= 3 * s; }
  const v = (t) => { const p = t.x / t.den; return !(t.den > 1) ? 0 : kind === 'count' ? t.x / (t.den * t.den) : Math.max(0, t.xx / t.den - p * p) / t.den; }, s = Math.sqrt(v(a) + v(b)); return s > 0 && Math.abs(pa - pb) >= 3 * s;
}
const NO_N = new Set(['staffing']), PAIRED = new Set(['abandon', 'sl_email']);

/* Returns { verdict, checks: [{what, logged, database, ok}], sql: [{title, sql}] }.
   verdict: match, mismatch, no figure (the page refused the request), not covered, not finished, error */
export function verifyCall(call) {
  const checks = [], sql = [], done = (verdict) => ({ verdict, checks, sql }), add = (what, logged, database, ok) => checks.push({ what, logged: logged ?? null, database: database ?? null, ok: !!ok });
  if (!['get_metric', 'breakdown', 'trend', 'score_by_outcome', 'launch_impact', 'describe_personas'].includes(call.name)) return done(call.name === 'describe_data' ? 'no figure' : 'not covered');
  const r = call.result, i = call.input || {}; if (r == null) return done('not finished'); if (call.error || r.error) return done('no figure'); if (typeof r !== 'object') return done('not covered');
  const same = (what, a, b) => add(what, a, b, a === b), ask = (title, s) => { sql.push({ title, sql: s }); return rows(s); };
  if (call.name === 'describe_personas') try {
    const all = ask('Persona profiles', personaSql()), want = i.persona ? all.filter((x) => norm(x.name) === norm(i.persona)).concat(all.filter((x) => norm(x.name) !== norm(i.persona) && norm(x.name).includes(norm(i.persona)))).slice(0, 1) : all;
    same('personas listed', (r.personas || []).map((x) => x.name).join('; '), want.map((x) => x.name).join('; ')); (r.personas || []).forEach((p, j) => { for (const f of ['description', 'preferred_channel', 'digital_comfort', 'price_sensitivity', 'typical_ages']) same(p.name + ', ' + f.replace('_', ' '), p[f], (want[j] || {})[f]); });
    return done(checks.every((c) => c.ok) ? 'match' : 'mismatch');
  } catch (e) { add('could not be checked', null, String(e.message).slice(0, 300), false); return done('error'); }
  if (call.name === 'launch_impact') try {
    const info = ask('The launch', launchInfoSql(r.launch))[0]; if (!info) { add('launch', r.launch, 'no such launch', false); return done('mismatch'); } add('launch used', r.launch, i.launch, norm(r.launch).includes(norm(i.launch)));
    same('date', r.date, Site.fmt.date(info.launch_date)); same('type', r.type, info.launch_type); same('planned impact', r.planned_impact, info.expected_contact_impact); same('about', r.about, info.description); same('overlapping launches', (r.overlapping_launches || []).join('; '), (info.overlapping || []).join('; '));
    const wk = ask('Week by week', launchWeekSql(info.launch_name)), rt = ask('Weeks 0-3 against the baseline', launchRateSql(info.launch_name)), v = launchVolume(wk), one = (n) => (n > 0 ? '+' : n < 0 ? '−' : '') + Math.abs(n).toFixed(1) + '%', whole = (n) => (n > 0 ? '+' : n < 0 ? '−' : '') + Site.fmt.count(Math.abs(n)), c = r.contacts;
    same('extra contacts', c.extra_first_weeks, whole(v.extra)); same('against expected', c.against_expected, one(v.pct)); same('weeks counted', c.weeks_counted, v.weeks); same('peak', c.peak, `${one(v.peak)} in week ${v.peakWeek}`); same('back to normal', c.back_to_normal, !v.any ? 'never above the normal range' : v.back != null ? `week ${v.back}` : `not for two weeks in a row by week ${v.last}`);
    const row = (s, p) => rt.find((x) => x.reasons === s && x.period === p) || {}, A = row('affected', 'weeks 0-3'), B = row('affected', 'baseline'), P = row('other', 'weeks 0-3'), Q = row('other', 'baseline');
    same('measures given', Object.keys(r.changes).sort().join(', '), Object.keys(LR).filter((m) => A[m] != null && B[m] != null).sort().join(', '));
    for (const [m, s] of Object.entries(r.changes)) {
      const kp = KPI[m], [, d, sc] = LR[m] || []; if (!d) { add(m, s.value, 'no such measure', false); continue; } const a = +A[m], b = +B[m], ch = Site.fmt.change(a, b, kp.format), vr = (p, n) => (n ? (p / sc) * (1 - p / sc) / n : 0);
      const sure = m === 'aht' ? Math.abs(a - b) >= 3 * Math.max(launchSpread(wk, 'aht') / Math.sqrt(v.weeks), 1e-9) : Math.abs(a - b) / sc >= 3 * Math.sqrt(vr(a, +A[d]) + vr(b, +B[d])), other = P[m] == null || Q[m] == null ? null : Site.fmt.change(b + (P[m] - Q[m]), b, kp.format);
      same(m + ', name', s.metric, kp.name); add(m, s.raw, a, near(s.raw, a, kp.format)); same(m + ', as shown', s.value, Site.fmt.value(a, kp.format, true)); add(m + ', baseline', s.raw_baseline, b, near(s.raw_baseline, b, kp.format)); same(m + ', baseline as shown', s.baseline, Site.fmt.value(b, kp.format, true)); same(m + ', change', s.change, ch.flat ? 'no change' : ch.text); same(m + ', too few', s.too_few, +A[d] < kp.minN);
      same(m + ', reading', s.reading, sure ? 'beyond chance' : 'within chance, so it can’t be told apart from no change'); same(m + ', other reasons', s.other_reasons_changed, other == null ? null : other.flat ? 'no change' : other.text);
    }
    return done(checks.every((x) => x.ok) ? 'match' : 'mismatch');
  } catch (e) { add('could not be checked', null, String(e.message).slice(0, 300), false); return done('error'); }
  if (call.name === 'score_by_outcome') try {
    const m = i.metric || 'csat', kp = KPI[m]; if (!['csat', 'nps', 'ces'].includes(m)) return done('not covered'); const ms = span(i.from, i.to), all = ask('Survey scores by what happened', outcomeSql(m, ms)); same('metric', r.metric, kp.name); same('definition', r.source.definition, kp.definition); same('period', r.source.period, label(ms));
    same('outcomes listed', r.rows.map((x) => x.outcome).join('; '), 'Resolved on first contact; Not transferred; Not escalated; Answered within the service level; No repeat contact within 7 days');
    for (const s of r.rows) {
      const pick = (h) => all.find((x) => x.outcome === s.outcome && x.happened === h), yes = pick(true), no = pick(false);
      for (const [w, g, d] of [['when it did', s.when_it_did, yes], ['when it did not', s.when_it_did_not, no]]) { const t = s.outcome + ', ' + w, x = d ? +d.value : null; add(t, g.raw, x, near(g.raw, x, kp.format)); same(t + ', as shown', g.value, x == null ? null : Site.fmt.value(x, kp.format, true)); same(t + ', records', g.n, d ? +d.n : 0); same(t + ', too few', g.too_few, (d ? +d.n : 0) < kp.minN); }
      const n = (d) => ({ x: +d.x, den: +d.den, xx: +d.xx }); same(s.outcome + ', beyond chance', s.beyond_chance, !!(yes && no) && beyond('cx', n(yes), n(no)));
    }
    return done(checks.every((x) => x.ok) ? 'match' : 'mismatch');
  } catch (e) { add('could not be checked', null, String(e.message).slice(0, 300), false); return done('error'); }
  const m = i.metric, k = KPI[m]; if (!F[m] || !k) return done('not covered');
  const [, , kind] = F[m], run = (title, ms, f, by) => { const s = buildSql(m, ms, f, by); sql.push({ title, sql: s }); return rows(s); }, shown = (v) => Site.fmt.value(v, k.format, true);
  try {
    // the names the page settled on, which must fit what the AI asked for
    const filters = {}; for (const t of (r.source && r.source.filters) || []) { const at = t.indexOf(': '), d = t.slice(0, at).replace(' ', '_'); if (!DIM[d]) throw new Error('unknown filter ' + d); filters[d] = t.slice(at + 2); }
    same('metric', r.metric, k.name); same('definition', r.source.definition, k.definition);
    const asked = Object.entries(i.filters || {}).filter(([, v]) => v != null && v !== ''); add('filters used', Object.entries(filters).map((x) => x.join(': ')).join('; ') || 'none', asked.map((x) => x.join(': ')).join('; ') || 'none', asked.length === Object.keys(filters).length && asked.every(([d, v]) => filters[d] && norm(filters[d]).includes(norm(v))));
    const one = !!(filters.channel || filters.queue), figure = (what, s, d, single) => {
      const v = d && d.value != null ? +d.value : null; add(what, s.raw, v, near(s.raw, v, k.format));
      if (s.value !== undefined) add(what + ', as shown', s.value, v == null ? null : shown(v), v != null && s.value === shown(v));
      const n = !d || NO_N.has(m) ? null : +d.n; if (s.n !== undefined) add(what + ', records', s.n, n, s.n === null ? NO_N.has(m) : s.n === n);
      const few = n != null && n < k.minN; if (s.too_few !== undefined) add(what + ', too few', s.too_few, few, s.too_few === few);
      if (s.status !== undefined) add(what + ', against target', s.status, Site.STATUS_WORD[Site.statusOf(k, v)], s.status === Site.STATUS_WORD[Site.statusOf(k, v)]);
      if (s.target !== undefined) same(what + ', target', s.target, few ? 'not applied, too few records' : single && PAIRED.has(m) ? 'set for both channels together, not for one' : k.target == null ? 'this KPI has no target' : k.targetLabel);
      if (s.records !== undefined) add(what + ', records as shown', s.records, n == null ? null : Site.fmt.count(n), n != null && s.records === `${Site.fmt.count(n)} ${s.counted}`);
      return { few, v };
    };
    const change = (what, s, a, b, few) => { // a = later, b = earlier
      const c = Site.fmt.change(a.v, b.v, k.format), real = beyond(a.kind === undefined ? kind : a.kind, a, b), q2 = Site.changeQuality(k, a.v, b.v, c), word = few ? 'too few records to compare' : c.flat ? 'no change' : real === false ? 'within chance, so it can’t be told apart from no change' : real ? { better: 'improved, beyond chance', worse: 'slipped, beyond chance', neutral: 'changed, beyond chance' }[q2] : 'chance not tested for this measure';
      add(what, s.change, c.flat ? 'no change' : c.text, s.change === (c.flat ? 'no change' : c.text)); same(what + ', reading', s.reading, word); same(what + ', beyond chance', s.beyond_chance, real);
    };
    const num = (d) => ({ x: +d.x, den: +d.den, xx: d.xx == null ? null : +d.xx, v: +d.value });

    if (call.name === 'get_metric') {
      const ms = span(i.from, i.to), d = run('This period', ms, filters, null)[0], a = figure('value', r, d, one); add('period', r.source.period, label(ms), r.source.period === label(ms));
      if (i.compare_from) {
        const cs = span(i.compare_from, i.compare_to), e = run('Comparison period', cs, filters, null)[0]; if (!r.comparison) { add('comparison', null, 'expected', false); return done('mismatch'); }
        const b = figure('comparison', r.comparison, e, one); add('comparison period', r.comparison.period, label(cs), r.comparison.period === label(cs)); change('change', r.comparison, num(d), num(e), a.few || b.few);
      }
    } else if (call.name === 'breakdown') {
      const ms = span(i.from, i.to), all = run('By ' + i.by, ms, filters, i.by), split = !!SPLIT[i.by], by = new Map(all.map((x) => [x.grp, x])), single = ['channel', 'queue'].includes(i.by) || one; add('period', r.source.period, label(ms), r.source.period === label(ms));
      add('number of groups', r.groups, all.length, r.groups === all.length);
      const total = all.reduce((s, x) => s + +x.x, 0), counted = m === 'volume' || split;
      for (const s of r.rows) { const d = by.get(s.name); if (!d) { add(s.name, s.value, 'no such group', false); continue; } figure(s.name, s, d, single); if (counted) { add(s.name + ', count', s.count, +d.x, s.count === +d.x); const sh = Site.fmt.value(+d.x / total * 100, 'pct'); add(s.name + ', share', s.share, sh, s.share === sh); } }
      // the right groups are listed, in the right order (ties may be in either order)
      const few = (x) => +x.n < k.minN && !NO_N.has(m), ok = all.filter((x) => !few(x)), dir = i.order === 'lowest' ? 1 : -1, want = ok.sort((x, y) => dir * (x.value - y.value)), n = Math.min(Math.max(1, i.limit || 10), 15), got = r.rows.filter((s) => by.has(s.name) && !few(by.get(s.name))).map((s) => +by.get(s.name).value), expect = want.slice(0, n).map((x) => +x.value);
      add('groups listed, in order', got.length + ' groups', expect.length + ' groups', got.length === expect.length && got.every((v, j) => near(v, expect[j], k.format))); add('rows listed', r.rows.length, Math.min(n, all.length), r.rows.length === Math.min(n, all.length));
      if (r.combined) figure('combined', r.combined, run('All channels together', ms, filters, null)[0], false);
    } else {
      const ms = (r.months || []).map((x) => toYm(x.month)), full = span(ms[0], ms[ms.length - 1]), all = new Map(run('By month', full, filters, 'month').map((x) => [x.grp, x])), total = k.format === 'count'; add('months shown', ms.length, full.length, ms.length === full.length && ms.every((x, j) => x === full[j]) && (!i.from || i.from === ms[0]) && (!i.to || i.to === ms[ms.length - 1]));
      add('period', r.source.period, label(full), r.source.period === label(full)); same('target', r.target, k.target == null ? 'this KPI has no target' : one && PAIRED.has(m) ? 'set for both channels together, not for one' : k.targetLabel); const pts = [];
      for (const s of r.months) { const y = toYm(s.month), d = all.get(y); if (s.raw === undefined) { add(s.month, s.value, d ? +d.value : 'no records', !d); continue; } const g = figure(s.month, { raw: s.raw, value: s.value, ...(s.n !== undefined ? { n: s.n } : {}), ...(s.status !== undefined ? { status: s.status } : {}), too_few: !!s.too_few }, d, one); if (!d) continue; const per = total ? g.v / last(y) : g.v; if (s.raw_per_day !== undefined) add(s.month + ', a day', s.raw_per_day, per, near(s.raw_per_day, per, 'x')); if (!g.few) pts.push({ ...num(d), v: per, whole: g.v, y, kind: total ? null : kind }); }
      if (pts.length > 1) {
        const A = pts[0], Z = pts[pts.length - 1], t = r.first_to_last, word = (p) => (total ? `${shown(p.whole)} (${shown(p.v)} a day)` : shown(p.v)), top = pts.reduce((x, p) => (p.v > x.v ? p : x)), low = pts.reduce((x, p) => (p.v < x.v ? p : x)), say = (p) => `${word(p)} in ${Site.fmt.month(p.y)}`;
        add('first month', `${t.from} ${t.from_value}`, `${Site.fmt.month(A.y)} ${word(A)}`, t.from === Site.fmt.month(A.y) && t.from_value === word(A)); add('last month', `${t.to} ${t.to_value}`, `${Site.fmt.month(Z.y)} ${word(Z)}`, t.to === Site.fmt.month(Z.y) && t.to_value === word(Z));
        change('first to last', t, Z, A, false); add('highest', r.highest, say(top), r.highest === say(top)); add('lowest', r.lowest, say(low), r.lowest === say(low));
        if (r.months_on_target) { const on = pts.filter((p) => Site.statusOf(k, p.whole) === 'good').length; add('months on target', r.months_on_target, `${on} of ${pts.length}`, r.months_on_target === `${on} of ${pts.length}`); }
      }
    }
    return done(checks.every((c) => c.ok) ? 'match' : 'mismatch');
  } catch (e) { add('could not be checked', null, String(e.message).slice(0, 300), false); return done('error'); }
}
