/* The question log: one row per question, kept in a private database so answers can be verified.
   - written only when the page says it has shown the notice (notice: 1), so an older open page is never logged
   - no name, internet address, access code or pass; the conversation is kept as a short code that only groups follow-ups
   - rows are deleted after KEEP_LOG_DAYS. The database's own backups last 7 days more, and the notice says 90
   - a failure to log never stops an answer */
import RULES from './rules.json';

let ready = null;
async function db(env) {
  if (!env.LOG) return null;
  ready = ready || env.LOG.prepare(`CREATE TABLE IF NOT EXISTS chat_log (id TEXT PRIMARY KEY, conversation TEXT NOT NULL, asked_at TEXT NOT NULL, updated_at TEXT NOT NULL, status TEXT NOT NULL, question TEXT NOT NULL, answer TEXT,
    label TEXT, unchecked TEXT, calls TEXT NOT NULL DEFAULT '[]', data_through TEXT, exported_at TEXT, page_version TEXT, rules_version TEXT, model TEXT, usd REAL NOT NULL DEFAULT 0, seconds REAL)`).run();
  try { await ready; } catch (e) { ready = null; throw e; }
  return env.LOG;
}
const clean = (s) => (s == null ? null : String(s).replace(/\u0000/g, ''));
const short = (s, re) => (typeof s === 'string' && re.test(s) ? s : null);
// what the page says about itself, kept only if it looks like what it should be
export const about = (a) => (a && a.notice === 1 ? { data_through: short(a.data_through, /^\d{4}-\d\d-\d\d$/), exported_at: short(a.exported_at, /^[\d:T.-]{10,25}$/), page: short(a.page, /^[\w.-]{1,20}$/) } : null);

// what the AI asked for and what came back, for the question that starts at message number `from`
export function callsFrom(messages, from) {
  const calls = [];
  for (const m of messages.slice(from)) for (const b of Array.isArray(m.content) ? m.content : []) {
    if (b.type === 'tool_use') calls.push({ id: b.id, name: b.name, input: b.input, result: null });
    if (b.type === 'tool_result') { const c = calls.find((x) => x.id === b.tool_use_id); if (c) { c.error = !!b.is_error; try { c.result = JSON.parse(b.content); } catch { c.result = b.content; } } }
  }
  return calls.map(({ id, ...c }) => c);
}

/* The label the reader saw. The same check as in docs/chat.html; chat/tests/server.mjs fails if the two differ. */
export const figures = (t) => (t.replace(/[,\u202f]/g, '').match(/\d+(?:\.\d+)?/g) || []).map((x) => String(parseFloat(x)));
export const telling = (text) => [...new Set(figures(text.replace(/\b13 (full )?months\b/g, 'months')))].filter((x) => !(Number.isInteger(+x) && (+x <= 12 || (+x >= 2024 && +x <= 2026))));
export function labelOf(text, messages, from) {
  const seen = [], results = (list) => callsFrom(list, 0).filter((c) => !c.error && c.result && !c.result.error && c.result.source).map((c) => c.result);
  for (const m of messages) if (m.role === 'user') for (const b of m.content) seen.push(b.type === 'text' ? b.text : b.content);
  const have = new Set(figures(seen.join(' '))), nums = telling(text), odd = nums.filter((x) => !have.has(x)), used = results(messages.slice(from)), before = used.length ? [] : results(messages.slice(0, from)).filter((u) => { const h = new Set(figures(JSON.stringify({ ...u, source: 0 }))); return nums.some((x) => h.has(x)); }), src = used.length ? used : before;
  return { label: odd.length ? 'Check the figures' : src.length && src.every((u) => u.profile) ? 'Persona profiles' : used.length ? 'Dashboard figures' : before.length ? 'Dashboard figures from earlier' : 'No figures used', odd };
}

export async function record(env, t, c, status, answer) {
  if (!t) return;
  try {
    const d = await db(env); if (!d) return;
    const now = new Date(), l = status === 'answered' ? labelOf(answer, c.messages, t.from) : { label: status === 'asked' ? null : 'Not answered', odd: [] };
    let calls = JSON.stringify(callsFrom(c.messages, t.from)); if (calls.length > 600000) calls = JSON.stringify(callsFrom(c.messages, t.from).map((x) => ({ ...x, result: 'left out: too long' })));
    await d.prepare(`INSERT INTO chat_log (id, conversation, asked_at, updated_at, status, question, answer, label, unchecked, calls, data_through, exported_at, page_version, rules_version, model, usd, seconds)
      VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17)
      ON CONFLICT (id) DO UPDATE SET updated_at = ?4, status = ?5, answer = ?7, label = ?8, unchecked = ?9, calls = ?10, model = ?15, usd = ?16, seconds = ?17`)
      .bind(t.id, t.group, new Date(t.at).toISOString(), now.toISOString(), status, clean(t.question), clean(answer), l.label, l.odd.join(', ') || null, clean(calls), t.about.data_through, t.about.exported_at, t.about.page, RULES.version, t.model || null, +(t.usd || 0).toFixed(5), status === 'asked' ? null : (now - t.at) / 1000).run();
  } catch (e) { console.error('log error', e && e.name); }
}
export async function tidy(env) {
  const d = await db(env); if (!d) return;
  await d.prepare('DELETE FROM chat_log WHERE asked_at < ?1').bind(new Date(Date.now() - Number(env.KEEP_LOG_DAYS) * 864e5).toISOString()).run();
}
