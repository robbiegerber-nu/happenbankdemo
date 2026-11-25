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
