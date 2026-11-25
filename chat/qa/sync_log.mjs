// Copies the chat's question log from Cloudflare to Postgres (schema qa), using your own Cloudflare sign-in.
//   node chat/qa/sync_log.mjs            new and changed questions
//   node chat/qa/sync_log.mjs --all      everything still in the cloud
//   node chat/qa/sync_log.mjs --local <folder>   a test server's log instead of the real one
// Run it as often as you like: a question already copied is updated, not repeated. Copies older than 90 days are
// deleted, because that is what the page's notice promises. Nothing is written to a file.
// Env overrides: HAPPEN_DB = database, HAPPEN_CHAT = the server's working folder.
import { spawnSync } from 'node:child_process'; import fs from 'node:fs'; import path from 'node:path'; import os from 'node:os'; import { fileURLToPath } from 'node:url';
const KEEP_DAYS = 90, PAGE = 25, here = path.dirname(fileURLToPath(import.meta.url)), dir = process.env.HAPPEN_CHAT || path.join(os.homedir(), 'happen-chat'), PSQL = 'C:\\Program Files\\PostgreSQL\\18\\bin\\psql.exe', args = process.argv.slice(2), at = args.indexOf('--local'), where = at >= 0 ? ['--local', '--persist-to', path.resolve(args[at + 1])] : ['--remote'];
const stop = (m) => { console.error(m); process.exit(1); };
function psql(sql) { const r = spawnSync(PSQL, ['-w', '-h', 'localhost', '-U', 'postgres', '-d', process.env.HAPPEN_DB || 'happen_demo', '-q', '-At', '-v', 'ON_ERROR_STOP=1', '-f', '-'], { input: sql, encoding: 'utf8', maxBuffer: 1e9, env: { ...process.env, PGCLIENTENCODING: 'UTF8' } }); if (r.status) stop('Postgres: ' + (r.stderr || r.error)); return r.stdout.trim(); }
function cloud(sql) {
  const r = spawnSync(process.execPath, ['node_modules/wrangler/bin/wrangler.js', 'd1', 'execute', 'happen-demo-qa', ...where, '--json', '--command', sql], { cwd: dir, encoding: 'utf8', maxBuffer: 1e9, env: { ...process.env, WRANGLER_SEND_METRICS: 'false' } });
  if (r.status) stop('Cloudflare: ' + (r.stdout + r.stderr).slice(0, 800)); return JSON.parse(r.stdout.slice(r.stdout.indexOf('[')))[0].results;
}
psql(fs.readFileSync(path.join(here, 'schema.sql'), 'utf8'));
const tables = cloud("SELECT name FROM sqlite_master WHERE name = 'chat_log'"); if (!tables.length) { console.log('The log is empty: no question has been logged yet.'); process.exit(0); }
// a day of overlap catches questions still being answered at the last copy
const since = args.includes('--all') ? '' : psql("SELECT coalesce(to_char((max(updated_at) - interval '1 day') AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS'), '') FROM qa.chat_log"), before = +psql('SELECT count(*) FROM qa.chat_log');
let got = 0;
for (let last = ''; ;) {
  const rows = cloud(`SELECT * FROM chat_log WHERE updated_at >= '${since}' AND id > '${last}' ORDER BY id LIMIT ${PAGE}`); if (!rows.length) break;
  // sent as base64, so nothing a visitor typed can be read as SQL
  const b64 = Buffer.from(JSON.stringify(rows)).toString('base64');
  psql(`INSERT INTO qa.chat_log AS t (id, conversation, asked_at, updated_at, status, question, answer, label, unchecked, calls, data_through, exported_at, page_version, rules_version, model, usd, seconds)
    SELECT id, conversation, asked_at, updated_at, status, question, answer, label, unchecked, calls::jsonb, data_through, exported_at, page_version, rules_version, model, usd, seconds
    FROM json_to_recordset(convert_from(decode('${b64}', 'base64'), 'UTF8')::json) AS x(id uuid, conversation text, asked_at timestamptz, updated_at timestamptz, status text, question text, answer text, label text, unchecked text, calls text, data_through date, exported_at text, page_version text, rules_version text, model text, usd numeric, seconds numeric)
    ON CONFLICT (id) DO UPDATE SET updated_at = excluded.updated_at, status = excluded.status, answer = excluded.answer, label = excluded.label, unchecked = excluded.unchecked, calls = excluded.calls, model = excluded.model, usd = excluded.usd, seconds = excluded.seconds
    WHERE t.updated_at <= excluded.updated_at;`);
  got += rows.length; last = rows[rows.length - 1].id; if (!/^[0-9a-f-]{36}$/.test(last)) stop('An unexpected id was found in the log.');
}
// readers' reports; your own review notes are never overwritten
if (cloud("SELECT name FROM sqlite_master WHERE name = 'chat_ticket'").length) for (let last = 0; ;) {
  const rows = cloud(`SELECT * FROM chat_ticket WHERE number > ${last} ORDER BY number LIMIT 100`); if (!rows.length) break;
  psql(`INSERT INTO qa.chat_ticket (number, log_id, created_at, reason, comment) SELECT x.number, x.log_id, x.created_at, x.reason, x.comment
    FROM json_to_recordset(convert_from(decode('${Buffer.from(JSON.stringify(rows)).toString('base64')}', 'base64'), 'UTF8')::json) AS x(number int, log_id uuid, created_at timestamptz, reason text, comment text) JOIN qa.chat_log l ON l.id = x.log_id
    ON CONFLICT DO NOTHING;`);
  last = Number(rows[rows.length - 1].number); if (!Number.isInteger(last)) stop('An unexpected ticket number was found.');
}
const added = +psql('SELECT count(*) FROM qa.chat_log') - before, gone = +psql(`WITH d AS (DELETE FROM qa.chat_log WHERE asked_at < now() - interval '${KEEP_DAYS} days' RETURNING 1) SELECT count(*) FROM d`);
console.log(`${got} read, ${added} new, ${gone} older than ${KEEP_DAYS} days deleted. ${psql("SELECT count(*) FROM qa.chat_ticket WHERE status = 'new'")} new tickets. See qa.v_chat_log, qa.v_chat_call and qa.v_chat_ticket in pgAdmin.`);
