/* The dashboard chat's server (Cloudflare Worker).
   - checks the access code and gives the browser a pass that lasts 12 hours
   - holds the instructions, tools, model and limits, so it cannot be used as a general AI
   - keeps each conversation for 30 minutes, then deletes it; visitors send only their question and tool results
   - counts questions and spending, and stops at the limits
   - keeps a log of questions, answers and readers' reports for quality checks (log.js), with nothing that identifies a visitor
   Nothing about questions or visitors goes to Cloudflare's own logs. Secrets: ANTHROPIC_API_KEY, ACCESS_CODE, SESSION_SECRET. */
import { DurableObject } from 'cloudflare:workers';
import { askClaude, costOf, textOf, MAX_COST } from './claude.js';
import { about, fileTicket, REASONS, record, tidy } from './log.js';

const J = (data, status = 200, headers = {}) => new Response(JSON.stringify(data), { status, headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', ...headers } });
const no = (code, message, status = 400) => ({ status, body: { error: code, message } });
const enc = new TextEncoder(), hex = (b) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, '0')).join('');
const b64 = (s) => btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, ''), unb64 = (s) => atob(s.replace(/-/g, '+').replace(/_/g, '/'));
const key = (secret) => crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
const mac = async (secret, text) => hex(await crypto.subtle.sign('HMAC', await key(secret), enc.encode(text)));
// compares without giving away how much matched: both sides are the same length after the MAC
const same = (a, b) => { let d = a.length ^ b.length; for (let i = 0; i < Math.min(a.length, b.length); i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i); return d === 0; };
const num = (env, k) => Number(env[k]);
const today = () => new Date().toISOString().slice(0, 10);

async function makePass(env) { const p = b64(JSON.stringify({ s: crypto.randomUUID(), e: Date.now() + num(env, 'PASS_HOURS') * 36e5 })); return `${p}.${await mac(env.SESSION_SECRET, p)}`; }
async function readPass(env, header) {
  const m = /^Bearer ([\w-]+)\.([0-9a-f]{64})$/.exec(header || ''); if (!m || !same(m[2], await mac(env.SESSION_SECRET, m[1]))) return null;
  try { const p = JSON.parse(unb64(m[1])); return p.e > Date.now() ? p : null; } catch { return null; }
}
// a visitor is counted under a code that changes every day; the address itself is never kept
const visitor = async (env, req) => (await mac(env.SESSION_SECRET, `${today()}|${req.headers.get('cf-connecting-ip') || 'local'}`)).slice(0, 24);

export default {
  async fetch(req, env) {
    const origin = req.headers.get('origin') || '', allowed = env.ALLOWED_ORIGINS.split(',').map((x) => x.trim()), ok = allowed.includes(origin);
    const cors = ok ? { 'access-control-allow-origin': origin, 'access-control-allow-headers': 'authorization, content-type', 'access-control-allow-methods': 'POST', 'access-control-max-age': '3600', vary: 'origin' } : { vary: 'origin' };
    if (req.method === 'OPTIONS') return new Response(null, { status: ok ? 204 : 403, headers: cors });
    if (!ok) return J({ error: 'origin', message: 'This chat only works from its own page.' }, 403, cors);
    if (req.method !== 'POST') return J({ error: 'method', message: 'Not found.' }, 404, cors);
    for (const k of ['ACCESS_CODE', 'SESSION_SECRET']) if (!env[k]) return J({ error: 'setup', message: 'The chat is not set up yet.' }, 503, cors);
    let body; try { const t = await req.text(); if (t.length > 60000) throw 0; body = JSON.parse(t); } catch { return J({ error: 'body', message: 'The request could not be read.' }, 400, cors); }
    const path = new URL(req.url).pathname, r = await route(path, body, req, env).catch((e) => { console.error('chat error', e && e.name); return no('server', 'Something went wrong. Please try again.', 500); });
    return J(r.body, r.status, cors);
  },
  // once a day: delete old log entries
  async scheduled(event, env) { await tidy(env).catch((e) => console.error('tidy error', e && e.name)); }
};

async function route(path, body, req, env) {
  const ledger = env.LEDGER.get(env.LEDGER.idFromName('main')), who = await visitor(env, req);
  if (path === '/login') {
    if (!(await ledger.attempt(who, num(env, 'LOGIN_TRIES_PER_HOUR')))) return no('tries', 'Too many tries. Please wait an hour.', 429);
    const code = typeof body.code === 'string' ? body.code.trim().slice(0, 200) : '';
    if (!same(await mac(env.SESSION_SECRET, 'code|' + code), await mac(env.SESSION_SECRET, 'code|' + env.ACCESS_CODE))) return no('code', 'That access code is not right.', 401);
    return { status: 200, body: { pass: await makePass(env), hours: num(env, 'PASS_HOURS') } };
  }
  const pass = await readPass(env, req.headers.get('authorization')); if (!pass) return no('pass', 'Please enter the access code again.', 401);
  if (path === '/ask') {
    const q = typeof body.question === 'string' ? body.question.trim() : ''; if (!q) return no('question', 'Please type a question.');
    if (q.length > num(env, 'QUESTION_CHARS')) return no('long', `Please keep questions to ${env.QUESTION_CHARS} characters.`);
    let id = body.conversation; if (id != null && !/^[0-9a-f-]{36}$/.test(id)) return no('conversation', 'That conversation is not valid.'); const fresh = id == null; if (fresh) id = crypto.randomUUID();
    const convo = env.CONVERSATION.get(env.CONVERSATION.idFromName(id)), can = await convo.canAsk(pass.s, fresh); if (can) return can;
    const full = await ledger.takeQuestion(who, num(env, 'VISITOR_QUESTIONS_PER_DAY'), num(env, 'QUESTIONS_PER_DAY'), num(env, 'MONTHLY_USD')); if (full) return full;
    const r = await convo.ask(pass.s, q, about(body.about), id); if (r.status === 200) r.body.conversation = id; return r;
  }
  if (path === '/tools') {
    if (!/^[0-9a-f-]{36}$/.test(body.conversation || '')) return no('conversation', 'That conversation is not valid.');
    const r = await env.CONVERSATION.get(env.CONVERSATION.idFromName(body.conversation)).tools(pass.s, body.results); if (r.status === 200) r.body.conversation = body.conversation; return r;
  }
  // a report about a logged answer: the ticket key was given with that answer, so nobody can report one they never saw
  if (path === '/report') {
    const m = /^([0-9a-f-]{36})\.([0-9a-f]{64})$/.exec(body.ticket || ''); if (!m || !same(m[2], await mac(env.SESSION_SECRET, 'report|' + m[1]))) return no('ticket', 'That answer could not be found.');
    if (!REASONS.includes(body.reason)) return no('reason', 'Please choose a reason.'); const comment = typeof body.comment === 'string' ? body.comment.trim() : ''; if (comment.length > num(env, 'COMMENT_CHARS')) return no('long', `Please keep comments to ${env.COMMENT_CHARS} characters.`);
    if (!(await ledger.takeReport(who, num(env, 'VISITOR_REPORTS_PER_DAY'), num(env, 'REPORTS_PER_DAY')))) return no('reports', 'The limit for reports today has been reached. Please try again tomorrow.', 429);
    let t; try { t = await fileTicket(env, m[1], body.reason, comment, body.notice); } catch (e) { console.error('ticket error', e && e.name); return no('save', 'Your report could not be saved. Please try again.', 500); }
    return t ? { status: 200, body: t } : no('gone', 'That answer is no longer kept, so it cannot be reported.', 410);
  }
  return no('path', 'Not found.', 404);
}

/* One conversation. Append-only, because the model's reasoning is tied to the messages before it. */
export class Conversation extends DurableObject {
  async load() { return (await this.ctx.storage.get('c')) || null; }
  async save(c) { await this.ctx.storage.put('c', c); await this.ctx.storage.setAlarm(Date.now() + num(this.env, 'KEEP_MINUTES') * 6e4); }
  async alarm() { await this.ctx.storage.deleteAll(); }
  async canAsk(owner, fresh) {
    const c = await this.load(); if (fresh) return null;
    if (!c || c.owner !== owner) return no('gone', 'That conversation has ended. Please start a new one.', 410);
    if (c.busy > Date.now()) return no('busy', 'The last question is still being answered.', 409);
    if (c.asked >= num(this.env, 'QUESTIONS_PER_CONVERSATION')) return no('full', 'This conversation is full. Please start a new one.', 409);
    if (c.pending) { // the browser never sent the tool results: close them, so the history stays valid
      c.messages.push({ role: 'user', content: c.pending.map((id) => ({ type: 'tool_result', tool_use_id: id, is_error: true, content: 'The page was closed before this finished.' })) }); c.pending = null; await this.save(c);
    }
    return null;
  }
  async ask(owner, q, seen, id) {
    const c = (await this.load()) || { owner, messages: [], asked: 0, rounds: 0, pending: null, busy: 0 }, last = c.messages[c.messages.length - 1];
    c.rounds = 0; c.asked++;
    const block = { type: 'text', text: q }, undo = JSON.stringify(c.messages);
    if (last && last.role === 'user') c.messages = [...c.messages.slice(0, -1), { role: 'user', content: [...last.content, block] }]; else c.messages.push({ role: 'user', content: [block] });
    c.trace = seen ? { id: crypto.randomUUID(), group: id.slice(0, 8), at: Date.now(), question: q, about: seen, from: c.messages.length - 1, usd: 0 } : null; if (c.trace) c.trace.key = await mac(this.env.SESSION_SECRET, 'report|' + c.trace.id); await record(this.env, c.trace, c, 'asked', null);
    return this.turn(c, undo);
  }
  async tools(owner, results) {
    const c = await this.load(); if (!c || c.owner !== owner) return no('gone', 'That conversation has ended. Please start a new one.', 410);
    if (c.busy > Date.now()) return no('busy', 'Still working on it.', 409);
    if (!c.pending) return no('pending', 'Nothing was waiting for a result.', 409);
    if (!Array.isArray(results) || results.length !== c.pending.length || !c.pending.every((id) => results.filter((r) => r && r.id === id && typeof r.content === 'string' && r.content.length <= 14000).length === 1)) return no('results', 'The results do not match what was asked for.');
    const undo = JSON.stringify(c.messages), was = c.pending;
    c.messages.push({ role: 'user', content: was.map((id) => { const r = results.find((x) => x.id === id); return { type: 'tool_result', tool_use_id: id, content: r.content, ...(r.error ? { is_error: true } : {}) }; }) }); c.pending = null; c.rounds++;
    const out = await this.turn(c, undo); if (out.status !== 200) { const now = await this.load(); if (now) { now.pending = was; await this.save(now); } } return out;
  }
  async turn(c, undo) {
    // the reference lets a reader point to this answer; it is only given when the question was logged
    const tag = c.trace && this.env.LOG ? { ref: c.trace.id.slice(0, 8), ticket: `${c.trace.id}.${c.trace.key}` } : {}, failed = (r) => { Object.assign(r.body, tag); return r; };
    const answered = (text) => ({ status: 200, body: { type: 'answer', text, left: num(this.env, 'QUESTIONS_PER_CONVERSATION') - c.asked, ...tag } });
    const env = this.env, ledger = env.LEDGER.get(env.LEDGER.idFromName('main')), reserved = await ledger.reserve(MAX_COST, num(env, 'MONTHLY_USD')); if (!reserved) { await record(env, c.trace, c, 'limit', null); c.messages = JSON.parse(undo); await this.save(c); return failed(no('spend', 'The chat has reached its limit for this month.', 429)); }
    c.busy = Date.now() + 9e4; await this.save(c); let msg, cost = MAX_COST;
    try { msg = await askClaude(env, c.messages, c.rounds < num(env, 'TOOL_ROUNDS')); cost = costOf(msg); if (env.ALLOWED_ORIGINS.startsWith('http://localhost')) console.error('usage', JSON.stringify({ stop: msg.stop_reason, model: msg.model, in: msg.usage.input_tokens, out: msg.usage.output_tokens, cw: msg.usage.cache_creation_input_tokens, cr: msg.usage.cache_read_input_tokens, usd: +cost.toFixed(4) })); }
    catch (e) { console.error('claude error', e && e.name, e && e.status); if (e && e.status >= 400 && e.status !== 408) cost = 0; if (c.trace) c.trace.usd += cost; await record(env, c.trace, c, 'ai_error', null); c.messages = JSON.parse(undo); c.busy = 0; await this.save(c); await ledger.settle(MAX_COST, cost); return failed(no(e && e.status === 429 ? 'ai_busy' : 'ai', 'The AI could not answer just now. Please try again.', 502)); }
    await ledger.settle(MAX_COST, cost); if (c.trace) { c.trace.usd += cost; c.trace.model = msg.model; }
    const calls = msg.content.filter((b) => b.type === 'tool_use');
    c.busy = 0;
    if (msg.stop_reason === 'refusal' || msg.stop_reason === 'max_tokens') { const no = msg.stop_reason === 'refusal', text = no ? "I can't help with that one. I can answer questions about the contact center data on these dashboards." : 'That answer got too long. Please ask something narrower.'; await record(env, c.trace, c, no ? 'declined' : 'too_long', text); c.messages = JSON.parse(undo); await this.save(c); return answered(text); }
    c.messages.push({ role: 'assistant', content: msg.content });
    if (calls.length) { c.pending = calls.map((b) => b.id); await this.save(c); await record(env, c.trace, c, 'asked', null); return { status: 200, body: { type: 'tools', calls: calls.map((b) => ({ id: b.id, name: b.name, input: b.input })) } }; }
    const text = textOf(msg); await this.save(c); await record(env, c.trace, c, 'answered', text); return answered(text);
  }
}

/* Counts only: login tries and questions per day, and dollars per month. */
export class Ledger extends DurableObject {
  async day() { const d = (await this.ctx.storage.get('day')) || {}; return d.on === today() ? d : { on: today(), all: 0, who: {}, tries: {} }; }
  async month() { const m = (await this.ctx.storage.get('month')) || {}, on = today().slice(0, 7); return m.on === on ? m : { on, spent: 0, held: {} }; }
  heldNow(m) { for (const k in m.held) if (m.held[k].until < Date.now()) { m.spent += m.held[k].usd; delete m.held[k]; } return Object.values(m.held).reduce((s, h) => s + h.usd, 0); }
  async attempt(who, max) { const d = await this.day(), hour = new Date().getUTCHours(), t = d.tries[who] && d.tries[who].h === hour ? d.tries[who] : { h: hour, n: 0 }; t.n++; d.tries[who] = t; await this.ctx.storage.put('day', d); return t.n <= max; }
  async takeReport(who, perVisitor, perDay) { const d = await this.day(); d.rep = d.rep || { all: 0, who: {} }; if (d.rep.all >= perDay || (d.rep.who[who] || 0) >= perVisitor) return false; d.rep.all++; d.rep.who[who] = (d.rep.who[who] || 0) + 1; await this.ctx.storage.put('day', d); return true; }
  async takeQuestion(who, perVisitor, perDay, usd) {
    const d = await this.day(), m = await this.month(); if (m.spent + this.heldNow(m) >= usd) return no('spend', 'The chat has reached its limit for this month.', 429);
    if (d.all >= perDay) return no('day', 'The chat has reached its limit for today. Please try again tomorrow.', 429);
    if ((d.who[who] || 0) >= perVisitor) return no('visitor', 'You have reached the number of questions for today.', 429);
    d.all++; d.who[who] = (d.who[who] || 0) + 1; await this.ctx.storage.put('day', d); return null;
  }
  async reserve(usd, cap) { const m = await this.month(); if (m.spent + this.heldNow(m) + usd > cap) return false; m.held[crypto.randomUUID()] = { usd, until: Date.now() + 12e4 }; await this.ctx.storage.put('month', m); return true; }
  async settle(held, actual) { const m = await this.month(), k = Object.keys(m.held).find((x) => m.held[x].usd === held); if (k) delete m.held[k]; m.spent += actual; await this.ctx.storage.put('month', m); }
}
