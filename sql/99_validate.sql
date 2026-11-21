-- Validation: row counts and consistency rules. Every check should say PASS.
\set ON_ERROR_STOP on
SET client_min_messages = warning;
SET work_mem = '1GB';
\pset footer off

\echo '=== Row counts ==='
SELECT t AS table_name, n AS row_count,
       CASE WHEN fact AND n < 100000 THEN 'FAIL (<100K)' WHEN fact THEN 'PASS (>=100K)' ELSE 'lookup' END AS check_100k
FROM (VALUES
 ('dim_date',(SELECT count(*) FROM cc.dim_date),false),('dim_time_interval',(SELECT count(*) FROM cc.dim_time_interval),false),
 ('dim_channel',(SELECT count(*) FROM cc.dim_channel),false),('dim_queue',(SELECT count(*) FROM cc.dim_queue),false),
 ('dim_site',(SELECT count(*) FROM cc.dim_site),false),('dim_team',(SELECT count(*) FROM cc.dim_team),false),
 ('dim_agent',(SELECT count(*) FROM cc.dim_agent),false),('dim_region',(SELECT count(*) FROM cc.dim_region),false),
 ('dim_persona',(SELECT count(*) FROM cc.dim_persona),false),('dim_product',(SELECT count(*) FROM cc.dim_product),false),
 ('product_launch',(SELECT count(*) FROM cc.product_launch),false),('dim_contact_reason',(SELECT count(*) FROM cc.dim_contact_reason),false),
 ('launch_reason_impact',(SELECT count(*) FROM cc.launch_reason_impact),false),
 ('customer',(SELECT count(*) FROM cc.customer),true),('customer_product',(SELECT count(*) FROM cc.customer_product),true),
 ('contact',(SELECT count(*) FROM cc.contact),true),('ivr_session',(SELECT count(*) FROM cc.ivr_session),true),
 ('survey_response',(SELECT count(*) FROM cc.survey_response),true),('interval_volume',(SELECT count(*) FROM cc.interval_volume),true),
 ('agent_schedule',(SELECT count(*) FROM cc.agent_schedule),true),('agent_activity',(SELECT count(*) FROM cc.agent_activity),true),
 ('agent_daily',(SELECT count(*) FROM cc.agent_daily),true),('complaint',(SELECT count(*) FROM cc.complaint),true)
) v(t, n, fact)
ORDER BY fact, t;

\echo '=== Consistency checks ==='
WITH chk(check_name, bad) AS (
  SELECT 'Contacts inside 2024-01-01..2026-10-31', count(*) FROM cc.contact
   WHERE offered_ts < '2024-01-01' OR coalesce(wrap_end_ts, abandoned_ts) >= '2026-11-01'
  UNION ALL SELECT 'Timestamps in order (offered <= answered <= customer_end <= wrap_end)', count(*) FROM cc.contact
   WHERE answered AND NOT (offered_ts <= answered_ts AND answered_ts <= customer_end_ts AND customer_end_ts <= wrap_end_ts)
  UNION ALL SELECT 'queue_wait_sec = answered/abandoned - offered (+/-1s)', count(*) FROM cc.contact
   WHERE abs(queue_wait_sec - extract(epoch FROM coalesce(answered_ts, abandoned_ts) - offered_ts)) > 1
  UNION ALL SELECT 'talk+hold = customer_end - answered (+/-1s)', count(*) FROM cc.contact
   WHERE answered AND abs(talk_sec + hold_sec - extract(epoch FROM customer_end_ts - answered_ts)) > 1
  UNION ALL SELECT 'wrap_sec = wrap_end - customer_end (+/-1s)', count(*) FROM cc.contact
   WHERE answered AND abs(wrap_sec - extract(epoch FROM wrap_end_ts - customer_end_ts)) > 1
  UNION ALL SELECT 'handle_sec = talk + hold + wrap', count(*) FROM cc.contact WHERE handle_sec <> talk_sec + hold_sec + wrap_sec
  UNION ALL SELECT 'Abandoned contacts have no agent, talk or wrap', count(*) FROM cc.contact
   WHERE abandoned AND (agent_id IS NOT NULL OR talk_sec > 0 OR wrap_sec > 0 OR answered)
  UNION ALL SELECT 'Every contact is answered xor abandoned', count(*) FROM cc.contact WHERE answered = abandoned
  UNION ALL SELECT 'Non-chat agents never handle overlapping contacts', count(*) FROM (
     SELECT wrap_end_ts, lead(answered_ts) OVER (PARTITION BY agent_id ORDER BY answered_ts) AS nxt
     FROM cc.contact WHERE answered AND channel_id <> 2) x WHERE nxt < wrap_end_ts
  UNION ALL SELECT 'Chat agents handle at most 3 chats at once', count(*) FROM cc.contact WHERE concurrent_chats > 3
  UNION ALL SELECT 'Contacts handled only while agent is logged in (Available)', count(*) FROM cc.contact c
   WHERE c.answered AND NOT EXISTS (SELECT 1 FROM cc.agent_activity a
     WHERE a.agent_id = c.agent_id AND a.date_key = gen.dk(c.answered_ts) AND a.state = 'Available'
       AND c.answered_ts >= a.state_start_ts AND c.wrap_end_ts <= a.state_end_ts)
  UNION ALL SELECT 'Agent activity states never overlap', count(*) FROM (
     SELECT state_end_ts, lead(state_start_ts) OVER (PARTITION BY agent_id ORDER BY state_start_ts) AS nxt
     FROM cc.agent_activity) x WHERE nxt < state_end_ts - interval '1 ms'
  UNION ALL SELECT 'Schedule blocks never overlap', count(*) FROM (
     SELECT scheduled_end_ts, lead(scheduled_start_ts) OVER (PARTITION BY agent_id ORDER BY scheduled_start_ts) AS nxt
     FROM cc.agent_schedule) x WHERE nxt < scheduled_end_ts
  UNION ALL SELECT 'Contacts only by agents employed that day', count(*) FROM cc.contact c JOIN cc.dim_agent a USING (agent_id)
   WHERE c.answered_ts::date < a.hire_date OR c.answered_ts::date >= coalesce(a.term_date, date '2026-11-01')
  UNION ALL SELECT 'Surveys only for answered contacts', count(*) FROM cc.survey_response s JOIN cc.contact c USING (contact_id) WHERE NOT c.answered
  UNION ALL SELECT 'IVR opt-out sessions link to phone contacts', count(*) FROM cc.ivr_session i JOIN cc.contact c USING (contact_id) WHERE c.channel_id <> 1
  UNION ALL SELECT 'interval_volume offered total = contact count', abs((SELECT sum(offered) FROM cc.interval_volume) - (SELECT count(*) FROM cc.contact))
  UNION ALL SELECT 'interval_volume answered total = answered contacts', abs((SELECT sum(answered) FROM cc.interval_volume) - (SELECT count(*) FROM cc.contact WHERE answered))
  UNION ALL SELECT 'agent_daily contacts total = answered contacts', abs((SELECT sum(contacts_handled) FROM cc.agent_daily) - (SELECT count(*) FROM cc.contact WHERE answered))
  UNION ALL SELECT 'Customer since is before first contact', count(*) FROM cc.contact c JOIN cc.customer cu USING (customer_id) WHERE cu.customer_since > c.offered_ts::date
  UNION ALL SELECT 'Products open before close', count(*) FROM cc.customer_product WHERE close_date < open_date
  UNION ALL SELECT 'Complaints closed after opened', count(*) FROM cc.complaint WHERE closed_ts < opened_ts
  UNION ALL SELECT 'Adherence between 0 and 100', count(*) FROM cc.agent_daily WHERE adherence_pct < 0 OR adherence_pct > 100.5
  UNION ALL SELECT 'Foreign keys defined (expect 43)', 43 - (SELECT count(*) FROM pg_constraint WHERE contype = 'f' AND connamespace = 'cc'::regnamespace)
)
SELECT check_name, bad AS violations, CASE WHEN bad = 0 THEN 'PASS' ELSE 'FAIL' END AS result FROM chk;

\echo '=== Headline KPIs by year and channel ==='
SELECT left(c.date_key::text, 4) AS yr, ch.channel_name,
       count(*) AS offered,
       round(100.0 * count(*) FILTER (WHERE c.answered AND c.met_service_level)
             / nullif(count(*) FILTER (WHERE c.answered OR (c.abandoned AND NOT c.short_abandon)), 0), 1) AS sl_pct,
       round(avg(c.queue_wait_sec) FILTER (WHERE c.answered)) AS asa_sec,
       round(100.0 * count(*) FILTER (WHERE c.abandoned) / count(*), 1) AS abandon_pct,
       round(avg(c.handle_sec) FILTER (WHERE c.answered)) AS aht_sec,
       round(avg(c.wrap_sec) FILTER (WHERE c.answered)) AS wrap_sec,
       round(100 * avg(c.first_contact_resolved::int), 1) AS fcr_pct
FROM cc.contact c JOIN cc.dim_channel ch USING (channel_id)
GROUP BY 1, 2 ORDER BY 1, 2;

SELECT left(date_key::text, 4) AS yr,
       round(100 * sum(in_adherence_min) / sum(scheduled_min) FILTER (WHERE NOT is_pto AND NOT is_absent), 1) AS adherence_pct,
       round(avg(occupancy_pct), 1) AS occupancy_pct
FROM cc.agent_daily WHERE NOT is_pto AND NOT is_absent GROUP BY 1 ORDER BY 1;

SELECT left(date_key::text, 4) AS yr, count(*) AS surveys, round(100 * avg((csat >= 4)::int), 1) AS csat_pct,
       round(100 * (avg((nps >= 9)::int) - avg((nps <= 6)::int)), 1) AS nps, round(avg(ces), 2) AS ces
FROM cc.survey_response GROUP BY 1 ORDER BY 1;
