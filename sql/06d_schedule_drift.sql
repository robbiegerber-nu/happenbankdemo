-- Break/lunch/coaching/meeting timing drift between the PLAN and what agents actually did.
-- Moves scheduled blocks by 5-minute steps (the actual activity and contacts are untouched),
-- so agents who take breaks off-plan show up as out of adherence. Larger drift for chronic offenders,
-- the summer-2025 crunch, new hires, the outsourced site, Mondays and post-holiday days.
\set ON_ERROR_STOP on
SET client_min_messages = warning;
SET max_parallel_workers_per_gather = 0;
SET work_mem = '512MB';
SELECT setseed(0.50);
DROP TABLE IF EXISTS gen.sd, gen.sd_shift;

CREATE TABLE gen.sd AS
SELECT s.schedule_id, s.agent_id, s.date_key, s.activity,
       lag(s.activity) OVER w AS prev_act, lead(s.activity) OVER w AS next_act,
       lag(s.schedule_id) OVER w AS prev_id, lead(s.schedule_id) OVER w AS next_id
FROM cc.agent_schedule s
WINDOW w AS (PARTITION BY s.agent_id, s.date_key ORDER BY s.scheduled_start_ts);

CREATE TABLE gen.sd_shift AS
SELECT sd.schedule_id, sd.prev_id, sd.next_id,
       (round(least(12, greatest(-12, random_normal(0, 4 * m.m))) / 5) * 5)::int AS dmin
FROM gen.sd sd
JOIN gen.agent_day ad ON ad.agent_id = sd.agent_id AND ad.date_key = sd.date_key
CROSS JOIN LATERAL (SELECT (CASE WHEN ad.offender THEN 1.8 ELSE 1 END) * (CASE WHEN ad.crunch THEN 1.5 ELSE 1 END)
                         * (CASE WHEN ad.tenure_days < 90 THEN 1.3 ELSE 1 END) * (CASE WHEN ad.site_id = 3 THEN 1.3 ELSE 1 END)
                         * (CASE WHEN ad.dow = 1 OR ad.post_holiday THEN 1.15 ELSE 1 END) AS m) m
WHERE sd.activity IN ('Break', 'Lunch', 'Coaching', 'Meeting')
  AND sd.prev_act = 'Open Shift' AND sd.next_act = 'Open Shift';
DELETE FROM gen.sd_shift WHERE dmin = 0;

UPDATE cc.agent_schedule s SET scheduled_start_ts = s.scheduled_start_ts + x.dmin * interval '1 min',
                               scheduled_end_ts   = s.scheduled_end_ts   + x.dmin * interval '1 min'
FROM gen.sd_shift x WHERE x.schedule_id = s.schedule_id;
UPDATE cc.agent_schedule s SET scheduled_end_ts = s.scheduled_end_ts + x.dmin * interval '1 min'
FROM gen.sd_shift x WHERE x.prev_id = s.schedule_id;
UPDATE cc.agent_schedule s SET scheduled_start_ts = s.scheduled_start_ts + x.dmin * interval '1 min'
FROM gen.sd_shift x WHERE x.next_id = s.schedule_id;
UPDATE cc.agent_schedule SET scheduled_min = round(extract(epoch FROM scheduled_end_ts - scheduled_start_ts) / 60)::int
WHERE activity = 'Open Shift';

DROP TABLE gen.sd, gen.sd_shift;
VACUUM ANALYZE cc.agent_schedule;
