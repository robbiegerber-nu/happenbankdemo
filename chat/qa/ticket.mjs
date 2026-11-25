// Reviews readers' reports. Run sync_log.mjs and verify_log.mjs first.
//   node chat/qa/ticket.mjs                                         open tickets
//   node chat/qa/ticket.mjs 1                                       one ticket: question, answer, comment, check
//   node chat/qa/ticket.mjs 1 --status confirmed --finding "..."    record your decision (kept in Postgres only)
//   node chat/qa/ticket.mjs 1 --issue                               PREVIEW the public GitHub issue; nothing is sent
//   node chat/qa/ticket.mjs 1 --issue --publish                     create it, with your own GitHub sign-in
// Readers are told that a response will be posted, so every ticket gets an issue. To close one without it (a test, spam), add --no-response.
//   node chat/qa/ticket.mjs 1 --close "..."                         PREVIEW closing the issue with a comment; add --publish to do it
// statuses: new, confirmed, no_problem, more_info, duplicate, closed
// The public issue never holds the question, the answer or the reader's comment. It has the ticket number, the reason, the KPI,
// months and filters (only names found in the database), the result of the check, and your finding.
import { spawnSync } from 'node:child_process'; import path from 'node:path'; import os from 'node:os'; import { Site, psql, KPI } from './verify.mjs';
const REPO = 'robbiegerber-nu/happenbankdemo', STATUS = ['new', 'confirmed', 'no_problem', 'more_info', 'duplicate', 'closed'], REASON = { wrong: 'The answer looks wrong', no_answer: 'It could not answer the question', more_info: 'More information wanted', other: 'Something else' };
const args = process.argv.slice(2), stop = (m) => { console.error(m); process.exit(1); }, opt = (n) => { const i = args.indexOf(n); if (i < 0) return null; const v = args[i + 1]; if (v === undefined || v.startsWith('--')) stop(`${n} needs a value.`); return v; }, n = args[0] && !args[0].startsWith('--') ? args[0].replace(/^QA-0*/i, '') : null;
const lit = (s) => `convert_from(decode('${Buffer.from(String(s)).toString('base64')}', 'base64'), 'UTF8')`, no = (x) => 'QA-' + String(x).padStart(4, '0'), json = (q) => JSON.parse(psql(`SELECT coalesce(json_agg(x), '[]') FROM (${q}) x;`));
if (!n) {
  const t = json("SELECT number, created_at::date AS on, due, response_owed, due < (now() AT TIME ZONE 'America/Chicago')::date AS late, reason, status, issue, reference, question, verdict, comment FROM qa.v_chat_ticket WHERE status <> 'closed' ORDER BY number");
  for (const x of t) console.log(`${no(x.number)}  ${x.on}  ${x.status.padEnd(10)}  ${REASON[x.reason] || x.reason}${x.issue ? `  (issue #${x.issue})` : ''}  ${x.response_owed ? (x.late ? `RESPONSE OVERDUE, was due ${x.due}` : `respond by ${x.due}`) : 'response posted'}\n         ${x.reference}  ${x.verdict}  ${String(x.question).replace(/\s+/g, ' ').slice(0, 100)}${x.comment ? '\n         comment: ' + x.comment.replace(/\s+/g, ' ').slice(0, 160) : ''}`);
  console.log(`${t.length} open tickets.`); process.exit(0);
}
if (!/^\d{1,9}$/.test(n)) stop('Give a ticket number, for example 1 or QA-0001.');
const load = () => json(`SELECT t.*, l.calls FROM qa.v_chat_ticket t JOIN qa.chat_log l ON l.id = t.log_id WHERE t.number = ${n}`)[0]; let t = load(); if (!t) stop(`There is no ticket ${no(n)}. Run sync_log.mjs first.`);
const status = opt('--status'), finding = opt('--finding'), close = opt('--close'), publish = args.includes('--publish');
if (status !== null && !STATUS.includes(status)) stop('Statuses: ' + STATUS.join(', '));
if (status !== null || finding !== null) { psql(`UPDATE qa.chat_ticket SET ${[status !== null ? `status = '${status}'` : null, finding !== null ? `finding = ${lit(finding)}` : null, 'reviewed_at = now()'].filter(Boolean).join(', ')} WHERE number = ${n};`); t = load(); console.log(`${no(n)} saved: ${t.status}${t.finding ? ' - ' + t.finding : ''}`); }

// ---------- What may be made public ----------
const names = new Set(psql("SELECT channel_name FROM cc.dim_channel UNION SELECT queue_name FROM cc.dim_queue UNION SELECT reason FROM cc.dim_contact_reason UNION SELECT reason_group FROM cc.dim_contact_reason UNION SELECT persona_name FROM cc.dim_persona UNION SELECT DISTINCT segment FROM cc.customer UNION SELECT DISTINCT age_band FROM cc.customer UNION SELECT site_name FROM cc.dim_site UNION SELECT team_name FROM cc.dim_team UNION SELECT launch_name FROM cc.product_launch", true).split(/\r?\n/)), YM = /^20\d\d-(0[1-9]|1[0-2])$/;
const DIMS = ['channel', 'queue', 'reason group', 'reason', 'persona', 'segment', 'age band', 'agent group', 'site', 'team', 'complaint category', 'root cause', 'severity'], KIND = { get_metric: 'a single figure', breakdown: 'a breakdown', trend: 'a trend', score_by_outcome: 'scores by outcome', launch_impact: 'a product launch', describe_personas: 'persona profiles', describe_data: 'what the data covers' };
function request(c, j) {
  const i = c.input || {}, r = c.result || {}, src = r.source || {}, k = KPI[i.metric], by = String(i.by || '').replace('_', ' '), f = (Array.isArray(src.filters) ? src.filters : []).map(String).filter((x) => { const at = x.indexOf(': '); return DIMS.includes(x.slice(0, at)) && names.has(x.slice(at + 2)); }), v = (t.checks || []).find((x) => x.request === j + 1);
  return [KIND[c.name] ? KIND[c.name][0].toUpperCase() + KIND[c.name].slice(1) : 'A request', k ? k.name : names.has(r.launch) ? r.launch : null, YM.test(i.from || '') ? Site.fmt.month(i.from) + (YM.test(i.to || '') && i.to !== i.from ? ` to ${Site.fmt.month(i.to)}` : '') : null, YM.test(i.compare_from || '') ? `compared with ${Site.fmt.month(i.compare_from)}` : null, DIMS.includes(by) ? `by ${by}` : null, ...f].filter(Boolean).join(' · ') + `: **${v ? v.verdict : 'not checked'}**${v && v.agreed + v.differed ? ` (${v.agreed} of ${v.agreed + v.differed} comparisons agree)` : ''}`;
}
// a mention in an issue would notify a stranger
const safe = (s) => String(s).replace(/@(?=\w)/g, '@​');
const issue = () => ({ title: `${no(n)}: ${REASON[t.reason] || 'Report'} (Ask the data)`, body: safe([`A reader reported an answer from [Ask the data](https://robbiegerber-nu.github.io/happenbankdemo/chat.html).`, '', '| | |', '|---|---|', `| **Ticket** | ${no(n)} |`, `| **Reason** | ${REASON[t.reason] || 'Report'} |`, `| **Reported** | ${Site.fmt.date(String(t.created_at).slice(0, 10))} |`, `| **Status** | ${t.status.replace('_', ' ')} |`, '', '**What the chat looked up, checked against the database**', '', ...((t.calls || []).length ? t.calls.map((c, j) => '- ' + request(c, j)) : ['- Nothing was looked up.']), '', '**Finding**', '', t.finding || 'Under review.', '', '*The question, the answer and any comment are not published. All data is simulated. How answers are checked: [AI chat](https://github.com/robbiegerber-nu/happenbankdemo/wiki/3c-AI-Chat#checking-logged-answers).*'].join('\n')) });
const gh = (a, input) => { const r = spawnSync('gh', a, { input, encoding: 'utf8', shell: false }); if (r.status !== 0) stop('GitHub: ' + (r.stderr || r.error)); return r.stdout.trim(); };
if (args.includes('--issue')) {
  if (publish && !t.finding) stop('Record a finding first: it is the response the reader is waiting for.'); if (t.issue) stop(`${no(n)} already has issue #${t.issue}.`); const x = issue(); console.log(`TITLE  ${x.title}\n\n${x.body}\n`);
  if (!publish) console.log('PREVIEW ONLY. Nothing was sent. Add --publish to create this public issue.');
  else { gh(['label', 'create', 'chat-report', '--repo', REPO, '--color', '1D76DB', '--description', 'Reported from Ask the data', '--force']); const url = gh(['issue', 'create', '--repo', REPO, '--title', x.title, '--label', 'chat-report', '--body-file', '-'], x.body), num = (/\/issues\/(\d+)$/.exec(url) || [])[1]; if (!num) stop('The issue may have been created, but its number could not be read: ' + url); psql(`UPDATE qa.chat_ticket SET issue = ${num} WHERE number = ${n};`); console.log('Created ' + url); }
} else if (close !== null) {
  if (!t.issue && !args.includes('--no-response')) stop(`${no(n)} has no issue, and the reader was told a response will be posted. Create it with --issue, or add --no-response to close it anyway.`);
  if (!t.issue) { psql(`UPDATE qa.chat_ticket SET status = 'closed', finding = coalesce(finding, ${lit(close)}), reviewed_at = now() WHERE number = ${n};`); console.log(`${no(n)} closed. It has no GitHub issue, so nothing public changed.`); }
  else if (!publish) console.log(`Would comment on issue #${t.issue} and close it:\n\n${safe(close)}\n\nPREVIEW ONLY. Nothing was sent. Add --publish to do it.`);
  else { gh(['issue', 'comment', String(t.issue), '--repo', REPO, '--body-file', '-'], safe(close)); gh(['issue', 'close', String(t.issue), '--repo', REPO]); psql(`UPDATE qa.chat_ticket SET status = 'closed', reviewed_at = now() WHERE number = ${n};`); console.log(`Issue #${t.issue} closed.`); }
} else if (status === null && finding === null) {
  console.log(`${no(n)}  ${t.status}  ${REASON[t.reason] || t.reason}  reported ${t.created_at}\nRespond:  ${t.response_owed ? `by ${t.due} (5 business days)` : t.issue ? 'posted' : 'closed without a response'}\nComment:  ${t.comment || '(none)'}\n\nQuestion: ${t.question}\nAnswer:   ${t.answer || '(none)'}\nLabel:    ${t.label}\nCheck:    ${t.verdict}${t.differences ? '\n' + t.differences : ''}\nFinding:  ${t.finding || '(none yet)'}${t.issue ? `\nIssue:    https://github.com/${REPO}/issues/${t.issue}` : ''}\nSQL:      ${path.join(process.env.HAPPEN_CHAT || path.join(os.homedir(), 'happen-chat'), 'qa-sql', t.reference + '.txt')}`);
}
