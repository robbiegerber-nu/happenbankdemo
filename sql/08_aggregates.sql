-- Aggregates built from the detail tables: interval_volume (15-min x queue) and agent_daily (agent x workday).
\set ON_ERROR_STOP on
SET client_min_messages = warning;
SET max_parallel_workers_per_gather = 0;
SET work_mem = '1GB';
SELECT setseed(0.48);
TRUNCATE cc.interval_volume, cc.agent_daily;

-- ================= interval_volume =================
CREATE TEMP TABLE q_grp AS
SELECT queue_id, channel_id, CASE WHEN channel_id IN (1, 4) THEN 1 WHEN channel_id = 2 THEN 2 ELSE 3 END AS grp FROM cc.dim_queue;

CREATE TEMP TABLE iv_act AS
SELECT c.date_key, c.interval_id, c.queue_id,
       count(*) AS offered,
       count(*) FILTER (WHERE c.answered) AS answered,
       count(*) FILTER (WHERE c.answered AND c.met_service_level) AS answered_within_sl,
       count(*) FILTER (WHERE c.abandoned) AS abandoned,
       count(*) FILTER (WHERE c.short_abandon) AS short_abandoned,
       sum(c.handle_sec) FILTER (WHERE c.answered) AS handle_sum,
       sum(c.queue_wait_sec) FILTER (WHERE c.answered) AS wait_sum
FROM cc.contact c GROUP BY 1, 2, 3;

-- Scheduled FTE per interval x channel group (planned "Open Shift" time)
CREATE TEMP TABLE sched_iv AS
SELECT gen.dk(it) AS date_key, gen.iv(it) AS interval_id, r.grp,
       sum(extract(epoch FROM least(s.scheduled_end_ts, it + interval '15 min') - greatest(s.scheduled_start_ts, it))) / 900.0 AS fte
FROM cc.agent_schedule s JOIN gen.roster r USING (agent_id)
CROSS JOIN LATERAL generate_series(s.scheduled_start_ts, s.scheduled_end_ts - interval '1 ms', interval '15 min') it
WHERE s.activity = 'Open Shift'
GROUP BY 1, 2, 3;

-- Dense grid: every open day x interval x queue (for a clean same-weekday moving-average forecast)
CREATE TEMP TABLE grid AS
SELECT d.date_key, d.full_date, d.day_of_week, i.interval_id, q.queue_id, q.grp,
       (d.full_date + i.interval_start)::timestamptz AS interval_ts
FROM cc.dim_date d CROSS JOIN cc.dim_time_interval i CROSS JOIN q_grp q
WHERE NOT d.is_center_closed OR q.grp = 3;
DELETE FROM grid WHERE gen.iv(interval_ts) <> interval_id;   -- DST spring-forward gap
-- plus any interval with actual volume outside the grid (e.g. callbacks requested on a closed day)
INSERT INTO grid
SELECT a.date_key, d.full_date, d.day_of_week, a.interval_id, a.queue_id, q.grp,
       (d.full_date + i.interval_start)::timestamptz
FROM iv_act a
JOIN cc.dim_date d USING (date_key)
JOIN cc.dim_time_interval i USING (interval_id)
JOIN q_grp q USING (queue_id)
WHERE NOT EXISTS (SELECT 1 FROM grid g WHERE g.date_key = a.date_key AND g.interval_id = a.interval_id AND g.queue_id = a.queue_id);

CREATE TEMP TABLE iv_fc AS
SELECT g.*, coalesce(a.offered, 0) AS offered, coalesce(a.answered, 0) AS answered,
       coalesce(a.answered_within_sl, 0) AS answered_within_sl, coalesce(a.abandoned, 0) AS abandoned,
       coalesce(a.short_abandoned, 0) AS short_abandoned, a.handle_sum, a.wait_sum,
       avg(coalesce(a.offered, 0)) OVER w AS fc,
       sum(a.handle_sum) OVER w / nullif(sum(a.answered) OVER w, 0) AS fc_aht
FROM grid g LEFT JOIN iv_act a USING (date_key, interval_id, queue_id)
WINDOW w AS (PARTITION BY g.queue_id, g.interval_id, g.day_of_week ORDER BY g.date_key ROWS BETWEEN 4 PRECEDING AND 1 PRECEDING);

INSERT INTO cc.interval_volume
SELECT f.interval_ts, f.date_key, f.interval_id, f.queue_id,
       round(coalesce(f.fc, f.offered)::numeric, 2),
       f.offered, f.answered, f.answered_within_sl, f.abandoned, f.short_abandoned,
       round(f.fc_aht::numeric, 1),
       round((f.handle_sum::numeric / nullif(f.answered, 0)), 1),
       round((f.wait_sum::numeric / nullif(f.answered, 0)), 1),
       round(coalesce(s.fte * coalesce(f.fc, f.offered) / nullif(sum(coalesce(f.fc, f.offered)) OVER (PARTITION BY f.date_key, f.interval_id, f.grp), 0), 0)::numeric, 2),
       round(coalesce(coalesce(f.fc, f.offered) * coalesce(f.fc_aht, 480) / (900 * 0.85) / CASE WHEN f.grp = 2 THEN 2.5 ELSE 1 END, 0)::numeric, 2),
       round(100.0 * f.answered_within_sl / nullif(f.answered + f.abandoned - f.short_abandoned, 0), 2),
       round(100.0 * f.abandoned / nullif(f.offered, 0), 2)
FROM iv_fc f
LEFT JOIN sched_iv s ON s.date_key = f.date_key AND s.interval_id = f.interval_id AND s.grp = f.grp
WHERE f.offered > 0 OR coalesce(f.fc, 0) > 0.05;

-- ================= agent_daily =================
CREATE TEMP TABLE sch AS
SELECT agent_id, date_key,
       sum(scheduled_min) FILTER (WHERE activity <> 'PTO') AS scheduled_min,
       sum(scheduled_min) FILTER (WHERE activity = 'Open Shift') AS productive_min,
       sum(scheduled_min) FILTER (WHERE activity = 'Break') AS sched_break,
       sum(scheduled_min) FILTER (WHERE activity = 'Lunch') AS sched_lunch,
       min(scheduled_start_ts) AS first_s, max(scheduled_end_ts) AS last_e,
       bool_or(activity = 'PTO') AS is_pto
FROM cc.agent_schedule GROUP BY 1, 2;

CREATE TEMP TABLE act AS
SELECT agent_id, date_key,
       sum(duration_sec) / 60.0 AS logged_in_min,
       coalesce(sum(duration_sec) FILTER (WHERE state = 'Available'), 0) / 60.0 AS available_min,
       coalesce(sum(duration_sec) FILTER (WHERE state = 'Break'), 0) / 60.0 AS break_min,
       coalesce(sum(duration_sec) FILTER (WHERE state = 'Lunch'), 0) / 60.0 AS lunch_min,
       coalesce(sum(duration_sec) FILTER (WHERE state = 'Training'), 0) / 60.0 AS training_min,
       coalesce(sum(duration_sec) FILTER (WHERE state = 'Coaching'), 0) / 60.0 AS coaching_min,
       coalesce(sum(duration_sec) FILTER (WHERE state = 'Meeting'), 0) / 60.0 AS meeting_min,
       coalesce(sum(duration_sec) FILTER (WHERE state = 'Unavailable'), 0) / 60.0 AS aux_min,
       min(state_start_ts) AS first_a, max(state_end_ts) AS last_a
FROM cc.agent_activity GROUP BY 1, 2;

-- Minutes where the actual state matched the scheduled activity
CREATE TEMP TABLE adh AS
SELECT s.agent_id, s.date_key,
       sum(extract(epoch FROM least(s.scheduled_end_ts, a.state_end_ts) - greatest(s.scheduled_start_ts, a.state_start_ts))) / 60.0 AS in_adh_min
FROM cc.agent_schedule s
JOIN cc.agent_activity a ON a.agent_id = s.agent_id AND a.date_key = s.date_key
 AND a.state_start_ts < s.scheduled_end_ts AND a.state_end_ts > s.scheduled_start_ts
 AND a.state = CASE s.activity WHEN 'Open Shift' THEN 'Available' ELSE s.activity END
WHERE s.activity <> 'PTO'
GROUP BY 1, 2;

CREATE TEMP TABLE ctc AS
SELECT agent_id, gen.dk(answered_ts) AS date_key, count(*) AS n,
       count(*) FILTER (WHERE channel_id = 1) AS n1, count(*) FILTER (WHERE channel_id = 2) AS n2,
       count(*) FILTER (WHERE channel_id = 3) AS n3, count(*) FILTER (WHERE channel_id = 4) AS n4,
       count(*) FILTER (WHERE channel_id = 5) AS n5,
       avg(queue_wait_sec) AS w, avg(talk_sec) AS t, avg(hold_sec) AS h, avg(wrap_sec) AS wr, avg(handle_sec) AS ht,
       sum(handle_sec) / 60.0 AS handle_min, avg(first_contact_resolved::int) AS fcr
FROM cc.contact WHERE answered GROUP BY 1, 2;

INSERT INTO cc.agent_daily
SELECT ad.agent_id, ad.date_key, ad.is_pto, ad.is_absent, ad.nh_training,
       coalesce(s.scheduled_min, 0), coalesce(s.productive_min, 0),
       round(coalesce(a.logged_in_min, 0), 1), round(coalesce(h.in_adh_min, 0), 1),
       CASE WHEN NOT ad.is_pto AND NOT ad.is_absent AND s.scheduled_min > 0 THEN round(100 * coalesce(h.in_adh_min, 0) / s.scheduled_min, 2) END,
       CASE WHEN NOT ad.is_pto AND NOT ad.is_absent AND s.scheduled_min > 0 THEN round(100 * coalesce(a.logged_in_min, 0) / s.scheduled_min, 2) END,
       round(greatest(0, extract(epoch FROM a.first_a - s.first_s) / 60)::numeric, 1) * (a.first_a IS NOT NULL)::int,
       round(greatest(0, extract(epoch FROM s.last_e - a.last_a) / 60)::numeric, 1) * (a.last_a IS NOT NULL)::int,
       round(greatest(0, coalesce(a.break_min, 0) - coalesce(s.sched_break, 0)) + greatest(0, coalesce(a.lunch_min, 0) - coalesce(s.sched_lunch, 0)), 1),
       round(coalesce(a.aux_min, 0), 1), round(coalesce(a.available_min, 0), 1), round(coalesce(c.handle_min, 0), 1),
       CASE WHEN a.available_min > 0 THEN round(least(100, 100 * coalesce(c.handle_min, 0) / a.available_min
                 / CASE WHEN ad.grp = 2 THEN CASE WHEN ad.tenure_days < 90 THEN 2 ELSE ad.lanes_max END ELSE 1 END), 2) END,
       round(coalesce(a.break_min, 0), 1), round(coalesce(a.lunch_min, 0), 1), round(coalesce(a.training_min, 0), 1),
       round(coalesce(a.coaching_min, 0), 1), round(coalesce(a.meeting_min, 0), 1),
       CASE WHEN ad.is_absent THEN coalesce(s.scheduled_min, 0) ELSE 0 END,
       coalesce(c.n, 0), coalesce(c.n1, 0), coalesce(c.n2, 0), coalesce(c.n3, 0), coalesce(c.n4, 0), coalesce(c.n5, 0),
       round(c.w, 1), round(c.t, 1), round(c.h, 1), round(c.wr, 1), round(c.ht, 1), round(100 * c.fcr, 2),
       CASE WHEN c.n > 0 AND random() < .2 THEN least(100, greatest(50, round(86 + 4 * ad.skill_z - 8 * exp(-ad.tenure_days / 90.0)
                 - CASE WHEN ad.site_id = 3 THEN 3 ELSE 0 END + random_normal(0, 5))))::smallint END
FROM gen.agent_day ad
LEFT JOIN sch s USING (agent_id, date_key)
LEFT JOIN act a USING (agent_id, date_key)
LEFT JOIN adh h USING (agent_id, date_key)
LEFT JOIN ctc c USING (agent_id, date_key);
