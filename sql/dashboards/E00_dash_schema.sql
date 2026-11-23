-- Shared objects for the dashboard exports, in their own schema so they never mix with the cc data model
-- or the discovery toolkit. Re-running is safe.
\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA IF NOT EXISTS dash;
COMMENT ON SCHEMA dash IS 'Dashboard export helpers: business events and the daily KPI cube behind the Process Stability Monitor. Rebuilt by sql/dashboards/export_dashboards.ps1.';

-- Business events drawn on every time chart (Style Guide: lines for one-day events, bands for periods).
-- The summer 2025 staffing gap is found from the data: the longest unbroken run of Sunday-start weeks in which
-- scheduled phone and chat staff were below required staff.
CREATE OR REPLACE VIEW dash.v_events AS
WITH staff_wk AS (
  SELECT d.full_date - extract(dow FROM d.full_date)::int AS wk,
         (sum(v.scheduled_fte) - sum(v.required_fte)) / nullif(sum(v.required_fte), 0) AS gap
  FROM cc.interval_volume v JOIN cc.dim_date d USING (date_key) JOIN cc.dim_queue q USING (queue_id)
  WHERE q.channel_id IN (1, 2) AND d.full_date BETWEEN '2025-03-01' AND '2025-12-31'
  GROUP BY 1
),
staff_run AS (
  SELECT min(wk) AS start_date, max(wk) + 6 AS end_date
  FROM (SELECT wk, wk - 7 * (row_number() OVER (ORDER BY wk))::int AS island FROM staff_wk WHERE gap < 0) x
  GROUP BY island ORDER BY count(*) DESC LIMIT 1
)
SELECT launch_date AS start_date, launch_date AS end_date, launch_name AS name, launch_type AS kind,
       'One-day'::text AS span,
       launch_type || ' launched ' || to_char(launch_date, 'Mon FMDD, YYYY') AS description
FROM cc.product_launch
UNION ALL
SELECT DATE '2026-04-07', DATE '2026-04-08', 'Online banking outage', 'Outage', 'Period',
       'Two-day online banking outage drove a spike in digital access contacts'
UNION ALL
SELECT start_date, end_date, 'Summer 2025 staffing gap', 'Staffing', 'Period',
       'Hiring freeze left phone and chat scheduled below required staff every week'
FROM staff_run;
COMMENT ON VIEW dash.v_events IS 'Product launches, the April 2026 outage and the summer 2025 staffing gap, for annotating time charts.';
