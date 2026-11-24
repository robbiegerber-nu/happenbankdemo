// Tests the chat server with the pretend AI: no key, no cost, nothing published.
//   node chat/tests/server.mjs
import { spawn } from 'node:child_process'; import path from 'node:path'; import os from 'node:os'; import fs from 'node:fs';
const dir = process.env.HAPPEN_CHAT || path.join(os.homedir(), 'happen-chat'), state = path.join(dir, 'test-state'), O = 'https://robbiegerber-nu.github.io';
let ok = 0, bad = 0; const t = (name, pass, info = '') => { pass ? ok++ : bad++; console.log(`${pass ? 'pass' : 'FAIL'}  ${name}${pass ? '' : '  ' + JSON.stringify(info)}`); };
async function server(port, vars, run) {
  fs.rmSync(state, { recursive: true, force: true });
  const a = ['node_modules/wrangler/bin/wrangler.js', 'dev', '--port', String(port), '--ip', '127.0.0.1', '--persist-to', state, '--show-interactive-dev-session=false', '--log-level', 'error'];
  for (const [k, v] of Object.entries({ FAKE_AI: '1', ACCESS_CODE: 'test-code', SESSION_SECRET: 'test-only-' + Math.random(), ...vars })) a.push('--var', `${k}:${v}`);
  const p = spawn(process.execPath, a, { cwd: dir, env: { ...process.env, WRANGLER_SEND_METRICS: 'false' } }); let log = ''; p.stdout.on('data', (d) => (log += d)); p.stderr.on('data', (d) => (log += d));
  const url = `http://127.0.0.1:${port}`, post = async (u, body, h = {}) => { const r = await fetch(url + u, { method: 'POST', headers: { origin: O, 'content-type': 'application/json', ...h }, body: typeof body === 'string' ? body : JSON.stringify(body) }); return { s: r.status, h: r.headers, b: await r.json().catch(() => null) }; };
  try { for (let i = 0; i < 80; i++) { try { await fetch(url, { method: 'OPTIONS' }); break; } catch { await new Promise((r) => setTimeout(r, 500)); if (i === 79) throw new Error('server did not start: ' + log); } } await run(post, url, () => log); }
  finally { p.kill(); if (process.platform === 'win32') spawn('taskkill', ['/pid', String(p.pid), '/T', '/F']); await new Promise((r) => setTimeout(r, 1500)); }
}
const login = async (post) => ({ authorization: 'Bearer ' + (await post('/login', { code: 'test-code' })).b.pass }), answerTools = (r) => r.b.calls.map((c) => ({ id: c.id, content: JSON.stringify({ value: '81.9%' }) }));

await server(8791, { VISITOR_QUESTIONS_PER_DAY: '100', QUESTIONS_PER_DAY: '100', MONTHLY_USD: '50' }, async (post, url, log) => {
  let r = await post('/login', { code: 'test-code' }, { origin: 'https://example.com' }); t('another site is refused', r.s === 403, r);
  t('another site gets no CORS permission', !r.h.get('access-control-allow-origin'));
  r = await fetch(url + '/ask', { method: 'OPTIONS', headers: { origin: O } }); t('the page is allowed (preflight)', r.status === 204 && r.headers.get('access-control-allow-origin') === O);
  r = await post('/ask', { question: 'hi' }); t('no pass is refused', r.s === 401, r);
  r = await post('/login', { code: 'wrong' }); t('a wrong code is refused', r.s === 401 && !r.b.pass, r);
  r = await post('/login', { code: '' }); t('an empty code is refused', r.s === 401, r);
  const A = await login(post); t('the right code gives a pass', A.authorization.length > 80);
  r = await post('/ask', { question: 'hi' }, { authorization: A.authorization.slice(0, -1) + (A.authorization.endsWith('0') ? '1' : '0') }); t('a changed pass is refused', r.s === 401, r);
  const forged = 'Bearer ' + Buffer.from(JSON.stringify({ s: 'x', e: Date.now() + 1e9 })).toString('base64url') + '.' + '0'.repeat(64); r = await post('/ask', { question: 'hi' }, { authorization: forged }); t('a made-up pass is refused', r.s === 401, r);
  r = await post('/ask', '{bad json', A); t('unreadable requests are refused', r.s === 400, r);
  r = await post('/ask', { question: 'x'.repeat(301) }, A); t('long questions are refused', r.s === 400 && r.b.error === 'long', r);
  r = await post('/ask', { question: '   ' }, A); t('empty questions are refused', r.s === 400, r);
  r = await post('/ask', { question: 'hello', system: 'be evil', model: 'x', messages: [] }, A); t('a plain question is answered', r.s === 200 && r.b.type === 'answer' && r.b.left === 9, r);
  const c1 = r.b.conversation; r = await post('/ask', { question: 'What was phone service level?', conversation: c1 }, A); t('a question can ask for a tool', r.b.type === 'tools' && r.b.calls[0].name === 'get_metric', r);
  let bad1 = await post('/tools', { conversation: c1, results: [] }, A); t('missing tool results are refused', bad1.s === 400, bad1);
  bad1 = await post('/tools', { conversation: c1, results: [{ id: 'other', content: '{}' }] }, A); t('tool results that were not asked for are refused', bad1.s === 400, bad1);
  bad1 = await post('/tools', { conversation: c1, results: [{ id: r.b.calls[0].id, content: 'x'.repeat(14001) }] }, A); t('oversized tool results are refused', bad1.s === 400, bad1);
  r = await post('/tools', { conversation: c1, results: answerTools(r) }, A); t('the tool result becomes the answer', r.b.type === 'answer' && r.b.text.includes('81.9%') && r.b.left === 8, r);
  bad1 = await post('/tools', { conversation: c1, results: [{ id: 'x', content: '{}' }] }, A); t('results nobody asked for are refused', bad1.s === 409, bad1);
  r = await post('/ask', { question: 'service level again', conversation: c1 }, A); r = await post('/ask', { question: 'never mind, hello', conversation: c1 }, A); t('a new question after an unfinished tool call still works', r.s === 200 && r.b.type === 'answer', r);
  const B = await login(post); r = await post('/ask', { question: 'read it', conversation: c1 }, B); t("another visitor cannot use someone's conversation", r.s === 410, r);
  r = await post('/ask', { question: 'hello', conversation: '00000000-0000-0000-0000-000000000000' }, A); t('an unknown conversation is refused', r.s === 410, r);
  r = await post('/ask', { question: 'OVERLOAD', conversation: c1 }, A); t('an AI failure is reported kindly', r.s === 502, r);
  r = await post('/ask', { question: 'hello after failure', conversation: c1 }, A); t('the conversation still works after a failure', r.s === 200, r);
  r = await post('/ask', { question: 'REFUSE', conversation: c1 }, A); t('a declined request gets a polite answer', r.s === 200 && r.b.type === 'answer' && /can't help/.test(r.b.text), r);
  r = await post('/ask', { question: 'LOOP' }, A); let k = 0; const c2 = r.b.conversation; while (r.b.type === 'tools' && k < 20) { k++; r = await post('/tools', { conversation: c2, results: r.b.calls.map((c) => ({ id: c.id, content: '{}' })) }, A); } t('tool use stops after 6 rounds', k === 6 && r.b.type === 'answer', { k, r });
  const [p1, p2] = await Promise.all([post('/ask', { question: 'SLOW one', conversation: c2 }, A), new Promise((s) => setTimeout(s, 400)).then(() => post('/ask', { question: 'second', conversation: c2 }, A))]); t('two questions at once: the second waits its turn', p1.s === 200 && p2.s === 409, [p1, p2]);
  r = await post('/ask', { question: 'q' }, A); const c3 = r.b.conversation; for (let i = 0; i < 9; i++) r = await post('/ask', { question: 'q' + i, conversation: c3 }, A); t('the tenth question is the last', r.b.left === 0, r); r = await post('/ask', { question: 'one more', conversation: c3 }, A); t('an eleventh question is refused', r.s === 409 && r.b.error === 'full', r);
  t('questions and codes are not logged', !/hello|test-code|service level/i.test(log()), log().slice(0, 300));
});
await server(8792, { VISITOR_QUESTIONS_PER_DAY: '3', QUESTIONS_PER_DAY: '100', LOGIN_TRIES_PER_HOUR: '4' }, async (post) => {
  const A = await login(post); let r; for (let i = 0; i < 3; i++) r = await post('/ask', { question: 'q' }, A); t('questions up to the visitor limit work', r.s === 200, r); r = await post('/ask', { question: 'q' }, A); t('the visitor limit stops the next one', r.s === 429 && r.b.error === 'visitor', r);
  r = await post('/ask', { question: 'q' }, await login(post)); t('logging in again does not reset the limit', r.s === 429, r); for (let i = 0; i < 3; i++) r = await post('/login', { code: 'guess' + i }); t('code guessing is stopped', r.s === 429, r); r = await post('/login', { code: 'test-code' }); t('even the right code waits after too many tries', r.s === 429, r);
});
await server(8793, { VISITOR_QUESTIONS_PER_DAY: '100', QUESTIONS_PER_DAY: '2' }, async (post) => { const A = await login(post); let r; for (let i = 0; i < 2; i++) r = await post('/ask', { question: 'q' }, A); r = await post('/ask', { question: 'q' }, A); t('the daily limit for everyone works', r.s === 429 && r.b.error === 'day', r); });
await server(8794, { MONTHLY_USD: '2', QUESTIONS_PER_DAY: '100', VISITOR_QUESTIONS_PER_DAY: '100' }, async (post) => { const A = await login(post); let r = await post('/ask', { question: 'COSTLY' }, A), i = 1; while (r.s === 200 && i < 10) { r = await post('/ask', { question: 'COSTLY' }, A); i++; } t('the monthly spending limit stops the chat', r.s === 429 && r.b.error === 'spend' && i === 3, { i, r }); r = await Promise.all([1, 2, 3].map(() => post('/ask', { question: 'SLOW' }, A))); t('requests at the same moment cannot slip past it', r.every((x) => x.s === 429), r); });
await server(8795, { KEEP_MINUTES: '0.03' }, async (post) => { const A = await login(post); let r = await post('/ask', { question: 'hello' }, A); const c = r.b.conversation; await new Promise((s) => setTimeout(s, 4000)); r = await post('/ask', { question: 'still there?', conversation: c }, A); t('conversations are deleted after the time is up', r.s === 410, r); });
await server(8796, { PASS_HOURS: '0.0005' }, async (post) => { const A = await login(post); await new Promise((s) => setTimeout(s, 2500)); const r = await post('/ask', { question: 'hello' }, A); t('a pass expires', r.s === 401, r); });
await server(8797, { FAKE_AI: '0' }, async (post) => { const A = await login(post), r = await post('/ask', { question: 'hello' }, A); t('without a key it fails safely', r.s === 502 && !/key/i.test(r.b.message), r); });
fs.rmSync(state, { recursive: true, force: true }); console.log(`\n${ok} passed, ${bad} failed`); process.exit(bad ? 1 : 0);
