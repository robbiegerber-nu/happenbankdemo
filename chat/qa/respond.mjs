// Posts responses written as comments on the private tickets.
//   node chat/qa/respond.mjs              PREVIEW what would be posted; nothing is sent
//   node chat/qa/respond.mjs --publish    post it (the daily check does this)
// On a private ticket, a comment that starts with one of these is acted on; every other comment stays private:
//   RESPOND no problem: ...               also: problem confirmed, more information, duplicate. Posted publicly; a later one is added as an update
//   CLOSE: ...                            posted publicly, and both tickets are closed
//   CLOSE WITHOUT RESPONSE: ...           for a test or spam: nothing is posted publicly
// Only comments by approved people are used (HAPPEN_QA_RESPONDERS, separated by commas). A response that repeats the reader's own
// words is refused. Each comment is used once: a rocket means done, a confused face means it was refused, with the reason in a reply.
import { spawnSync } from 'node:child_process'; import path from 'node:path'; import { fileURLToPath } from 'node:url';
import { PRIVATE, PUBLIC, gh, json, load, no, privateReady, safe, stop } from './ticket_lib.mjs'; import { psql } from './verify.mjs';
const publish = process.argv.includes('--publish'), WHO = (process.env.HAPPEN_QA_RESPONDERS || 'robbiegerber-nu').toLowerCase().split(',').map((x) => x.trim()), OUTCOME = { 'problem confirmed': 'confirmed', 'no problem': 'no_problem', 'no problem found': 'no_problem', 'more information': 'more_info', duplicate: 'duplicate' };
psql('CREATE TABLE IF NOT EXISTS qa.ticket_command (comment_id bigint PRIMARY KEY, number int NOT NULL, done_at timestamptz NOT NULL DEFAULT now(), result text NOT NULL);');
const ready = privateReady(); if (ready === 'missing' && process.argv.includes('--quiet-if-missing')) process.exit(0); if (ready !== 'private') stop(`STOPPED: GitHub does not say that ${PRIVATE} is private. Nothing was read or sent.`);
const words = (s) => String(s || '').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim().split(' ').filter(Boolean);
// eight words in a row from the reader's comment or question, or all of a shorter comment of at least four words
function repeats(text, ...theirs) { const t = ' ' + words(text).join(' ') + ' '; return theirs.some((x) => { const w = words(x), k = Math.min(8, w.length); if (k < 4) return false; for (let i = 0; i + k <= w.length; i++) if (t.includes(' ' + w.slice(i, i + k).join(' ') + ' ')) return true; return false; }); }
// how many letters differ, so a misspelled word gets a reply instead of being ignored
function off(a, b) { let p = [...Array(b.length + 1).keys()]; for (let i = 1; i <= a.length; i++) { const r = [i]; for (let j = 1; j <= b.length; j++) r[j] = Math.min(p[j] + 1, r[j - 1] + 1, p[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1)); p = r; } return p[b.length]; }
function almost(b) {
  const m = /^([a-z]+)(?:[ \t]+([^:\n]{0,40}?))?[*_]*[ \t]*:/i.exec(b); if (!m) { const n = new RegExp(`^([a-z]+)[ \\t]+(${Object.keys(OUTCOME).join('|')})\\b`, 'i').exec(b); return n && off(n[1].toUpperCase(), 'RESPOND') <= 2 ? `The colon may be missing. Start with "RESPOND ${n[2].toLowerCase()}:".` : null; }
  const w = m[1].toUpperCase(), rest = (m[2] || '').replace(/[*_]/g, '').trim().toLowerCase(); if (off(w, 'RESPOND') <= 2 && w !== 'RESPONDED' && (OUTCOME[rest] || !rest)) return `"${m[1]}" looks like a misspelled RESPOND.`; if (w !== 'CLOSE' && w !== 'CLOSED' && w !== 'CLOSER' && off(w, 'CLOSE') <= 1 && (!rest || rest === 'without response')) return `"${m[1]}" looks like a misspelled CLOSE.`; return null;
}
function parse(body) {
  const b = String(body || '').replace(/\r/g, '').replace(/^[\s*_>#`]+/, ''), m = /^(RESPOND|CLOSE WITHOUT RESPONSE|CLOSE)\b([^:\n]*):[*_]*\s*([\s\S]*)$/i.exec(b); if (!m) return /^RESPOND\b/i.test(b) || /^CLOSE\s*$/i.test(b) || /^CLOSE WITHOUT RESPONSE\b/i.test(b) ? { bad: 'Start with, for example, "RESPOND no problem:" or "CLOSE:", followed by the text.' } : almost(b) ? { bad: almost(b) + ' Nothing was done. Please add a new comment, or leave it as it is if it was meant to stay private.' } : null;
  const kind = m[1].toUpperCase(), what = m[2].replace(/[*_]/g, '').trim().toLowerCase(), text = m[3].trim(); if (kind !== 'RESPOND' && what) return kind === 'CLOSE' ? null : { bad: 'Use "CLOSE WITHOUT RESPONSE:" followed by the reason.' };
  if (kind === 'RESPOND' && !OUTCOME[what]) return { bad: `"${what || '(nothing)'}" is not an outcome. Use: problem confirmed, no problem, more information or duplicate.` };
  if (!text) return { bad: 'There is no text after the colon.' }; if (text.startsWith('--')) return { bad: 'The text cannot start with two dashes.' }; if (text.length > 4000) return { bad: 'Please keep it to 4,000 characters.' };
  return { kind, status: OUTCOME[what], what, text };
}
const ticket = (...a) => { const r = spawnSync(process.execPath, [path.join(path.dirname(fileURLToPath(import.meta.url)), 'ticket.mjs'), ...a], { encoding: 'utf8' }); if (r.status !== 0) throw new Error((r.stderr || 'failed').trim().slice(0, 400)); return r.stdout; };
const api = (args) => gh(['api', ...args], undefined, true), react = (id, c) => api(['-X', 'POST', `repos/${PRIVATE}/issues/comments/${id}/reactions`, '-f', `content=${c}`]);
let did = 0, refused = 0, failed = 0, waiting = 0;
for (const k of json("SELECT number, private_issue FROM qa.chat_ticket WHERE private_issue IS NOT NULL AND status <> 'closed' ORDER BY number")) {
  const raw = api([`repos/${PRIVATE}/issues/${k.private_issue}/comments?per_page=100`]); if (raw === null) { console.log(`${no(k.number)}: the private ticket could not be read.`); failed++; continue; }
  const used = new Set(json(`SELECT comment_id FROM qa.ticket_command WHERE number = ${k.number}`).map((x) => Number(x.comment_id)));
  for (const c of JSON.parse(raw)) {
    const id = Number(c.id); if (!Number.isSafeInteger(id) || used.has(id) || (c.reactions && (c.reactions.rocket || c.reactions.confused))) continue;
    const p = parse(c.body); if (!p) continue; const t = load(`t.number = ${k.number}`)[0]; if (t.status === 'closed') break;
    const why = !WHO.includes(String(c.user && c.user.login).toLowerCase()) ? 'Only approved people can respond from a ticket.' : p.bad ? p.bad : p.kind !== 'CLOSE WITHOUT RESPONSE' && repeats(p.text, t.comment, t.question) ? 'This repeats the reader\'s own words, and they were told those would not be published. Please reword it in a new comment.' : p.kind === 'CLOSE' && !t.issue ? 'The reader was told a response will be posted. Use RESPOND first, or "CLOSE WITHOUT RESPONSE:" for a test or spam.' : p.kind === 'CLOSE WITHOUT RESPONSE' && t.issue ? 'A public response was already posted, so use "CLOSE:".' : null;
    if (!publish) { waiting++; console.log(`${no(k.number)}  ${why ? 'WOULD REFUSE: ' + why : `WOULD ${p.kind}${p.what ? ' (' + p.what + ')' : ''}: ${p.text}`}`); continue; }
    const mark = (result, face) => { psql(`INSERT INTO qa.ticket_command (comment_id, number, result) VALUES (${id}, ${k.number}, '${result}') ON CONFLICT DO NOTHING;`); react(id, face); };
    if (why) { mark('refused', 'confused'); gh(['issue', 'comment', String(k.private_issue), '--repo', PRIVATE, '--body-file', '-'], `Not posted. ${safe(why)}`, true); refused++; console.log(`${no(k.number)}  refused: ${why}`); continue; }
    try {
      if (p.kind === 'RESPOND' && t.issue) { if (gh(['issue', 'comment', String(t.issue), '--repo', PUBLIC, '--body-file', '-'], `**Update (${p.what}):** ${safe(p.text)}`, true) === null) throw new Error('the update could not be posted'); mark('updated', 'rocket'); ticket(String(k.number), '--status', p.status, '--finding', p.text); gh(['issue', 'comment', String(k.private_issue), '--repo', PRIVATE, '--body-file', '-'], `Update posted: https://github.com/${PUBLIC}/issues/${t.issue}`, true); }
      else if (p.kind === 'RESPOND') { ticket(String(k.number), '--status', p.status, '--finding', p.text); ticket(String(k.number), '--issue', '--publish'); mark('responded', 'rocket'); }
      else if (p.kind === 'CLOSE') { ticket(String(k.number), '--close', p.text, '--publish'); mark('closed', 'rocket'); }
      else { ticket(String(k.number), '--close', p.text, '--no-response'); mark('closed', 'rocket'); }
      did++; console.log(`${no(k.number)}  ${p.kind.toLowerCase()}: done`);
    } catch (e) { failed++; console.log(`${no(k.number)}  could not be done, and will be tried again next time: ${e.message}`); break; }
  }
}
console.log(publish ? `${did} done, ${refused} refused, ${failed} failed.` : `${waiting} waiting. PREVIEW ONLY. Nothing was sent.`); process.exit(failed ? 1 : 0);
