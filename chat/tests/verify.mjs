// Tests the verifier (chat/qa/verify.mjs): right results must match, and wrong ones must be caught.
//   node chat/tests/verify.mjs          (about 5 minutes; reads the database and the dashboards' files, no AI)
// The results come from the real page code (docs/assets), run here against the files in docs/data.
import fs from 'node:fs'; import path from 'node:path'; import vm from 'node:vm'; import { fileURLToPath } from 'node:url';
import { verifyCall, buildSql, psql } from '../qa/verify.mjs';
const docs = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..', 'docs');
const box = vm.createContext({ console, URLSearchParams, Response, Blob, DecompressionStream, TextDecoder, Uint8Array, document: { documentElement: {}, addEventListener() {} }, localStorage: { getItem: () => null }, matchMedia: () => ({ matches: false, addEventListener() {} }), location: { hostname: 'x', href: 'http://x/' }, fetch: async (u) => { const p = path.join(docs, String(u).split('?')[0]), ok = fs.existsSync(p); return { ok, status: ok ? 200 : 404, arrayBuffer: async () => { const b = fs.readFileSync(p); return b.buffer.slice(b.byteOffset, b.byteOffset + b.length); } }; } }); box.window = box;
for (const f of ['site', 'cx', 'drivers', 'workforce', 'selfservice', 'launch', 'chat-tools']) vm.runInContext(fs.readFileSync(path.join(docs, 'assets', f + '.js'), 'utf8'), box);
const ask = async (name, input) => ({ name, input, result: JSON.parse(JSON.stringify(await box.ChatTools.run(name, input))) });
let ok = 0, bad = 0, refused = 0, checks = 0; const t = (n, p, info) => { p ? ok++ : bad++; if (!p) console.log('FAIL  ' + n + '  ' + JSON.stringify(info).slice(0, 700)); };

const ALL = { drivers: ['sl_phone', 'sl_chat', 'sl_email', 'sl_callback', 'asa_phone', 'abandon', 'volume', 'aht_phone', 'digital_share'], cx: ['csat', 'nps', 'ces', 'fcr', 'repeat', 'complaints', 'response'], workforce: ['adherence', 'occupancy', 'conformance', 'shrinkage'], scorecard: ['staffing'], menu: ['ivr_containment', 'no_agent'], customers: ['contact_rate'] };
const DIMS = { drivers: ['channel', 'queue', 'reason_group', 'reason', 'persona', 'segment', 'age_band'], cx: ['channel', 'queue', 'reason_group', 'reason', 'persona', 'segment'], workforce: ['agent_group', 'site', 'team'], scorecard: [], menu: ['persona'], customers: ['persona', 'segment', 'age_band'] };
const FILTER = { channel: 'Phone', queue: 'Fraud & Disputes', reason_group: 'Card', reason: 'Card Activation', persona: 'Credit Builder', segment: 'Mass Affluent', age_band: '25-34', agent_group: 'Chat', site: 'Lakeside', team: 'Atlas' };
const calls = [];
for (const [e, ms] of Object.entries(ALL)) for (const m of ms) {
  const M = e === 'customers' ? '2026-08' : '2026-10', C = e === 'customers' ? '2026-02' : '2025-10';
  calls.push(['get_metric', { metric: m, from: M }], ['get_metric', { metric: m, from: M, compare_from: C }]); if (e !== 'scorecard') calls.push(['get_metric', { metric: m, from: '2026-05', to: '2026-09', compare_from: '2026-01', compare_to: '2026-02' }]);
  if (e !== 'scorecard') calls.push(['trend', { metric: m }]); else calls.push(['trend', { metric: m, from: '2026-01', to: '2026-10' }]); if (DIMS[e][0]) calls.push(['trend', { metric: m, from: '2026-04', to: '2026-09', filters: { [DIMS[e].at(-1)]: FILTER[DIMS[e].at(-1)] } }]);
  for (const d of DIMS[e]) { calls.push(['breakdown', { metric: m, by: d, from: M }], ['get_metric', { metric: m, from: M, compare_from: C, filters: { [d]: FILTER[d] } }], ['breakdown', { metric: m, by: d, from: M, order: 'lowest', limit: 3, filters: { [DIMS[e].find((x) => x !== d) || d]: FILTER[DIMS[e].find((x) => x !== d) || d] } }]); }
}
for (const by of ['complaint_category', 'root_cause', 'severity']) calls.push(['breakdown', { metric: 'complaints', by, from: '2026-10' }], ['breakdown', { metric: 'complaints', by, from: '2026-07', to: '2026-09', limit: 2, filters: { persona: 'Credit Builder' } }], ['breakdown', { metric: 'complaints', by, from: '2026-10', filters: { channel: 'Chat' } }]);
for (const c of Object.values(JSON.parse(fs.readFileSync(path.join(docs, '..', 'chat', 'tests', 'tool_calls.json'), 'utf8')))) if (Array.isArray(c) && ['get_metric', 'breakdown', 'trend'].includes(c[0])) calls.push([c[0], c[1]]);
const launches = psql('SELECT launch_name FROM cc.product_launch ORDER BY 1').split(/\r?\n/); for (const l of launches) calls.push(['launch_impact', { launch: l }]); calls.push(['launch_impact', { launch: 'mobile app' }], ['launch_impact', { launch: 'nothing like this' }]);
for (const metric of ['csat', 'nps', 'ces']) calls.push(['score_by_outcome', { metric, from: '2026-10' }], ['score_by_outcome', { metric, from: '2025-01', to: '2025-12' }]); calls.push(['score_by_outcome', { from: '2024-02' }]);
calls.push(['describe_personas', {}], ['describe_personas', { persona: 'Credit Builder' }], ['describe_personas', { persona: 'retiree trad' }], ['describe_personas', { persona: 'retiree' }]);

const right = [];
for (const [n, i] of calls) {
  const c = await ask(n, i), v = verifyCall(c); checks += v.checks.length;
  if (c.result.error) { refused++; t(`${n} ${JSON.stringify(i)} refused`, v.verdict === 'no figure', v); continue; }
  t(`${n} ${JSON.stringify(i)}`, v.verdict === 'match', { v: v.verdict, bad: v.checks.filter((x) => !x.ok).slice(0, 4) }); if (v.verdict === 'match') right.push(c);
}
for (const n of ['get_metric', 'breakdown', 'trend', 'launch_impact', 'score_by_outcome', 'describe_personas']) console.log(`  ${n}: ${right.filter((c) => c.name === n).length}`);
console.log(`right results: ${right.length} matched, ${refused} refused by the page, ${checks} single checks`);

// ---------- Wrong results: every number and every reading, one at a time ----------
const bump = (v) => (typeof v === 'number' ? (Number.isInteger(v) ? v + 1 : v + 0.02) : typeof v === 'boolean' ? !v : /\d/.test(v) ? v.replace(/\d(?=\D*$)/, (d) => (+d + 1) % 10) : v + ' x');
const SAID = new Set(['raw', 'value', 'n', 'too_few', 'status', 'change', 'reading', 'count', 'share', 'groups', 'highest', 'lowest', 'months_on_target', 'raw_per_day', 'from_value', 'to_value', 'name', 'month', 'period', 'target', 'records', 'beyond_chance', 'metric', 'definition', 'launch', 'date', 'type', 'planned_impact', 'about', 'extra_first_weeks', 'against_expected', 'weeks_counted', 'peak', 'back_to_normal', 'baseline', 'raw_baseline', 'other_reasons_changed', 'outcome', 'description', 'preferred_channel', 'digital_comfort', 'price_sensitivity', 'typical_ages']);
// what the AI reads but is only another form of a checked value, or is fixed text
const spots = (o, at = []) => Object.entries(o).flatMap(([k, v]) => (v && typeof v === 'object' ? spots(v, [...at, k]) : SAID.has(k) && v != null && !(k === 'definition' && o.kpi === 'Persona profiles') && !(k === 'definition' && /^Expected volume/.test(v)) && !(k === 'period' && /^(Definitions|8 weeks)/.test(v)) ? [[...at, k]] : []));
let wrong = 0, missed = [];
for (const [j, c] of right.entries()) { const s = spots(c.result); for (const p of j % 4 ? [s[(j * 7) % s.length]] : s) {
  const b = JSON.parse(JSON.stringify(c)); let o = b.result; for (const k of p.slice(0, -1)) o = o[k]; o[p.at(-1)] = bump(o[p.at(-1)]); wrong++; if (!['mismatch', 'error'].includes(verifyCall(b).verdict)) missed.push([c.name, c.input, p.join('.')]);
} }
t(`every one of ${wrong} changed results is caught`, !missed.length, { missed: missed.length, first: missed.slice(0, 6) });
// wrong in other ways: a row left out, rows swapped, the filter or the month ignored
{ const b = right.find((c) => c.name === 'breakdown' && c.result.rows.length > 3 && !c.result.rows.some((x) => x.too_few)); const cut = JSON.parse(JSON.stringify(b)); cut.result.rows.splice(1, 1); t('a missing row is caught', verifyCall(cut).verdict === 'mismatch', cut); const swap = JSON.parse(JSON.stringify(b)); [swap.result.rows[0], swap.result.rows[2]] = [swap.result.rows[2], swap.result.rows[0]]; t('swapped rows are caught', verifyCall(swap).verdict === 'mismatch', swap.result.rows); }
{ const f = await ask('get_metric', { metric: 'csat', from: '2026-10' }); f.input.filters = { persona: 'Credit Builder' }; t('an ignored filter is caught', verifyCall(f).verdict === 'mismatch', f); const m = await ask('get_metric', { metric: 'csat', from: '2026-10' }); m.input.from = '2026-09'; t('the wrong month is caught', verifyCall(m).verdict === 'mismatch', m); const k = await ask('get_metric', { metric: 'nps', from: '2026-10' }); k.input.metric = 'csat'; t('the wrong KPI is caught', verifyCall(k).verdict === 'mismatch', k); }
// not figures, and text that tries to be SQL
t('something new is reported as not covered', verifyCall({ name: 'new_tool', input: {}, result: {} }).verdict === 'not covered'); t('the description of the data is not a figure', verifyCall({ name: 'describe_data', input: {}, result: {} }).verdict === 'no figure');
{ const a = right.find((c) => c.name === 'launch_impact' && c.result.overlapping_launches.length), b = JSON.parse(JSON.stringify(a)); b.result.overlapping_launches.pop(); t('a missing overlapping launch is caught', verifyCall(b).verdict === 'mismatch'); const d = JSON.parse(JSON.stringify(a)); delete d.result.changes.csat; t('a missing launch measure is caught', verifyCall(d).verdict === 'mismatch'); const g = JSON.parse(JSON.stringify(a)); delete g.result.changes.sl; t('a missing launch service level is caught', verifyCall(g).verdict === 'mismatch'); delete g.result.service_level_is; t('an answer from before service level was added still matches', verifyCall(g).verdict === 'match'); const e = JSON.parse(JSON.stringify(a)); e.input.launch = launches.find((x) => x !== a.result.launch); t('the wrong launch is caught', verifyCall(e).verdict === 'mismatch');
  const p = JSON.parse(JSON.stringify(right.find((c) => c.name === 'describe_personas' && c.result.personas.length === 8))); p.result.personas.pop(); t('a missing persona is caught', verifyCall(p).verdict === 'mismatch'); const o = JSON.parse(JSON.stringify(right.find((c) => c.name === 'score_by_outcome'))); o.result.rows.pop(); t('a missing outcome is caught', verifyCall(o).verdict === 'mismatch'); } t('an unfinished request is reported', verifyCall({ name: 'get_metric', input: { metric: 'csat', from: '2026-10' }, result: null }).verdict === 'not finished');
{ const x = await ask('get_metric', { metric: 'csat', from: '2026-10', filters: { persona: 'Credit Builder' } }); x.result.source.filters = ["persona: '; DROP TABLE cc.dim_persona; --"]; x.input.filters.persona = "'; DROP TABLE cc.dim_persona; --"; t('a filter written as SQL is only text', verifyCall(x).verdict !== 'match' && psql('SELECT count(*) FROM cc.dim_persona') === '8'); const y = await ask('get_metric', { metric: 'csat', from: '2026-10' }); y.input.from = "2026-10' OR 1=1"; t('a month written as SQL is refused', verifyCall(y).verdict === 'error'); }
{ let w = false; try { psql('CREATE TABLE public.x_verify (a int);', true); w = true; } catch { /* as it should be */ } t('checking queries cannot change data', !w); }
t('no template reads the dash tables', Object.values(ALL).flat().every((m) => !/\bdash\./.test(buildSql(m, ['2026-08']))));
console.log(`changed results: ${wrong}, missed ${missed.length}`); console.log(`\n${ok} passed, ${bad} failed`); process.exit(bad ? 1 : 0);
