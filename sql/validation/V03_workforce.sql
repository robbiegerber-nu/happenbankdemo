-- Validation queries: Workforce management
-- The page defaults to Phone agents and the 30 days ending on the last day of data (Oct 17 - Nov 15, 2026).
-- Run one query at a time (select it, then run). Every query only reads data.
-- Filters: 'All' means no filter. Separate several values with ' | ', for example 'Phone | Chat'.
-- Names must match exactly, including capitals. See README.md in this folder.

-- ====================================================================================================
-- 3.1  Adherence, conformance, shrinkage and occupancy
-- On the page: tiles at the top
-- Expected with the values below (checked Nov 24, 2026): adherence 91.0, conformance 100.3, shrinkage 19.1, occupancy 75.2
-- ====================================================================================================
WITH settings AS (
  SELECT   -- <<< CHANGE THESE VALUES >>>
    DATE '2026-10-17'              AS start_date,              -- first day
    DATE '2026-11-15'              AS end_date,                -- last day (included)
    'Phone'::text                  AS agent_group,             -- Phone, Chat, Email
    'All'::text                    AS site,                    -- Central Campus, Lakeside Center, Partner Site (Outsourced)
    'All'::text                    AS team,                    -- e.g. Phone - Team Atlas
    'All'::text                    AS weekday                  -- Monday, Tuesday, ...
)
SELECT round(100.0 * sum(ad.in_adherence_min) FILTER (WHERE NOT ad.is_pto AND NOT ad.is_absent) / nullif(sum(ad.scheduled_min) FILTER (WHERE NOT ad.is_pto AND NOT ad.is_absent), 0), 1) AS adherence_pct,
       round(100.0 * sum(ad.logged_in_min) FILTER (WHERE NOT ad.is_pto AND NOT ad.is_absent) / nullif(sum(ad.scheduled_min) FILTER (WHERE NOT ad.is_pto AND NOT ad.is_absent), 0), 1) AS conformance_pct,
       round(100.0 * sum(ad.shrinkage_break_min + ad.shrinkage_lunch_min + ad.unplanned_aux_min + ad.shrinkage_absence_min
             + ad.shrinkage_coaching_min + ad.shrinkage_meeting_min + ad.shrinkage_training_min) / nullif(sum(ad.scheduled_min) FILTER (WHERE NOT ad.is_pto), 0), 1) AS shrinkage_pct,
       round(sum(ad.occupancy_pct * ad.available_min) FILTER (WHERE NOT ad.is_pto AND NOT ad.is_absent) / nullif(sum(ad.available_min) FILTER (WHERE NOT ad.is_pto AND NOT ad.is_absent), 0), 1) AS occupancy_pct,
       count(*) FILTER (WHERE NOT ad.is_pto AND NOT ad.is_absent AND ad.scheduled_min > 0) AS agent_days_worked
FROM cc.agent_daily ad
JOIN cc.dim_date d ON d.date_key = ad.date_key
JOIN cc.dim_agent a ON a.agent_id = ad.agent_id
JOIN cc.dim_team t ON t.team_id = a.team_id
JOIN cc.dim_site si ON si.site_id = t.site_id
JOIN cc.dim_channel ch ON ch.channel_id = t.primary_channel_id
CROSS JOIN settings s
WHERE d.full_date BETWEEN s.start_date AND s.end_date
    AND (s.agent_group = 'All' OR ch.channel_name = ANY (string_to_array(s.agent_group, ' | ')))
    AND (s.site = 'All' OR si.site_name = ANY (string_to_array(s.site, ' | ')))
    AND (s.team = 'All' OR t.team_name = ANY (string_to_array(s.team, ' | ')))
    AND (s.weekday = 'All' OR d.day_name = ANY (string_to_array(s.weekday, ' | ')));


-- ====================================================================================================
-- 3.2  Shrinkage by reason
-- On the page: the shrinkage chart
-- Expected with the values below (checked Nov 24, 2026): Breaks 5.9, Lunch 5.2, Unplanned unavailable 4.0, Absence 2.4, Coaching 0.9, Meetings 0.6, Training 0.0
-- ====================================================================================================
WITH settings AS (
  SELECT   -- <<< CHANGE THESE VALUES >>>
    DATE '2026-10-17'              AS start_date,              -- first day
    DATE '2026-11-15'              AS end_date,                -- last day (included)
    'Phone'::text                  AS agent_group,             -- Phone, Chat, Email
    'All'::text                    AS site,                    -- Central Campus, Lakeside Center, Partner Site (Outsourced)
    'All'::text                    AS team,                    -- e.g. Phone - Team Atlas
    'All'::text                    AS weekday                  -- Monday, Tuesday, ...
)
SELECT x.reason, round(sum(x.minutes), 0) AS minutes,
       round(100.0 * sum(x.minutes) / nullif(sum(ad.scheduled_min) FILTER (WHERE NOT ad.is_pto), 0), 1) AS pct_of_scheduled
FROM cc.agent_daily ad
JOIN cc.dim_date d ON d.date_key = ad.date_key
JOIN cc.dim_agent a ON a.agent_id = ad.agent_id
JOIN cc.dim_team t ON t.team_id = a.team_id
JOIN cc.dim_site si ON si.site_id = t.site_id
JOIN cc.dim_channel ch ON ch.channel_id = t.primary_channel_id
CROSS JOIN settings s
CROSS JOIN LATERAL (VALUES ('Breaks', ad.shrinkage_break_min), ('Lunch', ad.shrinkage_lunch_min), ('Unplanned unavailable', ad.unplanned_aux_min),
  ('Absence', ad.shrinkage_absence_min), ('Coaching', ad.shrinkage_coaching_min), ('Meetings', ad.shrinkage_meeting_min), ('Training', ad.shrinkage_training_min)) x(reason, minutes)
WHERE d.full_date BETWEEN s.start_date AND s.end_date
    AND (s.agent_group = 'All' OR ch.channel_name = ANY (string_to_array(s.agent_group, ' | ')))
    AND (s.site = 'All' OR si.site_name = ANY (string_to_array(s.site, ' | ')))
    AND (s.team = 'All' OR t.team_name = ANY (string_to_array(s.team, ' | ')))
    AND (s.weekday = 'All' OR d.day_name = ANY (string_to_array(s.weekday, ' | ')))
GROUP BY 1
ORDER BY 2 DESC;


-- ====================================================================================================
-- 3.3  Teams
-- On the page: the team table
-- Expected with the values below (checked Nov 24, 2026): Phone - Team Keystone (Partner): 89.7, 100.4, 19.6, 75.6, 128 agent-days, absence 2.5, unplanned 20.5 min, long breaks 5.2 min
-- ====================================================================================================
WITH settings AS (
  SELECT   -- <<< CHANGE THESE VALUES >>>
    DATE '2026-10-17'              AS start_date,              -- first day
    DATE '2026-11-15'              AS end_date,                -- last day (included)
    'Phone'::text                  AS agent_group,             -- Phone, Chat, Email
    'All'::text                    AS site,                    -- Central Campus, Lakeside Center, Partner Site (Outsourced)
    'All'::text                    AS team,                    -- e.g. Phone - Team Atlas
    'All'::text                    AS weekday                  -- Monday, Tuesday, ...
)
SELECT t.team_name, si.site_name, round(100.0 * sum(ad.in_adherence_min) FILTER (WHERE NOT ad.is_pto AND NOT ad.is_absent) / nullif(sum(ad.scheduled_min) FILTER (WHERE NOT ad.is_pto AND NOT ad.is_absent), 0), 1) AS adherence_pct,
       round(100.0 * sum(ad.logged_in_min) FILTER (WHERE NOT ad.is_pto AND NOT ad.is_absent) / nullif(sum(ad.scheduled_min) FILTER (WHERE NOT ad.is_pto AND NOT ad.is_absent), 0), 1) AS conformance_pct,
       round(100.0 * sum(ad.shrinkage_break_min + ad.shrinkage_lunch_min + ad.unplanned_aux_min + ad.shrinkage_absence_min
             + ad.shrinkage_coaching_min + ad.shrinkage_meeting_min + ad.shrinkage_training_min) / nullif(sum(ad.scheduled_min) FILTER (WHERE NOT ad.is_pto), 0), 1) AS shrinkage_pct,
       round(sum(ad.occupancy_pct * ad.available_min) FILTER (WHERE NOT ad.is_pto AND NOT ad.is_absent) / nullif(sum(ad.available_min) FILTER (WHERE NOT ad.is_pto AND NOT ad.is_absent), 0), 1) AS occupancy_pct,
       count(*) FILTER (WHERE NOT ad.is_pto AND NOT ad.is_absent AND ad.scheduled_min > 0) AS agent_days_worked,
       round(100.0 * sum(ad.shrinkage_absence_min) / nullif(sum(ad.scheduled_min) FILTER (WHERE NOT ad.is_pto), 0), 1) AS absence_pct,
       round(sum(ad.unplanned_aux_min) / nullif(count(*) FILTER (WHERE NOT ad.is_pto AND NOT ad.is_absent AND ad.scheduled_min > 0), 0), 1) AS unplanned_min_per_day,
       round(sum(ad.extended_break_min) / nullif(count(*) FILTER (WHERE NOT ad.is_pto AND NOT ad.is_absent AND ad.scheduled_min > 0), 0), 1) AS long_break_min_per_day
FROM cc.agent_daily ad
JOIN cc.dim_date d ON d.date_key = ad.date_key
JOIN cc.dim_agent a ON a.agent_id = ad.agent_id
JOIN cc.dim_team t ON t.team_id = a.team_id
JOIN cc.dim_site si ON si.site_id = t.site_id
JOIN cc.dim_channel ch ON ch.channel_id = t.primary_channel_id
CROSS JOIN settings s
WHERE d.full_date BETWEEN s.start_date AND s.end_date
    AND (s.agent_group = 'All' OR ch.channel_name = ANY (string_to_array(s.agent_group, ' | ')))
    AND (s.site = 'All' OR si.site_name = ANY (string_to_array(s.site, ' | ')))
    AND (s.team = 'All' OR t.team_name = ANY (string_to_array(s.team, ' | ')))
    AND (s.weekday = 'All' OR d.day_name = ANY (string_to_array(s.weekday, ' | ')))
GROUP BY 1, 2
ORDER BY adherence_pct;


-- ====================================================================================================
-- 3.4  Staffing vs required, and forecast error
-- On the page: the Staffing and Forecast tiles (Phone and Chat groups, with no site or team filter)
-- Expected with the values below (checked Nov 24, 2026): staffing +14.7, forecast error -4.2
-- ====================================================================================================
WITH settings AS (
  SELECT   -- <<< CHANGE THESE VALUES >>>
    DATE '2026-10-17'              AS start_date,              -- first day
    DATE '2026-11-15'              AS end_date,                -- last day (included)
    'Phone'::text                  AS agent_group,             -- Phone or Chat
    'Phone | Callback'::text       AS contact_channels,        -- what that group serves: Phone | Callback, or Chat
    'All'::text                    AS weekday                  -- Monday, Tuesday, ...
),
open_shift AS (   -- scheduled open-shift minutes, including agents who turned out absent, without PTO
  SELECT d.full_date, sum(extract(epoch FROM sc.scheduled_end_ts - sc.scheduled_start_ts) / 60) AS open_min
  FROM cc.agent_schedule sc JOIN cc.dim_date d ON d.date_key = sc.date_key
  JOIN cc.agent_daily ad ON ad.agent_id = sc.agent_id AND ad.date_key = sc.date_key AND NOT ad.is_pto
  JOIN cc.dim_agent a ON a.agent_id = sc.agent_id
  JOIN cc.dim_team t ON t.team_id = a.team_id
  JOIN cc.dim_channel ch ON ch.channel_id = t.primary_channel_id
  CROSS JOIN settings s
  WHERE d.full_date BETWEEN s.start_date AND s.end_date AND sc.activity = 'Open Shift'
    AND (s.agent_group = 'All' OR ch.channel_name = ANY (string_to_array(s.agent_group, ' | ')))
    AND (s.weekday = 'All' OR d.day_name = ANY (string_to_array(s.weekday, ' | ')))
  GROUP BY 1
),
need AS (
  SELECT d.full_date, sum(v.required_fte) * 15 AS required_min, sum(v.offered) AS offered, sum(v.forecast_contacts) AS forecast
  FROM cc.interval_volume v JOIN cc.dim_date d ON d.date_key = v.date_key
  JOIN cc.dim_queue q ON q.queue_id = v.queue_id
  JOIN cc.dim_channel ch ON ch.channel_id = q.channel_id
  CROSS JOIN settings s
  WHERE d.full_date BETWEEN s.start_date AND s.end_date
    AND (s.contact_channels = 'All' OR ch.channel_name = ANY (string_to_array(s.contact_channels, ' | ')))
    AND (s.weekday = 'All' OR d.day_name = ANY (string_to_array(s.weekday, ' | ')))
  GROUP BY 1
)
SELECT round(sum(o.open_min) / 60, 0) AS scheduled_hours,
       round(sum(n.required_min) FILTER (WHERE o.open_min > 0) / 60, 0) AS required_hours,   -- days with nobody scheduled have no requirement
       round(100.0 * (sum(o.open_min) - sum(n.required_min) FILTER (WHERE o.open_min > 0))
             / nullif(sum(n.required_min) FILTER (WHERE o.open_min > 0), 0), 1) AS staffing_vs_required_pct,
       sum(n.offered) AS offered, round(100.0 * (sum(n.offered) - sum(n.forecast)) / nullif(sum(n.forecast), 0), 1) AS forecast_error_pct
FROM need n LEFT JOIN open_shift o USING (full_date);


-- ====================================================================================================
-- 3.5  One 15-minute slot: required, scheduled and available staff
-- On the page: a row of "Time slots that run short of staff"
-- Expected with the values below (checked Nov 24, 2026): Thursday 13:00: required 53.4, scheduled 48.7, available 43.0, gap -10.4
-- ====================================================================================================
WITH settings AS (
  SELECT   -- <<< CHANGE THESE VALUES >>>
    DATE '2026-10-17'              AS start_date,              -- first day
    DATE '2026-11-15'              AS end_date,                -- last day (included)
    'Phone'::text                  AS agent_group,             -- Phone or Chat
    'Phone | Callback'::text       AS contact_channels,        -- Phone | Callback, or Chat
    'Thursday'::text               AS weekday,                 -- one weekday
    TIME '13:00'                   AS slot_start               -- start of the 15 minutes, 24-hour clock
),
members AS (
  SELECT g.agent_id FROM cc.dim_agent g JOIN cc.dim_team t ON t.team_id = g.team_id JOIN cc.dim_channel ch ON ch.channel_id = t.primary_channel_id
  CROSS JOIN settings s WHERE ch.channel_name = s.agent_group
),
days AS (   -- that weekday's dates on which the group had anyone scheduled
  SELECT DISTINCT d.date_key, (d.full_date + s.slot_start) AT TIME ZONE 'America/Chicago' AS a,
         (d.full_date + s.slot_start) AT TIME ZONE 'America/Chicago' + interval '15 min' AS b
  FROM cc.agent_schedule sc JOIN cc.dim_date d ON d.date_key = sc.date_key JOIN members USING (agent_id) CROSS JOIN settings s
  WHERE d.full_date BETWEEN s.start_date AND s.end_date AND d.day_name = s.weekday AND sc.activity = 'Open Shift'
),
scheduled AS (
  SELECT sum(extract(epoch FROM least(sc.scheduled_end_ts, dy.b) - greatest(sc.scheduled_start_ts, dy.a)) / 60) AS minutes
  FROM cc.agent_schedule sc JOIN days dy USING (date_key) JOIN members USING (agent_id)
  JOIN cc.agent_daily ad ON ad.agent_id = sc.agent_id AND ad.date_key = sc.date_key AND NOT ad.is_pto
  WHERE sc.activity = 'Open Shift' AND sc.scheduled_start_ts < dy.b AND sc.scheduled_end_ts > dy.a
),
available AS (
  SELECT sum(extract(epoch FROM least(x.state_end_ts, dy.b) - greatest(x.state_start_ts, dy.a)) / 60) AS minutes
  FROM cc.agent_activity x JOIN days dy USING (date_key) JOIN members USING (agent_id)
  WHERE x.state = 'Available' AND x.state_start_ts < dy.b AND x.state_end_ts > dy.a
),
required AS (
  SELECT sum(v.required_fte) AS fte
  FROM cc.interval_volume v JOIN days dy USING (date_key) JOIN cc.dim_time_interval ti USING (interval_id)
  JOIN cc.dim_queue q USING (queue_id) JOIN cc.dim_channel ch ON ch.channel_id = q.channel_id CROSS JOIN settings s
  WHERE ti.interval_start = s.slot_start
    AND (s.contact_channels = 'All' OR ch.channel_name = ANY (string_to_array(s.contact_channels, ' | ')))
)
SELECT n.days, round(r.fte / n.days, 1) AS required_fte, round(sc.minutes / 15 / n.days, 1) AS scheduled_fte,
       round(av.minutes / 15 / n.days, 1) AS available_fte, round(av.minutes / 15 / n.days - r.fte / n.days, 1) AS gap
FROM required r, scheduled sc, available av, (SELECT count(*) AS days FROM days) n;
