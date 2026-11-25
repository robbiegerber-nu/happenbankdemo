// Reviews readers' reports. Run sync_log.mjs and verify_log.mjs first.
//   node chat/qa/ticket.mjs                                         open tickets
//   node chat/qa/ticket.mjs 1                                       one ticket: question, answer, comment, check
//   node chat/qa/ticket.mjs 1 --status confirmed --finding "..."    record your decision (kept in Postgres only)
//   node chat/qa/ticket.mjs 1 --issue                               PREVIEW the public response; nothing is sent
//   node chat/qa/ticket.mjs 1 --issue --publish                     post it, with your own GitHub sign-in
// Add --hide-question to leave the question out, or --show-question to publish one that was held for looking personal.
// Readers are told that a response will be posted, so every ticket gets one. To close one without it (a test, spam), add --no-response.
//   node chat/qa/ticket.mjs 1 --close "..."                         PREVIEW closing the public response with a comment; add --publish to do it
// statuses: new, confirmed, no_problem, more_info, duplicate, closed
// The public response holds the question only if the reader was told it would (notice 2). It never holds the answer or the comment. The full ticket is in the private repository
// (private_tickets.mjs); posting or closing the public response is noted there.
import { PRIVATE, PUBLIC, REASON, STATUS, gh, json, lit, load, no, privateReady, publicIssue, questionChoice, safe, sqlFile, stop } from './ticket_lib.mjs'; import { psql } from './verify.mjs';
const args = process.argv.slice(2), opt = (n) => { const i = args.indexOf(n); if (i < 0) return null; const v = args[i + 1]; if (v === undefined || v.startsWith('--')) stop(`${n} needs a value.`); return v; }, n = args[0] && !args[0].startsWith('--') ? args[0].replace(/^QA-0*/i, '') : null, privateUrl = (x) => `https://github.com/${PRIVATE}/issues/${x}`;
if (!n) {
  const t = json("SELECT v.number, (v.created_at AT TIME ZONE 'America/Chicago')::date AS on, v.due, v.response_owed, v.due < (now() AT TIME ZONE 'America/Chicago')::date AS late, v.reason, v.status, v.issue, v.reference, v.question, v.verdict, v.comment, k.private_issue FROM qa.v_chat_ticket v JOIN qa.chat_ticket k USING (number) WHERE v.status <> 'closed' ORDER BY v.number");
  for (const x of t) console.log(`${no(x.number)}  ${x.on}  ${x.status.padEnd(10)}  ${REASON[x.reason] || x.reason}${x.issue ? `  (public #${x.issue})` : ''}  ${x.response_owed ? (x.late ? `RESPONSE OVERDUE, was due ${x.due}` : `respond by ${x.due}`) : 'response posted'}\n         ${x.reference}  ${x.verdict}  ${String(x.question).replace(/\s+/g, ' ').slice(0, 100)}${x.comment ? '\n         comment: ' + x.comment.replace(/\s+/g, ' ').slice(0, 160) : ''}${x.private_issue ? '\n         full ticket: ' + privateUrl(x.private_issue) : ''}`);
  console.log(`${t.length} open tickets.`); process.exit(0);
}
if (!/^\d{1,9}$/.test(n)) stop('Give a ticket number, for example 1 or QA-0001.');
const get = () => { const t = load(`t.number = ${n}`)[0]; if (t) t.private_issue = json(`SELECT private_issue FROM qa.chat_ticket WHERE number = ${n}`)[0].private_issue; return t; }; let t = get(); if (!t) stop(`There is no ticket ${no(n)}. Run sync_log.mjs first.`);
const status = opt('--status'), finding = opt('--finding'), close = opt('--close'), publish = args.includes('--publish');
if (status !== null && !STATUS[status]) stop('Statuses: ' + Object.keys(STATUS).join(', '));
if (status !== null || finding !== null) { psql(`UPDATE qa.chat_ticket SET ${[status !== null ? `status = '${status}'` : null, finding !== null ? `finding = ${lit(finding)}` : null, 'reviewed_at = now()'].filter(Boolean).join(', ')} WHERE number = ${n};`); t = get(); console.log(`${no(n)} saved: ${t.status}${t.finding ? ' - ' + t.finding : ''}`); }
for (const [flag, v] of [['--hide-question', false], ['--show-question', true]]) if (args.includes(flag)) { if (v && !(t.notice >= 2)) stop('This reader was told their question would stay private, so it cannot be shown.'); if (t.issue) stop('The response is already posted. Edit the public issue on GitHub.'); psql(`UPDATE qa.chat_ticket SET show_question = ${v} WHERE number = ${n};`); t = get(); }
// keeps the private ticket in step; a problem there never undoes what was done
function note(text, shut) { if (!t.private_issue || privateReady() !== 'private') return; const a = ['--repo', PRIVATE], i = String(t.private_issue), ok = gh(['issue', 'comment', i, ...a, '--body-file', '-'], safe(text), true) !== null && (!shut || gh(['issue', 'close', i, ...a], undefined, true) !== null); console.log(ok ? `Noted on the private ticket${shut ? ', which is closed' : ''}.` : 'The private ticket could not be updated; please do it on GitHub.'); }

if (args.includes('--issue')) {
  if (publish && !t.finding) stop('Record a finding first: it is the response the reader is waiting for.'); if (publish && questionChoice(t).hold) stop(`${questionChoice(t).why}. Add --hide-question, or --show-question if it is fine to publish.`); if (publish && t.status === 'new') stop('Set a status first: it is the outcome shown to the reader.'); if (t.issue) stop(`${no(n)} already has a public response, #${t.issue}.`); const x = publicIssue(t); console.log(`TITLE  ${x.title}\n\n${x.body}\n`);
  if (!publish) console.log('PREVIEW ONLY. Nothing was sent. Add --publish to post this public response.');
  else { gh(['label', 'create', 'chat-report', '--repo', PUBLIC, '--color', '1D76DB', '--description', 'Reported from Ask the data', '--force']); const url = gh(['issue', 'create', '--repo', PUBLIC, '--title', x.title, '--label', 'chat-report', '--body-file', '-'], x.body), num = (/\/issues\/(\d+)$/.exec(url) || [])[1]; if (!num) stop('The issue may have been created, but its number could not be read: ' + url); psql(`UPDATE qa.chat_ticket SET issue = ${num} WHERE number = ${n};`); console.log('Posted ' + url); note(`Public response posted: ${url}`, false); }
} else if (close !== null) {
  if (!t.issue && !args.includes('--no-response')) stop(`${no(n)} has no public response, and the reader was told one will be posted. Post it with --issue, or add --no-response to close it anyway.`);
  if (!t.issue) { psql(`UPDATE qa.chat_ticket SET status = 'closed', finding = coalesce(finding, ${lit(close)}), reviewed_at = now() WHERE number = ${n};`); console.log(`${no(n)} closed. It has no public response, so nothing public changed.`); note(`Closed without a public response: ${close}`, true); }
  else if (!publish) console.log(`Would comment on public issue #${t.issue} and close it:\n\n${safe(close)}\n\nPREVIEW ONLY. Nothing was sent. Add --publish to do it.`);
  else { gh(['issue', 'comment', String(t.issue), '--repo', PUBLIC, '--body-file', '-'], safe(close)); gh(['issue', 'close', String(t.issue), '--repo', PUBLIC]); psql(`UPDATE qa.chat_ticket SET status = 'closed', reviewed_at = now() WHERE number = ${n};`); console.log(`Public issue #${t.issue} closed.`); note(`Closed: ${close}`, true); }
} else if (status === null && finding === null) {
  console.log(`${no(n)}  ${t.status}  ${REASON[t.reason] || t.reason}  reported ${t.reported}\nRespond:  ${t.response_owed ? `by ${t.due} (5 business days)` : t.issue ? 'posted' : 'closed without a response'}\nComment:  ${t.comment || '(none)'}\n\nQuestion: ${t.question}\nPublished: ${questionChoice(t).why}\nAnswer:   ${t.answer || '(none)'}\nLabel:    ${t.label}\nCheck:    ${t.verdict}${t.differences ? '\n' + t.differences : ''}\nFinding:  ${t.finding || '(none yet)'}${t.issue ? `\nPublic:   https://github.com/${PUBLIC}/issues/${t.issue}` : ''}${t.private_issue ? `\nFull:     ${privateUrl(t.private_issue)}` : ''}\nSQL:      ${sqlFile(t.reference)}`);
}
