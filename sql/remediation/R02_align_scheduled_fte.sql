-- Remediation R02 - scheduled staff counted in the wrong 15 minutes
-- ------------------------------------------------------------------------------------------------
-- Found by:   building the Workforce Management dashboard (its staffing is taken from the schedule to the minute).
--             No data quality rule covers scheduled_fte against the schedule.
-- Root cause: sql/08_aggregates.sql cut each open shift into 15-minute pieces counted from the shift's own start.
--             A piece starting off the quarter hour (15:05-15:20) was counted whole in the slot it started in (15:00).
--             Daily totals are right; single slots are not: phone slots differ by 1.5 FTE on average, 16.3 at most.
-- Source fix: sql/08_aggregates.sql now cuts shifts at the quarter hour, so a rebuild gives the same result as this script.
-- Data fix:   recalculate scheduled_fte from cc.agent_schedule. Each channel group's staff are split across its queues by
--             forecast share, as before. No other column changes. The replaced values are kept in
--             dash.r02_scheduled_fte_before the first time this runs.
-- Feeds:      data/daily_loads/*/interval_volume.csv carry the corrected values too, so reloading November keeps the fix.
-- Safe to re-run: gives the same values again.
\set ON_ERROR_STOP on
SET client_min_messages = warning;
SET TimeZone = 'America/Chicago';
SET work_mem = '256MB';
BEGIN;

CREATE SCHEMA IF NOT EXISTS dash;
CREATE TABLE IF NOT EXISTS dash.r02_scheduled_fte_before AS
SELECT interval_ts, queue_id, scheduled_fte FROM cc.interval_volume;
COMMENT ON TABLE dash.r02_scheduled_fte_before IS 'interval_volume.scheduled_fte as it was before remediation R02.';

CREATE TEMP TABLE r02_sched ON COMMIT DROP AS
SELECT gen.dk(it) AS date_key, gen.iv(it) AS interval_id, a.primary_channel_id AS grp,
       sum(extract(epoch FROM least(s.scheduled_end_ts, it + interval '15 min') - greatest(s.scheduled_start_ts, it))) / 900.0 AS fte
FROM cc.agent_schedule s JOIN cc.dim_agent a USING (agent_id)
CROSS JOIN LATERAL generate_series(date_bin('15 min', s.scheduled_start_ts, timestamptz '2024-01-01 00:00'),
                                   s.scheduled_end_ts - interval '1 ms', interval '15 min') it
WHERE s.activity = 'Open Shift'
GROUP BY 1, 2, 3;

CREATE TEMP TABLE r02_new ON COMMIT DROP AS
SELECT v.interval_ts, v.queue_id,
       round(coalesce(s.fte * v.forecast_contacts / nullif(sum(v.forecast_contacts) OVER (PARTITION BY v.date_key, v.interval_id, g.grp), 0), 0)::numeric, 2) AS fte
FROM cc.interval_volume v
JOIN (SELECT queue_id, CASE WHEN channel_id IN (1, 4) THEN 1 WHEN channel_id = 2 THEN 2 ELSE 3 END AS grp FROM cc.dim_queue) g USING (queue_id)
LEFT JOIN r02_sched s ON s.date_key = v.date_key AND s.interval_id = v.interval_id AND s.grp = g.grp;

WITH u AS (
  UPDATE cc.interval_volume v SET scheduled_fte = n.fte
  FROM r02_new n
  WHERE n.interval_ts = v.interval_ts AND n.queue_id = v.queue_id AND v.scheduled_fte IS DISTINCT FROM n.fte
  RETURNING 1)
SELECT 'interval rows corrected' AS item, count(*) FROM u;

-- Every slot must now match the schedule, and totals must not have moved
DO $$ DECLARE worst numeric; before numeric; after numeric;
BEGIN
  SELECT max(abs(x.st - s.fte)) INTO worst
  FROM r02_sched s
  JOIN (SELECT date_key, interval_id, CASE WHEN channel_id IN (1, 4) THEN 1 WHEN channel_id = 2 THEN 2 ELSE 3 END AS grp, sum(scheduled_fte) AS st, sum(forecast_contacts) AS fc
        FROM cc.interval_volume JOIN cc.dim_queue USING (queue_id) GROUP BY 1, 2, 3) x USING (date_key, interval_id, grp)
  WHERE x.fc > 0;
  IF worst > 0.05 THEN RAISE EXCEPTION 'R02: a slot still differs from the schedule by % FTE', worst; END IF;
  SELECT sum(scheduled_fte) INTO before FROM dash.r02_scheduled_fte_before;
  SELECT sum(v.scheduled_fte) INTO after FROM cc.interval_volume v JOIN dash.r02_scheduled_fte_before b USING (interval_ts, queue_id);
  IF abs(after - before) > before * 0.001 THEN RAISE EXCEPTION 'R02: total scheduled staff moved from % to %', before, after; END IF;
END $$;
COMMIT;
ANALYZE cc.interval_volume;
