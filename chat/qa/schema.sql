-- The chat's question log, copied from Cloudflare by sync_log.mjs. Safe to run again.
-- sql/run_all.ps1 recreates the whole database: afterwards, run sync_log.mjs --all to fetch what the cloud still holds.
SET client_min_messages = warning;
CREATE SCHEMA IF NOT EXISTS qa;
CREATE TABLE IF NOT EXISTS qa.chat_log (
  id            uuid PRIMARY KEY,
  conversation  text NOT NULL,
  asked_at      timestamptz NOT NULL,
  updated_at    timestamptz NOT NULL,
  status        text NOT NULL,
  question      text NOT NULL,
  answer        text,
  label         text,
  unchecked     text,
  calls         jsonb NOT NULL,
  data_through  date,
  exported_at   text,
  page_version  text,
  rules_version text,
  model         text,
  usd           numeric NOT NULL,
  seconds       numeric
);
COMMENT ON TABLE  qa.chat_log IS 'One row per question asked of the AI chat with an access code. Kept 90 days.';
COMMENT ON COLUMN qa.chat_log.id IS 'The first 8 characters are the reference shown under the answer.';
COMMENT ON COLUMN qa.chat_log.conversation IS 'Short code that groups follow-up questions. It does not identify anyone.';
COMMENT ON COLUMN qa.chat_log.status IS 'asked (never finished), answered, declined (safety check), too_long, ai_error, limit.';
COMMENT ON COLUMN qa.chat_log.label IS 'The label the reader saw above the answer.';
COMMENT ON COLUMN qa.chat_log.unchecked IS 'Figures in the answer that were not found in the dashboard results.';
COMMENT ON COLUMN qa.chat_log.calls IS 'What the AI requested and the results the page sent back, in order.';
COMMENT ON COLUMN qa.chat_log.data_through IS 'Last day of data on the page when the question was asked, as the page reported it.';
COMMENT ON COLUMN qa.chat_log.rules_version IS 'Fingerprint of the AI rules, tools and model settings.';

CREATE OR REPLACE VIEW qa.v_chat_log AS
SELECT left(id::text, 8) AS reference, asked_at AT TIME ZONE 'America/Chicago' AS asked_central, conversation, status, label, question, answer, unchecked,
       jsonb_array_length(calls) AS requests, data_through, rules_version, model, round(usd, 4) AS usd, round(seconds, 1) AS seconds, id
FROM qa.chat_log ORDER BY asked_at DESC;

CREATE OR REPLACE VIEW qa.v_chat_call AS
SELECT left(l.id::text, 8) AS reference, l.asked_at AT TIME ZONE 'America/Chicago' AS asked_central, l.question, x.n AS request, x.c ->> 'name' AS tool,
       x.c -> 'input' ->> 'metric' AS metric, x.c -> 'input' ->> 'from' AS from_month, x.c -> 'input' ->> 'to' AS to_month, x.c -> 'input' -> 'filters' AS filters,
       x.c -> 'input' ->> 'by' AS split_by, x.c -> 'result' ->> 'value' AS value, x.c ->> 'error' AS error, x.c -> 'input' AS input, x.c -> 'result' AS result, l.id
FROM qa.chat_log l CROSS JOIN LATERAL jsonb_array_elements(l.calls) WITH ORDINALITY AS x(c, n) ORDER BY l.asked_at DESC, x.n;

-- ---------- Checks against the source tables (verify_log.mjs) ----------
CREATE TABLE IF NOT EXISTS qa.chat_check (
  log_id       uuid NOT NULL REFERENCES qa.chat_log (id) ON DELETE CASCADE,
  request      int NOT NULL,
  checked_at   timestamptz NOT NULL DEFAULT now(),
  verdict      text NOT NULL,
  agreed       int NOT NULL,
  differed     int NOT NULL,
  details      jsonb NOT NULL,
  sql          text NOT NULL,
  data_through date,
  PRIMARY KEY (log_id, request)
);
COMMENT ON TABLE  qa.chat_check IS 'One row per request behind a logged answer: what the database says, against what the chat was given.';
COMMENT ON COLUMN qa.chat_check.verdict IS 'match, mismatch, no figure (none was given), not covered (no template yet), not finished, error.';
COMMENT ON COLUMN qa.chat_check.sql IS 'The query, ready to paste into pgAdmin. Fixed templates; the AI writes none of it.';

CREATE OR REPLACE VIEW qa.v_chat_check AS
SELECT left(l.id::text, 8) AS reference, l.asked_at AT TIME ZONE 'America/Chicago' AS asked_central, l.question, k.request, c.value ->> 'name' AS tool, c.value -> 'input' AS input, k.verdict, k.agreed, k.differed,
       (SELECT string_agg((x ->> 'what') || ': chat ' || coalesce(x ->> 'logged', '-') || ', database ' || coalesce(x ->> 'database', '-'), E'\n') FROM jsonb_array_elements(k.details) x WHERE NOT (x ->> 'ok')::boolean) AS differences,
       k.sql, k.checked_at AT TIME ZONE 'America/Chicago' AS checked_central, k.data_through AS checked_data_through, l.data_through AS asked_data_through, l.id
FROM qa.chat_check k JOIN qa.chat_log l ON l.id = k.log_id LEFT JOIN LATERAL (SELECT l.calls -> (k.request - 1) AS value) c ON true
ORDER BY l.asked_at DESC, k.request;

-- one row per question, with what a person still needs to look at
CREATE OR REPLACE VIEW qa.v_chat_verdict AS
SELECT left(l.id::text, 8) AS reference, l.asked_at AT TIME ZONE 'America/Chicago' AS asked_central, l.status, l.label, l.question, l.answer,
       CASE WHEN count(k.*) = 0 THEN 'not checked yet' WHEN bool_or(k.verdict = 'mismatch') THEN 'mismatch' WHEN bool_or(k.verdict = 'error') THEN 'error' WHEN bool_or(k.verdict = 'not finished') THEN 'not finished'
            WHEN bool_or(k.verdict = 'not covered') AND bool_or(k.verdict = 'match') THEN 'match, partly covered' WHEN bool_or(k.verdict = 'not covered') THEN 'not covered' WHEN bool_or(k.verdict = 'match') THEN 'match' ELSE 'no figure' END AS verdict,
       sum(k.agreed) AS agreed, sum(k.differed) AS differed,
       CASE WHEN l.status <> 'answered' THEN 'Not answered: read it' WHEN bool_or(k.verdict IN ('mismatch', 'error')) THEN 'Figure differs: investigate' WHEN l.label = 'Check the figures' THEN 'Figure in the answer not in the results: ' || coalesce(l.unchecked, '')
            WHEN bool_or(k.verdict = 'match') AND NOT bool_or(k.verdict IN ('not covered', 'not finished')) THEN 'Figures agree: wording only' ELSE 'Read the answer' END AS for_a_person, l.id
FROM qa.chat_log l LEFT JOIN qa.chat_check k ON k.log_id = l.id GROUP BY l.id ORDER BY l.asked_at DESC;
