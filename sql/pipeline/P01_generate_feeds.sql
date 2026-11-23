-- Builds the 15 daily feeds for 1-15 Nov 2026 (v3.1 demo), including the planted problems and the files that fix them.
--
-- Clean data: each November day replays the same weekday four weeks earlier (4-18 Oct): every record gets a new ID
-- (old ID + 10,000,000) and moves 28 days forward, keeping its local time of day. Veterans Day (11 Nov) keeps ~60%.
-- Feeds carry each record's final outcome (an email answered the next day arrives with its answer): a simplification,
-- so a record never needs a later update unless something went wrong.
--
-- feedgen.plan lists every file to write: which day's folder it arrives in, whether it is a daily, late or correction
-- file, the SQL that produces it, and the sender's notes. generate_feeds.ps1 writes the CSVs and manifests from it.
\set ON_ERROR_STOP on
SET client_min_messages = warning;
SET TimeZone = 'America/Chicago';
DROP SCHEMA IF EXISTS feedgen CASCADE;
CREATE SCHEMA feedgen;

-- ---------- Clean replay (each row kept as a cc.<table> record, plus its business day) ----------
-- Veterans Day: 40% of 14 Oct's contacts are dropped (contact_id % 5 in 0,1), with the IVR calls, surveys and complaints tied to them
CREATE TABLE feedgen.contact AS
SELECT (c.offered_ts + interval '28 days')::date AS bday,
       jsonb_populate_record(c, jsonb_build_object(
         'contact_id', c.contact_id + 10000000,
         'date_key', to_char(c.offered_ts + interval '28 days', 'YYYYMMDD')::int,
         'offered_ts', c.offered_ts + interval '28 days', 'answered_ts', c.answered_ts + interval '28 days',
         'abandoned_ts', c.abandoned_ts + interval '28 days', 'customer_end_ts', c.customer_end_ts + interval '28 days',
         'wrap_end_ts', c.wrap_end_ts + interval '28 days')) AS rec
FROM cc.contact c
WHERE c.offered_ts >= '2026-10-04' AND c.offered_ts < '2026-10-19' AND c.contact_id < 10000000
  AND NOT (c.offered_ts::date = '2026-10-14' AND c.contact_id % 5 IN (0, 1));
CREATE INDEX ON feedgen.contact (bday);
CREATE TABLE feedgen.kept AS SELECT (rec).contact_id - 10000000 AS src_id FROM feedgen.contact;
ALTER TABLE feedgen.kept ADD PRIMARY KEY (src_id);

CREATE TABLE feedgen.ivr_session AS
SELECT (i.start_ts + interval '28 days')::date AS bday,
       jsonb_populate_record(i, jsonb_build_object(
         'session_id', i.session_id + 10000000, 'contact_id', i.contact_id + 10000000,
         'date_key', to_char(i.start_ts + interval '28 days', 'YYYYMMDD')::int,
         'start_ts', i.start_ts + interval '28 days', 'end_ts', i.end_ts + interval '28 days')) AS rec
FROM cc.ivr_session i
WHERE i.start_ts >= '2026-10-04' AND i.start_ts < '2026-10-19' AND i.session_id < 10000000
  AND (i.contact_id IS NULL OR EXISTS (SELECT 1 FROM feedgen.kept k WHERE k.src_id = i.contact_id))
  AND NOT (i.contact_id IS NULL AND i.start_ts::date = '2026-10-14' AND i.session_id % 5 IN (0, 1));

CREATE TABLE feedgen.survey_response AS
SELECT (s.survey_ts + interval '28 days')::date AS bday,
       jsonb_populate_record(s, jsonb_build_object(
         'survey_id', s.survey_id + 10000000, 'contact_id', s.contact_id + 10000000,
         'date_key', to_char(s.survey_ts + interval '28 days', 'YYYYMMDD')::int,
         'survey_ts', s.survey_ts + interval '28 days')) AS rec
FROM cc.survey_response s
WHERE s.survey_ts >= '2026-10-04' AND s.survey_ts < '2026-10-19' AND s.survey_id < 10000000
  AND EXISTS (SELECT 1 FROM feedgen.kept k WHERE k.src_id = s.contact_id);   -- surveys of contacts before 4 Oct are not replayed

CREATE TABLE feedgen.complaint AS
SELECT (k.opened_ts + interval '28 days')::date AS bday,
       jsonb_populate_record(k, jsonb_build_object(
         'complaint_id', k.complaint_id + 10000000, 'contact_id', k.contact_id + 10000000,
         'date_key', to_char(k.opened_ts + interval '28 days', 'YYYYMMDD')::int,
         'opened_ts', k.opened_ts + interval '28 days', 'closed_ts', k.closed_ts + interval '28 days')) AS rec
FROM cc.complaint k
WHERE k.opened_ts >= '2026-10-04' AND k.opened_ts < '2026-10-19' AND k.complaint_id < 10000000
  AND (k.contact_id IS NULL OR EXISTS (SELECT 1 FROM feedgen.kept x WHERE x.src_id = k.contact_id));

CREATE TABLE feedgen.agent_activity AS
SELECT to_date(a.date_key::text, 'YYYYMMDD') + 28 AS bday,
       jsonb_populate_record(a, jsonb_build_object(
         'activity_id', a.activity_id + 10000000, 'date_key', to_char(to_date(a.date_key::text, 'YYYYMMDD') + 28, 'YYYYMMDD')::int,
         'state_start_ts', a.state_start_ts + interval '28 days', 'state_end_ts', a.state_end_ts + interval '28 days')) AS rec
FROM cc.agent_activity a
WHERE a.date_key BETWEEN 20261004 AND 20261018 AND a.activity_id < 10000000;

CREATE TABLE feedgen.agent_schedule AS
SELECT to_date(a.date_key::text, 'YYYYMMDD') + 28 AS bday,
       jsonb_populate_record(a, jsonb_build_object(
         'schedule_id', a.schedule_id + 10000000, 'date_key', to_char(to_date(a.date_key::text, 'YYYYMMDD') + 28, 'YYYYMMDD')::int,
         'scheduled_start_ts', a.scheduled_start_ts + interval '28 days', 'scheduled_end_ts', a.scheduled_end_ts + interval '28 days')) AS rec
FROM cc.agent_schedule a
WHERE a.date_key BETWEEN 20261004 AND 20261018 AND a.schedule_id < 10000000;

-- Summaries are rebuilt from the replayed contacts so they reconcile exactly (contacts by the day they were answered,
-- 15-minute counts by the interval they were offered)
CREATE TABLE feedgen.agent_daily AS
WITH h AS (
  SELECT (rec).agent_id AS agent_id, to_char((rec).answered_ts, 'YYYYMMDD')::int AS date_key, count(*) AS n,
         count(*) FILTER (WHERE (rec).channel_id = 1) AS ph, count(*) FILTER (WHERE (rec).channel_id = 2) AS ch,
         count(*) FILTER (WHERE (rec).channel_id = 3) AS em, count(*) FILTER (WHERE (rec).channel_id = 4) AS cb,
         count(*) FILTER (WHERE (rec).channel_id = 5) AS sm
  FROM feedgen.contact WHERE (rec).answered GROUP BY 1, 2)
SELECT to_date(a.date_key::text, 'YYYYMMDD') + 28 AS bday,
       jsonb_populate_record(a, jsonb_build_object(
         'date_key', to_char(to_date(a.date_key::text, 'YYYYMMDD') + 28, 'YYYYMMDD')::int,
         'contacts_handled', coalesce(h.n, 0), 'phone_contacts', coalesce(h.ph, 0), 'chat_contacts', coalesce(h.ch, 0),
         'email_contacts', coalesce(h.em, 0), 'callback_contacts', coalesce(h.cb, 0), 'secure_msg_contacts', coalesce(h.sm, 0))) AS rec
FROM cc.agent_daily a
LEFT JOIN h ON h.agent_id = a.agent_id AND h.date_key = to_char(to_date(a.date_key::text, 'YYYYMMDD') + 28, 'YYYYMMDD')::int
WHERE a.date_key BETWEEN 20261004 AND 20261018;

CREATE TABLE feedgen.interval_volume AS
WITH c AS (
  SELECT (rec).date_key AS date_key, (rec).interval_id AS interval_id, (rec).queue_id AS queue_id, count(*) AS offered,
         count(*) FILTER (WHERE (rec).answered) AS answered,
         count(*) FILTER (WHERE (rec).answered AND (rec).met_service_level) AS within_sl,
         count(*) FILTER (WHERE (rec).abandoned) AS abandoned, count(*) FILTER (WHERE (rec).short_abandon) AS short_ab
  FROM feedgen.contact GROUP BY 1, 2, 3)
SELECT to_date(v.date_key::text, 'YYYYMMDD') + 28 AS bday,
       jsonb_populate_record(v, jsonb_build_object(
         'interval_ts', v.interval_ts + interval '28 days',
         'date_key', to_char(to_date(v.date_key::text, 'YYYYMMDD') + 28, 'YYYYMMDD')::int,
         'offered', coalesce(c.offered, 0), 'answered', coalesce(c.answered, 0), 'answered_within_sl', coalesce(c.within_sl, 0),
         'abandoned', coalesce(c.abandoned, 0), 'short_abandoned', coalesce(c.short_ab, 0))) AS rec
FROM cc.interval_volume v
LEFT JOIN c ON c.date_key = to_char(to_date(v.date_key::text, 'YYYYMMDD') + 28, 'YYYYMMDD')::int
           AND c.interval_id = v.interval_id AND c.queue_id = v.queue_id
WHERE v.date_key BETWEEN 20261004 AND 20261018;

-- Every 15-minute row must exist for the contacts it summarises
DO $$ BEGIN
  IF (SELECT sum((rec).offered) FROM feedgen.interval_volume) <> (SELECT count(*) FROM feedgen.contact) THEN
    RAISE EXCEPTION 'replayed 15-minute summary does not cover every replayed contact';
  END IF;
END $$;

-- ---------- The plan: every file, in the folder of the day it arrives ----------
CREATE TABLE feedgen.plan (
  arrived    date NOT NULL,      -- folder data/daily_loads/<arrived>/ (late and correction files in its late/ or corrections/ subfolder)
  kind       text NOT NULL,      -- Daily | Late | Correction
  fixes      date,               -- late and correction files: the business day they are for
  feed       text NOT NULL,
  file_name  text NOT NULL,
  action     text NOT NULL,      -- insert | upsert | delete
  query      text NOT NULL,      -- produces the file's rows
  expected   text,               -- produces the row count the sender declares in the manifest (defaults to the file's rows)
  missing    boolean NOT NULL DEFAULT false,   -- listed in the manifest but never delivered
  reason     text, cause text, fix text,
  note       text                -- what is planted (for the reader of this script; not written to the manifest)
);

-- Daily files: every feed, every day, clean unless replaced below
INSERT INTO feedgen.plan (arrived, kind, feed, file_name, action, query)
SELECT d::date, 'Daily', f, f || '.csv', 'insert',
       format('SELECT (rec).* FROM feedgen.%I WHERE bday = %L', f, d::date)
FROM generate_series(timestamp '2026-11-01', timestamp '2026-11-15', interval '1 day') d,
     unnest(ARRAY['contact', 'ivr_session', 'survey_response', 'complaint', 'agent_activity', 'agent_schedule', 'agent_daily', 'interval_volume']) f;

CREATE FUNCTION feedgen.daily(d date, f text) RETURNS text LANGUAGE sql AS
$$ SELECT format('SELECT (rec).* FROM feedgen.%I WHERE bday = %L', f, d) $$;

-- 2 Nov: the contact file contains every contact twice; the copies have new IDs (+5,000,000). The manifest declares the real count.
UPDATE feedgen.plan SET query = feedgen.daily('2026-11-02', 'contact') || $$ UNION ALL
  SELECT (jsonb_populate_record(rec, jsonb_build_object('contact_id', (rec).contact_id + 5000000))).* FROM feedgen.contact WHERE bday = '2026-11-02'$$,
  expected = $$SELECT count(*) FROM feedgen.contact WHERE bday = '2026-11-02'$$,
  note = 'Planted: every contact sent twice'
WHERE arrived = '2026-11-02' AND feed = 'contact';

-- 3 Nov: answered contacts with contact_id ending in 3 lose their agent
UPDATE feedgen.plan SET query = $$SELECT (CASE WHEN (rec).answered AND (rec).contact_id % 10 = 3
    THEN jsonb_populate_record(rec, '{"agent_id": null}') ELSE rec END).* FROM feedgen.contact WHERE bday = '2026-11-03'$$,
  note = 'Planted: agent missing on about 1 in 10 answered contacts'
WHERE arrived = '2026-11-03' AND feed = 'contact';

-- 4 Nov: agent activity never arrives; the agent-day summary is built from the empty extract (0 minutes logged in)
UPDATE feedgen.plan SET missing = true, note = 'Planted: file never delivered'
WHERE arrived = '2026-11-04' AND feed = 'agent_activity';
UPDATE feedgen.plan SET query = $$SELECT (CASE WHEN (rec).logged_in_min > 0
    THEN jsonb_populate_record(rec, '{"logged_in_min": 0, "available_min": 0, "in_adherence_min": 0}') ELSE rec END).*
  FROM feedgen.agent_daily WHERE bday = '2026-11-04'$$,
  note = 'Planted: summary built from the empty activity extract'
WHERE arrived = '2026-11-04' AND feed = 'agent_daily';

-- 5 Nov: offered time written in UTC (+5 hours) while the other times stay local; wait times computed from it go negative
UPDATE feedgen.plan SET query = $$SELECT (jsonb_populate_record(rec, jsonb_build_object(
      'offered_ts', (rec).offered_ts + interval '5 hours', 'queue_wait_sec', (rec).queue_wait_sec - 18000))).*
  FROM feedgen.contact WHERE bday = '2026-11-05'$$,
  note = 'Planted: offered time in UTC'
WHERE arrived = '2026-11-05' AND feed = 'contact';

-- 7 Nov: complaint close dates between 7 and 10 Nov read as day/month (11/09 -> 11 Sep), so they close before they open
UPDATE feedgen.plan SET query = $$SELECT (CASE WHEN extract(day FROM (rec).closed_ts) BETWEEN 7 AND 10 AND (rec).closed_ts < '2026-11-11'
    THEN jsonb_populate_record(rec, jsonb_build_object(
      'closed_ts', make_date(2026, extract(day FROM (rec).closed_ts)::int, 11) + (rec).closed_ts::time,
      'days_to_close', round(extract(epoch FROM (make_date(2026, extract(day FROM (rec).closed_ts)::int, 11) + (rec).closed_ts::time)::timestamptz - (rec).opened_ts) / 86400, 1)))
    ELSE rec END).* FROM feedgen.complaint WHERE bday = '2026-11-07'$$,
  note = 'Planted: close dates read as day/month'
WHERE arrived = '2026-11-07' AND feed = 'complaint';

-- 9 Nov: the contact file never arrives (IVR calls, surveys and complaints that refer to its contacts are held by the loader)
UPDATE feedgen.plan SET missing = true, note = 'Planted: file never delivered'
WHERE arrived = '2026-11-09' AND feed = 'contact';

-- 10 Nov: emails, secure messages and callbacks arrive without the customer
UPDATE feedgen.plan SET query = $$SELECT (CASE WHEN (rec).channel_id IN (3, 4, 5)
    THEN jsonb_populate_record(rec, '{"customer_id": null}') ELSE rec END).* FROM feedgen.contact WHERE bday = '2026-11-10'$$,
  note = 'Planted: customer missing on emails, messages and callbacks'
WHERE arrived = '2026-11-10' AND feed = 'contact';

-- 12 Nov: the survey vendor credits each survey to the wrong agent (the agent on the next survey in the file)
UPDATE feedgen.plan SET query = $$SELECT (jsonb_populate_record(rec, jsonb_build_object('agent_id', coalesce(nxt, first_agent)))).*
  FROM (SELECT rec, lead((rec).agent_id) OVER (ORDER BY (rec).survey_id) AS nxt,
               first_value((rec).agent_id) OVER (ORDER BY (rec).survey_id) AS first_agent
        FROM feedgen.survey_response WHERE bday = '2026-11-12') s$$,
  note = 'Planted: surveys credited to the wrong agent'
WHERE arrived = '2026-11-12' AND feed = 'survey_response';

-- 14 Nov: 1 in 7 answered contacts assigned to recycled IDs of agents who left (302, 271, 331)
UPDATE feedgen.plan SET query = $$SELECT (CASE WHEN (rec).answered AND (rec).contact_id % 7 = 0
    THEN jsonb_populate_record(rec, jsonb_build_object('agent_id', (ARRAY[302, 271, 331])[((rec).contact_id / 7) % 3 + 1])) ELSE rec END).*
  FROM feedgen.contact WHERE bday = '2026-11-14'$$,
  note = 'Planted: contacts assigned to agents who had left'
WHERE arrived = '2026-11-14' AND feed = 'contact';

-- ---------- Late files and corrections, with the sender's explanation ----------
INSERT INTO feedgen.plan (arrived, kind, fixes, feed, file_name, action, query, reason, cause, fix) VALUES
('2026-11-03', 'Correction', '2026-11-02', 'contact', 'contact_delete.csv', 'delete',
 $$SELECT (rec).contact_id + 5000000 AS contact_id FROM feedgen.contact WHERE bday = '2026-11-02'$$, NULL,
 'The 2 Nov contact extract ran twice after a timeout, and both copies went out in one file. The second copy was given new contact IDs.',
 'Delete file removes the second copy of each 2 Nov contact (contact IDs from 15,000,000).'),

('2026-11-04', 'Correction', '2026-11-03', 'contact', 'contact_update.csv', 'upsert',
 $$SELECT (rec).* FROM feedgen.contact WHERE bday = '2026-11-03' AND (rec).answered AND (rec).contact_id % 10 = 3$$, NULL,
 'A routing-platform change on 3 Nov stopped writing the agent ID on some answered contacts.',
 'Update file re-sends the affected 3 Nov contacts with the agent restored.'),

('2026-11-05', 'Late', '2026-11-04', 'agent_activity', 'agent_activity_morning.csv', 'insert',
 $$SELECT (rec).* FROM feedgen.agent_activity WHERE bday = '2026-11-04' AND (rec).state_start_ts::time < '12:00'$$,
 'The agent activity extract for 4 Nov failed. A re-run has delivered the morning so far; the afternoon will follow.', NULL, NULL),

('2026-11-06', 'Late', '2026-11-04', 'agent_activity', 'agent_activity_afternoon.csv', 'insert',
 $$SELECT (rec).* FROM feedgen.agent_activity WHERE bday = '2026-11-04' AND (rec).state_start_ts::time >= '12:00'$$, NULL,
 'The agent activity extract job for 4 Nov failed, so no activity was sent and the agent-day summary was built from an empty extract (0 minutes logged in).',
 'The rest of 4 Nov''s activity was re-extracted, and the agent-day summary was rebuilt and re-sent.'),
('2026-11-06', 'Late', '2026-11-04', 'agent_daily', 'agent_daily_rebuilt.csv', 'upsert',
 $$SELECT (rec).* FROM feedgen.agent_daily WHERE bday = '2026-11-04'$$, NULL, NULL, NULL),

('2026-11-06', 'Correction', '2026-11-05', 'contact', 'contact_replace.csv', 'upsert',
 $$SELECT (rec).* FROM feedgen.contact WHERE bday = '2026-11-05'$$, NULL,
 'A release of the contact export on 5 Nov wrote the offered time in UTC while the other times stayed in local time, which also made wait times negative.',
 'Replacement file re-sends every 5 Nov contact with the local offered time and the correct wait time.'),

('2026-11-08', 'Correction', '2026-11-07', 'complaint', 'complaint_replace.csv', 'upsert',
 $$SELECT (rec).* FROM feedgen.complaint WHERE bday = '2026-11-07' AND extract(day FROM (rec).closed_ts) BETWEEN 7 AND 10 AND (rec).closed_ts < '2026-11-11'$$, NULL,
 'Complaint close dates on 7 Nov were read as day/month instead of month/day, so 11/09 became 11 September.',
 'Replacement file re-sends the affected complaints with the correct close dates.'),

('2026-11-10', 'Late', '2026-11-09', 'contact', 'contact.csv', 'insert',
 $$SELECT (rec).* FROM feedgen.contact WHERE bday = '2026-11-09'$$, NULL,
 'The 9 Nov contact file failed to transfer because a certificate on the file server had expired.',
 'File re-sent after the certificate was renewed. IVR calls, surveys and complaints held for its contacts load with it.'),

('2026-11-11', 'Correction', '2026-11-10', 'contact', 'contact_update.csv', 'upsert',
 $$SELECT (rec).* FROM feedgen.contact WHERE bday = '2026-11-10' AND (rec).channel_id IN (3, 4, 5)$$, NULL,
 'An email-parsing change on 10 Nov stopped matching emails, secure messages and callbacks to customers.',
 'Update file re-sends the affected 10 Nov contacts with the customer restored.'),

('2026-11-13', 'Correction', '2026-11-12', 'survey_response', 'survey_replace.csv', 'upsert',
 $$SELECT (rec).* FROM feedgen.survey_response WHERE bday = '2026-11-12'$$, NULL,
 'The survey vendor''s new matching logic on 12 Nov credited surveys to the wrong agent.',
 'Replacement file re-sends the 12 Nov surveys with the agent who handled each contact.'),

('2026-11-15', 'Correction', '2026-11-14', 'contact', 'contact_update.csv', 'upsert',
 $$SELECT (rec).* FROM feedgen.contact WHERE bday = '2026-11-14' AND (rec).answered AND (rec).contact_id % 7 = 0$$, NULL,
 'After a routing-system change on 14 Nov, some contacts were assigned to recycled agent IDs that belonged to agents who had left.',
 'Update file re-sends the affected 14 Nov contacts with the correct agent.');

SELECT arrived, kind, count(*) AS files, string_agg(feed, ', ' ORDER BY feed) FILTER (WHERE note IS NOT NULL OR kind <> 'Daily') AS special
FROM feedgen.plan GROUP BY 1, 2 ORDER BY 1, 2;
