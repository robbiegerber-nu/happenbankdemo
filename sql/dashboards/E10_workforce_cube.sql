-- Workforce Management: agent minutes by team, per day and per 15 minutes.
--   dash.wf_day       one row per day x team, from agent_daily (adherence, conformance, shrinkage, occupancy)
--   dash.wf_interval  one row per day x 15 minutes x team: what agents were scheduled to do and what they did
-- In wf_interval, scheduled minutes leave out PTO. For any slice:
--   open (scheduled open shift) = absent + aux (unplanned unavailable) + avail + other
-- where "other" is the net of late starts, early finishes and breaks or lunches taken off schedule (it can be negative).
\set ON_ERROR_STOP on
SET client_min_messages = warning;
SET work_mem = '256MB';
SET TimeZone = 'America/Chicago';

DROP TABLE IF EXISTS dash.wf_day, dash.wf_interval;

CREATE UNLOGGED TABLE dash.wf_day AS
SELECT d.full_date AS d, a.team_id AS t,
       count(*) FILTER (WHERE NOT is_pto AND NOT is_absent AND scheduled_min > 0) AS n,
       count(*) FILTER (WHERE is_absent) AS nabs, count(*) FILTER (WHERE is_pto) AS npto,
       sum(scheduled_min) FILTER (WHERE NOT is_pto) AS sched,
       coalesce(sum(scheduled_min) FILTER (WHERE NOT is_pto AND NOT is_absent), 0) AS worked,
       coalesce(sum(logged_in_min) FILTER (WHERE NOT is_pto AND NOT is_absent), 0) AS li,
       coalesce(sum(in_adherence_min) FILTER (WHERE NOT is_pto AND NOT is_absent), 0) AS adh,
       coalesce(sum(available_min) FILTER (WHERE NOT is_pto AND NOT is_absent), 0) AS av,
       round(coalesce(sum(occupancy_pct * available_min) FILTER (WHERE NOT is_pto AND NOT is_absent), 0), 1) AS occ,
       sum(late_login_min) AS late, sum(early_logout_min) AS early, sum(extended_break_min) AS ext, sum(unplanned_aux_min) AS aux,
       sum(shrinkage_break_min) AS brk, sum(shrinkage_lunch_min) AS lun, sum(shrinkage_training_min) AS trn,
       sum(shrinkage_coaching_min) AS coa, sum(shrinkage_meeting_min) AS mtg, sum(shrinkage_absence_min) AS abs
FROM cc.agent_daily ad JOIN cc.dim_date d USING (date_key) JOIN cc.dim_agent a USING (agent_id)
GROUP BY 1, 2;

CREATE TEMP TABLE day_kind AS SELECT agent_id, date_key, is_pto, is_absent FROM cc.agent_daily;
CREATE UNIQUE INDEX ON day_kind (agent_id, date_key);
ANALYZE day_kind;

CREATE UNLOGGED TABLE dash.wf_interval AS
WITH raw AS (
  SELECT s.agent_id, s.date_key, 'S' AS src, s.activity AS what, s.scheduled_start_ts AS a, s.scheduled_end_ts AS b, k.is_absent
  FROM cc.agent_schedule s JOIN day_kind k USING (agent_id, date_key)
  WHERE NOT k.is_pto AND s.activity <> 'PTO'
  UNION ALL
  SELECT x.agent_id, x.date_key, 'A', x.state, x.state_start_ts, x.state_end_ts, false
  FROM cc.agent_activity x
),
cut AS (
  SELECT r.agent_id, r.date_key, r.src, r.what, r.is_absent, it,
         extract(epoch FROM least(r.b, it + interval '15 min') - greatest(r.a, it)) / 60.0 AS m
  FROM raw r
  CROSS JOIN LATERAL generate_series(date_bin('15 min', r.a, timestamptz '2024-01-01 00:00'), r.b - interval '1 ms', interval '15 min') it
)
SELECT d.full_date AS d, (extract(hour FROM c.it) * 4 + floor(extract(minute FROM c.it) / 15))::int AS i, g.team_id AS t,
       round(coalesce(sum(m) FILTER (WHERE src = 'S' AND what = 'Open Shift'), 0), 1) AS open,
       round(coalesce(sum(m) FILTER (WHERE src = 'S' AND what = 'Break'), 0), 1) AS sbrk,
       round(coalesce(sum(m) FILTER (WHERE src = 'S' AND what = 'Lunch'), 0), 1) AS slun,
       round(coalesce(sum(m) FILTER (WHERE src = 'S' AND what IN ('Coaching', 'Meeting', 'Training')), 0), 1) AS smtg,
       round(coalesce(sum(m) FILTER (WHERE src = 'S' AND what = 'Open Shift' AND is_absent), 0), 1) AS absent,
       round(coalesce(sum(m) FILTER (WHERE src = 'A' AND what = 'Available'), 0), 1) AS avail,
       round(coalesce(sum(m) FILTER (WHERE src = 'A' AND what = 'Unavailable'), 0), 1) AS aux,
       round(coalesce(sum(m) FILTER (WHERE src = 'A' AND what = 'Break'), 0), 1) AS abrk,
       round(coalesce(sum(m) FILTER (WHERE src = 'A' AND what = 'Lunch'), 0), 1) AS alun,
       round(coalesce(sum(m) FILTER (WHERE src = 'A' AND what IN ('Coaching', 'Meeting', 'Training')), 0), 1) AS amtg
FROM cut c JOIN cc.dim_date d USING (date_key) JOIN cc.dim_agent g USING (agent_id)
WHERE m > 0
GROUP BY 1, 2, 3;

CREATE INDEX ON dash.wf_interval (d);
ANALYZE dash.wf_interval;
COMMENT ON TABLE dash.wf_day IS 'Agent minutes by day and team for Workforce Management. Rebuilt by E10_workforce_cube.sql.';
COMMENT ON TABLE dash.wf_interval IS 'Scheduled and actual agent minutes by day, 15 minutes and team for Workforce Management. Rebuilt by E10_workforce_cube.sql.';
