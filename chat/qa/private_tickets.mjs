// Puts the full ticket (comment, question, answer, check, SQL) in the PRIVATE repository, for whoever handles it.
//   node chat/qa/private_tickets.mjs                 PREVIEW new tickets; nothing is sent
//   node chat/qa/private_tickets.mjs --show 1        PREVIEW one ticket
//   node chat/qa/private_tickets.mjs --publish       create new tickets, and delete those past 90 days
//   node chat/qa/private_tickets.mjs --refresh 1     write one ticket's text again, for example after a new check (ticks in its to-do list are lost)
//   node chat/qa/private_tickets.mjs --publish --quiet-if-missing   the same, but do nothing if the repository doesn't exist (daily check)
// Answers not checked yet are checked first, so a ticket never goes out without its result.
// Every run asks GitHub whether the repository is private, and sends nothing if it isn't.
import { spawnSync } from 'node:child_process'; import path from 'node:path'; import { fileURLToPath } from 'node:url';
import { PRIVATE, gh, json, load, no, privateIssue, privateReady, stop } from './ticket_lib.mjs'; import { psql } from './verify.mjs';
const args = process.argv.slice(2), publish = args.includes('--publish'), show = args.includes('--show') ? args[args.indexOf('--show') + 1] : null, LABEL = 'chat-ticket', today = new Date().toLocaleDateString('en-CA', { timeZone: 'America/Chicago' });
const check = () => { const r = spawnSync(process.execPath, [path.join(path.dirname(fileURLToPath(import.meta.url)), 'verify_log.mjs')], { encoding: 'utf8' }); if (r.status !== 0) stop('The answers could not be checked, so nothing was sent. Run verify_log.mjs to see why.\n' + (r.stderr || '').slice(0, 300)); };
const refresh = args.includes('--refresh') ? args[args.indexOf('--refresh') + 1] : null; if (refresh !== null && !/^\d{1,9}$/.test(refresh || '')) stop('Give a ticket number.');
if (publish || refresh !== null) check();
if (refresh !== null) { const t = load(`t.number = ${refresh}`)[0], num = t && json(`SELECT private_issue FROM qa.chat_ticket WHERE number = ${refresh}`)[0].private_issue; if (!num) stop('That ticket is not in the private repository.'); if (privateReady() !== 'private') stop(`STOPPED: GitHub does not say that ${PRIVATE} is private. Nothing was sent.`); gh(['issue', 'edit', String(num), '--repo', PRIVATE, '--body-file', '-'], privateIssue(t).body); console.log(`${no(t.number)} refreshed: https://github.com/${PRIVATE}/issues/${num}`); process.exit(0); }
if (show !== null) { if (!/^\d{1,9}$/.test(show || '')) stop('Give a ticket number.'); const t = load(`t.number = ${show}`)[0]; if (!t) stop('There is no such ticket.'); const x = privateIssue(t); console.log(`TITLE  ${x.title}\n\n${x.body}\n\nPREVIEW ONLY. Nothing was sent.`); process.exit(0); }
const todo = load("t.status <> 'closed' AND NOT EXISTS (SELECT 1 FROM qa.chat_ticket k WHERE k.number = t.number AND k.private_issue IS NOT NULL)");
if (!publish) { for (const t of todo) { const x = privateIssue(t); console.log(`Would create in ${PRIVATE}:  ${x.title}  (${x.body.length} characters)`); } console.log(`${todo.length} to create. PREVIEW ONLY. Nothing was sent.`); process.exit(0); }
const ready = privateReady(); if (ready === 'missing' && args.includes('--quiet-if-missing')) { console.log('The private repository does not exist yet, so no tickets were sent.'); process.exit(0); } if (ready !== 'private') stop(ready === 'missing' ? `${PRIVATE} does not exist, or this GitHub sign-in cannot see it.` : `STOPPED: GitHub does not say that ${PRIVATE} is private. Nothing was sent.`);
gh(['label', 'create', LABEL, '--repo', PRIVATE, '--color', 'B60205', '--description', 'A reader report from Ask the data', '--force']);
const list = () => JSON.parse(gh(['issue', 'list', '--repo', PRIVATE, '--state', 'all', '--label', LABEL, '--limit', '1000', '--json', 'number,title,body']));
let made = 0, gone = 0; const there = list();
for (const t of todo) {
  const x = privateIssue(t), old = there.find((i) => i.title.startsWith(no(t.number) + ':')); let num = old && old.number;   // created before, but not recorded here (for example after the database was rebuilt)
  if (!num) { const url = gh(['issue', 'create', '--repo', PRIVATE, '--title', x.title, '--label', LABEL, '--body-file', '-'], x.body); num = (/\/issues\/(\d+)$/.exec(url) || [])[1]; if (!num) stop('A ticket may have been created, but its number could not be read: ' + url); made++; console.log(`${no(t.number)}  ${url}`); }
  psql(`UPDATE qa.chat_ticket SET private_issue = ${Number(num)} WHERE number = ${t.number};`);
}
// the notice says reports are kept for up to 90 days. Only tickets this script made, with a passed date in their own hidden mark
for (const i of there) { const m = /<!-- chat-ticket delete-after:(\d{4}-\d\d-\d\d) -->\s*$/.exec(i.body || ''); if (m && /^QA-\d{4,}: /.test(i.title) && m[1] < today) { gh(['issue', 'delete', String(i.number), '--repo', PRIVATE, '--yes']); gone++; } }
console.log(`${made} private tickets created, ${gone} older than 90 days deleted.`);
