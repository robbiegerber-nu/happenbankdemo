-- Validation queries: Data quality
-- The page opens on the latest discovery run (run 22). Here the date range is the day a run was made, or the business day, as noted.
-- Run one query at a time (select it, then run). Every query only reads data.
-- Filters: 'All' means no filter. Separate several values with ' | ', for example 'Phone | Chat'.
-- Names must match exactly, including capitals. See README.md in this folder.

-- ====================================================================================================
-- 11.1  Health score of each run
-- On the page: the Overall health score tile and the health over time chart (score recalculated from the check results)
-- Expected with the values below (checked Nov 24, 2026): run 22: 100.0, 101 checks, 101 passed; run 7: 91.1, 89 passed, 4 warned, 6 failed
-- ====================================================================================================
WITH settings AS (
  SELECT   -- <<< CHANGE THESE VALUES >>>
    DATE '2026-11-21'              AS start_date,              -- runs made on or after (a date)
    DATE '2026-11-30'              AS end_date,                -- runs made on or before
    'All'::text                    AS table_name,              -- e.g. contact
    'All'::text                    AS dimension                -- Completeness, Uniqueness, Validity, Consistency, Volume, ...
)
SELECT r.run_id, r.started_at::date AS run_date, r.business_date, count(*) AS checks, count(*) FILTER (WHERE c.status = 'Pass') AS passed,
       count(*) FILTER (WHERE c.status = 'Warn') AS warned, count(*) FILTER (WHERE c.status IN ('Fail', 'Error')) AS failed,
       round(100.0 * sum(w.weight * CASE c.status WHEN 'Pass' THEN 1 WHEN 'Warn' THEN 0.5 ELSE 0 END) / sum(w.weight), 1) AS score
FROM discovery.dq_run r JOIN discovery.dq_check_result c USING (run_id) CROSS JOIN settings s
CROSS JOIN LATERAL (SELECT CASE c.severity WHEN 'Critical' THEN 4 WHEN 'High' THEN 3 WHEN 'Medium' THEN 2 ELSE 1 END AS weight) w
WHERE r.started_at::date BETWEEN s.start_date AND s.end_date
    AND (s.table_name = 'All' OR c.table_name = ANY (string_to_array(s.table_name, ' | ')))
    AND (s.dimension = 'All' OR c.dimension = ANY (string_to_array(s.dimension, ' | ')))
GROUP BY r.run_id, r.started_at, r.business_date
ORDER BY r.run_id DESC;


-- ====================================================================================================
-- 11.2  Check results
-- On the page: the check results list
-- Expected with the values below (checked Nov 24, 2026): run 7 has 6 Fail and 4 Warn; run 22 has none
-- ====================================================================================================
WITH settings AS (
  SELECT   -- <<< CHANGE THESE VALUES >>>
    DATE '2026-11-21'              AS start_date,              -- runs made on or after
    DATE '2026-11-30'              AS end_date,                -- runs made on or before
    '7'::text                      AS run,                     -- one run number, or All
    'Fail | Warn'::text            AS status,                  -- Pass, Warn, Fail, Error
    'All'::text                    AS table_name,              -- e.g. contact
    'All'::text                    AS rule                     -- e.g. CON-018
)
SELECT c.run_id, c.status, c.severity, c.rule_id, c.table_name, c.dimension, c.rule_name, c.measured_value, c.unit, c.warn_above, c.fail_above
FROM discovery.dq_check_result c JOIN discovery.dq_run r USING (run_id) CROSS JOIN settings s
WHERE r.started_at::date BETWEEN s.start_date AND s.end_date
    AND (s.run = 'All' OR c.run_id::text = ANY (string_to_array(s.run, ' | ')))
    AND (s.status = 'All' OR c.status = ANY (string_to_array(s.status, ' | ')))
    AND (s.table_name = 'All' OR c.table_name = ANY (string_to_array(s.table_name, ' | ')))
    AND (s.rule = 'All' OR c.rule_id = ANY (string_to_array(s.rule, ' | ')))
ORDER BY c.run_id DESC, c.status, c.severity, c.rule_id;


-- ====================================================================================================
-- 11.3  Daily record counts, live against the latest run
-- On the page: the Daily volume tab
-- Expected with the values below (checked Nov 24, 2026): difference 0 on every day
-- ====================================================================================================
WITH settings AS (
  SELECT   -- <<< CHANGE THESE VALUES >>>
    DATE '2026-11-01'              AS start_date,              -- first business day
    DATE '2026-11-15'              AS end_date,                -- last business day
    'contact'::text                AS table_name               -- contact, ivr_session, survey_response, complaint, interval_volume, agent_daily
),
live AS (
  SELECT 'contact' AS table_name, date_key, count(*) AS n FROM cc.contact GROUP BY 2
  UNION ALL SELECT 'ivr_session', date_key, count(*) FROM cc.ivr_session GROUP BY 2
  UNION ALL SELECT 'survey_response', date_key, count(*) FROM cc.survey_response GROUP BY 2
  UNION ALL SELECT 'complaint', date_key, count(*) FROM cc.complaint GROUP BY 2
  UNION ALL SELECT 'interval_volume', date_key, count(*) FROM cc.interval_volume GROUP BY 2
  UNION ALL SELECT 'agent_daily', date_key, count(*) FROM cc.agent_daily GROUP BY 2
)
SELECT v.day, v.table_name, coalesce(l.n, 0) AS rows_now, v.row_count AS rows_in_latest_run, coalesce(l.n, 0) - v.row_count AS difference,
       v.baseline, round(v.ratio, 2) AS ratio_to_baseline, v.is_outlier
FROM discovery.dq_daily_volume v CROSS JOIN settings s
LEFT JOIN live l ON l.table_name = v.table_name AND l.date_key = to_char(v.day, 'YYYYMMDD')::int
WHERE v.run_id = (SELECT max(run_id) FROM discovery.dq_daily_volume) AND v.table_name = s.table_name AND v.day BETWEEN s.start_date AND s.end_date
ORDER BY v.day;


-- ====================================================================================================
-- 11.4  Incidents
-- On the page: the Incidents tab
-- Expected with the values below (checked Nov 24, 2026): 10 incidents
-- ====================================================================================================
WITH settings AS (
  SELECT   -- <<< CHANGE THESE VALUES >>>
    DATE '2026-11-01'              AS start_date,              -- first business day
    DATE '2026-11-15'              AS end_date,                -- last business day
    'All'::text                    AS status                   -- Open, Resolved, Accepted (the page calls Accepted "Explained")
)
SELECT i.business_date, i.status, i.rule_id, i.title, i.impact, i.fix, i.opened_run_id, i.resolved_run_id, count(*) OVER () AS incidents_listed
FROM discovery.dq_incident i CROSS JOIN settings s
WHERE i.business_date BETWEEN s.start_date AND s.end_date
    AND (s.status = 'All' OR i.status = ANY (string_to_array(s.status, ' | ')))
ORDER BY i.business_date, i.incident_id;


-- ====================================================================================================
-- 11.5  Files loaded each day
-- On the page: the Daily load section of a run
-- Expected with the values below (checked Nov 24, 2026): 131 files (about 9 a day: daily, late and correction files)
-- ====================================================================================================
WITH settings AS (
  SELECT   -- <<< CHANGE THESE VALUES >>>
    DATE '2026-11-01'              AS start_date,              -- first day the file arrived
    DATE '2026-11-15'              AS end_date,                -- last day
    'All'::text                    AS feed,                    -- e.g. contact, survey_response
    'All'::text                    AS load_kind,               -- Daily, Late, Correction
    'All'::text                    AS status                   -- Loaded, Count mismatch, Missing
)
SELECT l.arrived_on, l.business_date, l.feed, l.load_kind, l.action, l.status, l.expected_rows, l.rows_received, l.rows_inserted, l.rows_replaced,
       l.rows_deleted, l.rows_held, l.rows_released
FROM discovery.dq_load l CROSS JOIN settings s
WHERE l.arrived_on BETWEEN s.start_date AND s.end_date
    AND (s.feed = 'All' OR l.feed = ANY (string_to_array(s.feed, ' | ')))
    AND (s.load_kind = 'All' OR l.load_kind = ANY (string_to_array(s.load_kind, ' | ')))
    AND (s.status = 'All' OR l.status = ANY (string_to_array(s.status, ' | ')))
ORDER BY l.load_id;
