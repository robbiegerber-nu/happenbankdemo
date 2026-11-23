-- Executive Scorecard export: one JSON document with monthly KPI values, sample sizes,
-- driver breakdowns and business events. Run by export_dashboards.ps1 (psql -At -f).
--
-- Golden rule: every ratio is calculated from its monthly totals, never by averaging
-- daily or interval percentages. Values are unrounded; the page rounds for display.
--
-- Output rows: k = KPI id, g = driver dimension (NULL for the KPI total), name = driver
-- member, m = 'YYYY-MM', v = value, n = sample size (the KPI's denominator).

SET work_mem = '256MB';

WITH
iv AS (   -- interval_volume by month and queue (service level, ASA, abandon, volume, staffing)
  SELECT to_char(d.full_date, 'YYYY-MM') AS m, q.queue_name, q.channel_id,
         sum(v.answered_within_sl) AS within_sl,
         sum(v.answered + v.abandoned - v.short_abandoned) AS sl_eligible,
         sum(v.offered) AS offered, sum(v.answered) AS answered, sum(v.abandoned) AS abandoned,
         sum(coalesce(v.asa_sec, 0) * v.answered) AS wait_sec,
         sum(coalesce(v.actual_aht_sec, 0) * v.answered) AS handle_sec,
         sum(v.scheduled_fte) AS sched_fte, sum(v.required_fte) AS req_fte
  FROM cc.interval_volume v
  JOIN cc.dim_date d USING (date_key)
  JOIN cc.dim_queue q USING (queue_id)
  GROUP BY 1, 2, 3
),
sl_map(k, channels) AS (VALUES
  ('sl_phone', ARRAY[1]::int[]), ('sl_chat', ARRAY[2]), ('sl_email', ARRAY[3, 5]), ('sl_callback', ARRAY[4])
),
c AS (    -- contacts by month and reason group (FCR)
  SELECT to_char(d.full_date, 'YYYY-MM') AS m, r.reason_group,
         count(*) FILTER (WHERE c.answered) AS answered,
         count(*) FILTER (WHERE c.answered AND c.first_contact_resolved) AS resolved
  FROM cc.contact c
  JOIN cc.dim_date d USING (date_key)
  JOIN cc.dim_contact_reason r USING (reason_id)
  GROUP BY 1, 2
),
s AS (    -- surveys by month and reason group of the surveyed contact (CSAT, NPS)
  SELECT to_char(d.full_date, 'YYYY-MM') AS m, r.reason_group,
         count(*) AS surveys,
         count(*) FILTER (WHERE s.csat >= 4) AS satisfied,
         count(*) FILTER (WHERE s.nps >= 9) AS promoters,
         count(*) FILTER (WHERE s.nps <= 6) AS detractors
  FROM cc.survey_response s
  JOIN cc.dim_date d ON d.date_key = s.date_key
  JOIN cc.contact c ON c.contact_id = s.contact_id
  JOIN cc.dim_contact_reason r ON r.reason_id = c.reason_id
  GROUP BY 1, 2
),
cp AS (   -- complaints by month and category
  SELECT to_char(d.full_date, 'YYYY-MM') AS m, cp.category, count(*) AS complaints
  FROM cc.complaint cp JOIN cc.dim_date d USING (date_key)
  GROUP BY 1, 2
),
a AS (    -- agent-days by month and site (adherence, occupancy); PTO and absence excluded
  SELECT to_char(full_date, 'YYYY-MM') AS m, site_name,
         count(*) AS agent_days,
         sum(in_adherence_min) AS in_adh, sum(scheduled_min) AS sched,
         sum(occupancy_pct * available_min) AS occ_w, sum(available_min) AS avail
  FROM cc.v_agent_adherence
  WHERE NOT is_pto AND NOT is_absent AND scheduled_min > 0
  GROUP BY 1, 2
),
ivr AS (
  SELECT to_char(d.full_date, 'YYYY-MM') AS m, count(*) AS sessions, count(*) FILTER (WHERE i.contained) AS contained
  FROM cc.ivr_session i JOIN cc.dim_date d USING (date_key)
  GROUP BY 1
),
rows AS (
  -- Service level by channel group, with queue drivers
  SELECT sm.k, NULL::text AS g, NULL::text AS name, iv.m,
         sum(within_sl)::numeric / nullif(sum(sl_eligible), 0) * 100 AS v, sum(sl_eligible) AS n
  FROM iv JOIN sl_map sm ON iv.channel_id = ANY (sm.channels) GROUP BY sm.k, iv.m
  UNION ALL
  SELECT sm.k, 'Queue', iv.queue_name, iv.m,
         sum(within_sl)::numeric / nullif(sum(sl_eligible), 0) * 100, sum(sl_eligible)
  FROM iv JOIN sl_map sm ON iv.channel_id = ANY (sm.channels) GROUP BY sm.k, iv.queue_name, iv.m
  -- ASA, phone (seconds)
  UNION ALL
  SELECT 'asa_phone', NULL, NULL, m, sum(wait_sec) / nullif(sum(answered), 0), sum(answered)
  FROM iv WHERE channel_id = 1 GROUP BY m
  UNION ALL
  SELECT 'asa_phone', 'Queue', queue_name, m, sum(wait_sec) / nullif(sum(answered), 0), sum(answered)
  FROM iv WHERE channel_id = 1 GROUP BY queue_name, m
  -- Abandon rate, phone and chat
  UNION ALL
  SELECT 'abandon', NULL, NULL, m, sum(abandoned)::numeric / nullif(sum(offered), 0) * 100, sum(offered)
  FROM iv WHERE channel_id IN (1, 2) GROUP BY m
  UNION ALL
  SELECT 'abandon', 'Queue', queue_name, m, sum(abandoned)::numeric / nullif(sum(offered), 0) * 100, sum(offered)
  FROM iv WHERE channel_id IN (1, 2) GROUP BY queue_name, m
  -- AHT, phone (seconds)
  UNION ALL
  SELECT 'aht_phone', NULL, NULL, m, sum(handle_sec) / nullif(sum(answered), 0), sum(answered)
  FROM iv WHERE channel_id = 1 GROUP BY m
  -- Contacts offered, all channels
  UNION ALL
  SELECT 'volume', NULL, NULL, m, sum(offered), sum(offered) FROM iv GROUP BY m
  -- Digital share: chat, email and secure message as % of contacts offered
  UNION ALL
  SELECT 'digital_share', NULL, NULL, m,
         sum(offered) FILTER (WHERE channel_id IN (2, 3, 5))::numeric / nullif(sum(offered), 0) * 100, sum(offered)
  FROM iv GROUP BY m
  -- Staffing vs required: (scheduled − required FTE) ÷ required, phone and chat (real-time channels)
  UNION ALL
  SELECT 'staffing', NULL, NULL, m, (sum(sched_fte) - sum(req_fte)) / nullif(sum(req_fte), 0) * 100, sum(offered)
  FROM iv WHERE channel_id IN (1, 2) GROUP BY m
  -- First contact resolution, with reason-group drivers
  UNION ALL
  SELECT 'fcr', NULL, NULL, m, sum(resolved)::numeric / nullif(sum(answered), 0) * 100, sum(answered) FROM c GROUP BY m
  UNION ALL
  SELECT 'fcr', 'Contact reason', reason_group, m, resolved::numeric / nullif(answered, 0) * 100, answered FROM c
  -- CSAT and NPS, with reason-group drivers
  UNION ALL
  SELECT 'csat', NULL, NULL, m, sum(satisfied)::numeric / nullif(sum(surveys), 0) * 100, sum(surveys) FROM s GROUP BY m
  UNION ALL
  SELECT 'csat', 'Contact reason', reason_group, m, satisfied::numeric / nullif(surveys, 0) * 100, surveys FROM s
  UNION ALL
  SELECT 'nps', NULL, NULL, m, (sum(promoters) - sum(detractors))::numeric / nullif(sum(surveys), 0) * 100, sum(surveys) FROM s GROUP BY m
  UNION ALL
  SELECT 'nps', 'Contact reason', reason_group, m, (promoters - detractors)::numeric / nullif(surveys, 0) * 100, surveys FROM s
  -- Complaints per 1,000 contacts offered, with category counts as drivers
  UNION ALL
  SELECT 'complaints', NULL, NULL, cp.m, sum(cp.complaints)::numeric / nullif(max(vol.offered), 0) * 1000, max(vol.offered)
  FROM cp JOIN (SELECT m, sum(offered) AS offered FROM iv GROUP BY m) vol USING (m) GROUP BY cp.m
  UNION ALL
  SELECT 'complaints', 'Category', cp.category, cp.m, cp.complaints::numeric / nullif(vol.offered, 0) * 1000, vol.offered
  FROM cp JOIN (SELECT m, sum(offered) AS offered FROM iv GROUP BY m) vol USING (m)
  -- Schedule adherence and occupancy, with site drivers
  UNION ALL
  SELECT 'adherence', NULL, NULL, m, sum(in_adh) / nullif(sum(sched), 0) * 100, sum(agent_days) FROM a GROUP BY m
  UNION ALL
  SELECT 'adherence', 'Site', site_name, m, in_adh / nullif(sched, 0) * 100, agent_days FROM a
  UNION ALL
  SELECT 'occupancy', NULL, NULL, m, sum(occ_w) / nullif(sum(avail), 0), sum(agent_days) FROM a GROUP BY m
  UNION ALL
  SELECT 'occupancy', 'Site', site_name, m, occ_w / nullif(avail, 0), agent_days FROM a
  -- IVR containment
  UNION ALL
  SELECT 'ivr_containment', NULL, NULL, m, contained::numeric / nullif(sessions, 0) * 100, sessions FROM ivr
),
staff_wk AS (    -- weekly (Sunday-start) staffing vs required, phone and chat: finds the summer 2025 staffing gap
  SELECT d.full_date - extract(dow FROM d.full_date)::int AS wk,
         (sum(v.scheduled_fte) - sum(v.required_fte)) / nullif(sum(v.required_fte), 0) AS gap
  FROM cc.interval_volume v JOIN cc.dim_date d USING (date_key) JOIN cc.dim_queue q USING (queue_id)
  WHERE q.channel_id IN (1, 2) AND d.full_date BETWEEN '2025-03-01' AND '2025-12-31'
  GROUP BY 1
),
staff_run AS (   -- the longest unbroken run of understaffed weeks (gaps-and-islands)
  SELECT min(wk) AS start_date, max(wk) + 6 AS end_date
  FROM (SELECT wk, wk - 7 * (row_number() OVER (ORDER BY wk))::int AS island FROM staff_wk WHERE gap < 0) x
  GROUP BY island ORDER BY count(*) DESC LIMIT 1
),
events AS (
  SELECT launch_date AS start_date, launch_date AS end_date, launch_name AS name, launch_type AS kind,
         'One-day' AS span,
         launch_type || ' launched ' || to_char(launch_date, 'Mon FMDD, YYYY') AS description
  FROM cc.product_launch
  UNION ALL
  SELECT DATE '2026-04-07', DATE '2026-04-08', 'Online banking outage', 'Outage', 'Period',
         'Two-day online banking outage drove a spike in digital access contacts'
  UNION ALL
  SELECT start_date, end_date, 'Summer 2025 staffing gap', 'Staffing', 'Period',
         'Hiring freeze left phone and chat scheduled below required staff every week'
  FROM staff_run
)
SELECT json_build_object(
  'generated_at', to_char(now() AT TIME ZONE 'America/Chicago', 'YYYY-MM-DD"T"HH24:MI:SS'),
  'timezone', 'America/Chicago',
  'data_through', (SELECT max(d.full_date) FROM cc.interval_volume v JOIN cc.dim_date d USING (date_key)),
  'rows', (SELECT json_agg(json_build_object('k', k, 'g', g, 'name', name, 'm', m, 'v', round(v, 4), 'n', n)
                           ORDER BY k, g NULLS FIRST, name, m) FROM rows WHERE v IS NOT NULL),
  'events', (SELECT json_agg(json_build_object('start', start_date, 'end', end_date, 'name', name, 'kind', kind,
                                               'span', span, 'description', description) ORDER BY start_date) FROM events)
);
