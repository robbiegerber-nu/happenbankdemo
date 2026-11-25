// Checks logged chat answers against the source tables. Run sync_log.mjs first.
//   node chat/qa/verify_log.mjs                 questions not checked yet
//   node chat/qa/verify_log.mjs --all           every question again
//   node chat/qa/verify_log.mjs --only 4b4fa516 one question, by its reference
// Results go to qa.chat_check (see qa.v_chat_verdict and qa.v_chat_check). The SQL for each question is also written to a
// text file to paste into pgAdmin, outside the project folder because it holds people's questions.
import fs from 'node:fs'; import path from 'node:path'; import os from 'node:os'; import { fileURLToPath } from 'node:url';
import { verifyCall, psql } from './verify.mjs';
const here = path.dirname(fileURLToPath(import.meta.url)), args = process.argv.slice(2), only = args.includes('--only') ? String(args[args.indexOf('--only') + 1] || '') : null;
if (only !== null && !/^[0-9a-f]{8}$/.test(only)) { console.error('Give the 8-character reference, for example --only 4b4fa516.'); process.exit(1); }
const out = path.join(process.env.HAPPEN_CHAT || path.join(os.homedir(), 'happen-chat'), 'qa-sql'); fs.mkdirSync(out, { recursive: true });
psql(fs.readFileSync(path.join(here, 'schema.sql'), 'utf8'));
const rows = JSON.parse(psql(`SELECT coalesce(json_agg(json_build_object('id', l.id, 'question', l.question, 'answer', l.answer, 'label', l.label, 'through', l.data_through, 'calls', l.calls) ORDER BY l.asked_at), '[]') FROM qa.chat_log l
  WHERE ${only ? `l.id::text LIKE '${only}%'` : args.includes('--all') ? 'true' : "NOT EXISTS (SELECT 1 FROM qa.chat_check k WHERE k.log_id = l.id AND k.checked_at > l.updated_at)"};`));
const through = psql('SELECT max(d.full_date) FROM cc.contact c JOIN cc.dim_date d USING (date_key)', true), line = (s) => String(s ?? '').replace(/[\s\p{Cc}]+/gu, ' '), b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64');
const tally = {};
for (const r of rows) {
  const ref = r.id.slice(0, 8), res = r.calls.map(verifyCall); if (!res.length) res.push({ verdict: 'no figure', checks: [], sql: [] });
  const text = [`-- Question ${ref}: ${line(r.question)}`, `-- The chat answered: ${line(r.answer)}`, `-- Data through ${r.through || 'not known'} when asked, ${through} now. Each query only reads data; copy one at a time into pgAdmin 4.`];
  res.forEach((v, j) => {
    const c = r.calls[j]; tally[v.verdict] = (tally[v.verdict] || 0) + 1;
    text.push('', '-- ' + '='.repeat(96), `-- Request ${j + 1}: ${c ? line(c.name + ' ' + JSON.stringify(c.input)) : 'none'}`, `-- Result of the check: ${v.verdict.toUpperCase()}${v.checks.length ? ` (${v.checks.filter((x) => x.ok).length} of ${v.checks.length} comparisons agree)` : ''}`);
    for (const x of v.checks.filter((x) => !x.ok)) text.push(`--   DIFFERS  ${line(x.what)}: chat ${line(x.logged)}, database ${line(x.database)}`);
    for (const x of v.checks.filter((x) => x.ok).slice(0, 12)) text.push(`--   agrees   ${line(x.what)}: ${line(x.logged)}`);
    for (const s of v.sql) text.push('', `-- ${s.title}`, s.sql + ';');
    psql(`INSERT INTO qa.chat_check (log_id, request, verdict, agreed, differed, details, sql, data_through)
      SELECT '${r.id}', ${j + 1}, '${v.verdict}', ${v.checks.filter((x) => x.ok).length}, ${v.checks.filter((x) => !x.ok).length}, convert_from(decode('${b64(v.checks)}', 'base64'), 'UTF8')::jsonb, convert_from(decode('${Buffer.from(v.sql.map((s) => `-- ${s.title}\n${s.sql};`).join('\n\n')).toString('base64')}', 'base64'), 'UTF8'), ${/^\d{4}-\d\d-\d\d$/.test(through) ? `'${through}'` : 'NULL'}
      ON CONFLICT (log_id, request) DO UPDATE SET checked_at = now(), verdict = excluded.verdict, agreed = excluded.agreed, differed = excluded.differed, details = excluded.details, sql = excluded.sql, data_through = excluded.data_through;`);
  });
  fs.writeFileSync(path.join(out, ref + '.txt'), String.fromCharCode(0xfeff) + text.join('\r\n') + '\r\n');
  console.log(`${ref}  ${[...new Set(res.map((v) => v.verdict))].join(', ').padEnd(12)}  ${line(r.question).slice(0, 80)}`);
}
// a question deleted from the log takes its file with it
const known = new Set(psql('SELECT left(id::text, 8) FROM qa.chat_log').split(/\s+/)); let gone = 0; for (const f of fs.readdirSync(out)) if (/^[0-9a-f]{8}\.txt$/.test(f) && !known.has(f.slice(0, 8))) { fs.rmSync(path.join(out, f)); gone++; }
console.log(`${rows.length} questions checked${rows.length ? ': ' + Object.entries(tally).map(([k, n]) => `${n} ${k}`).join(', ') : ''}.${gone ? ` ${gone} old files deleted.` : ''}\nSQL files: ${out}`);
