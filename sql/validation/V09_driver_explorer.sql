-- Validation queries: Performance driver explorer
-- The page defaults to phone service level, October 2026 compared with September 2026.
-- Channel setting: the page pairs channels: Phone for service level, ASA and AHT; Phone | Chat for abandon rate; Email | Secure Message for email; All for FCR, Digital share, Volume.
-- Run one query at a time (select it, then run). Every query only reads data.
-- Filters: 'All' means no filter. Separate several values with ' | ', for example 'Phone | Chat'.
-- Names must match exactly, including capitals. See README.md in this folder.

-- ====================================================================================================
-- 9.1  One metric, this period against the comparison
-- On the page: the headline figure
-- Expected with the values below (checked Nov 24, 2026): phone service level 81.9 now, 78.9 before, +3.02; n 78,904 now
-- ====================================================================================================
WITH settings AS (
  SELECT   -- <<< CHANGE THESE VALUES >>>
    DATE '2026-10-01'              AS start_date,              -- first day
    DATE '2026-10-31'              AS end_date,                -- last day (included)
    DATE '2026-09-01'              AS compare_start,           -- first day of the comparison period
    DATE '2026-09-30'              AS compare_end,             -- last day of it
    'Service level'::text          AS metric,                  -- Service level, ASA, Abandon rate, AHT, FCR, Digital share, Volume
    'Phone'::text                  AS channel,                 -- Phone, Chat, Email, Callback, Secure Message (see the note at the top)
    'All'::text                    AS queue,                   -- e.g. Phone - Fraud & Disputes
    'All'::text                    AS reason_group,            -- Account Servicing, Card, Fraud/Dispute, Digital Access, Lending, Product Inquiry, Complaint
    'All'::text                    AS reason,                  -- e.g. Card Activation
    'All'::text                    AS persona,                 -- e.g. Credit Builder, Retiree Traditionalist
    'All'::text                    AS segment,                 -- Mass, Mass Affluent, Private, Small Business
    'All'::text                    AS age_band                 -- as on the page
),
x AS (
  SELECT 'all' AS grp, d.full_date BETWEEN s.start_date AND s.end_date AS is_now,
         CASE s.metric WHEN 'Service level' THEN c.met_service_level::int WHEN 'ASA' THEN CASE WHEN c.answered THEN c.queue_wait_sec ELSE 0 END
           WHEN 'Abandon rate' THEN c.abandoned::int WHEN 'AHT' THEN CASE WHEN c.answered THEN c.handle_sec ELSE 0 END
           WHEN 'FCR' THEN (c.answered AND coalesce(c.first_contact_resolved, false))::int WHEN 'Digital share' THEN (c.channel_id IN (2, 3, 5))::int ELSE 1 END AS x,
         CASE s.metric WHEN 'Service level' THEN (c.answered OR (c.abandoned AND NOT c.short_abandon))::int
           WHEN 'ASA' THEN c.answered::int WHEN 'AHT' THEN c.answered::int WHEN 'FCR' THEN c.answered::int ELSE 1 END AS n
  FROM cc.contact c JOIN cc.dim_date d ON d.date_key = c.date_key
  JOIN cc.dim_queue q ON q.queue_id = c.queue_id
  JOIN cc.dim_channel ch ON ch.channel_id = c.channel_id
  JOIN cc.dim_contact_reason r ON r.reason_id = c.reason_id
  LEFT JOIN cc.customer cu ON cu.customer_id = c.customer_id
  LEFT JOIN cc.dim_persona p ON p.persona_id = cu.persona_id
  LEFT JOIN cc.dim_agent a ON a.agent_id = c.agent_id
  LEFT JOIN cc.dim_team t ON t.team_id = a.team_id
  LEFT JOIN cc.dim_site si ON si.site_id = t.site_id
  CROSS JOIN settings s
  WHERE (d.full_date BETWEEN s.start_date AND s.end_date OR d.full_date BETWEEN s.compare_start AND s.compare_end)
    AND (s.channel = 'All' OR ch.channel_name = ANY (string_to_array(s.channel, ' | ')))
    AND (s.queue = 'All' OR q.queue_name = ANY (string_to_array(s.queue, ' | ')))
    AND (s.reason_group = 'All' OR r.reason_group = ANY (string_to_array(s.reason_group, ' | ')))
    AND (s.reason = 'All' OR r.reason = ANY (string_to_array(s.reason, ' | ')))
    AND (s.persona = 'All' OR p.persona_name = ANY (string_to_array(s.persona, ' | ')))
    AND (s.segment = 'All' OR cu.segment = ANY (string_to_array(s.segment, ' | ')))
    AND (s.age_band = 'All' OR cu.age_band = ANY (string_to_array(s.age_band, ' | ')))
)
SELECT s.metric, sum(x) FILTER (WHERE is_now) AS numerator_now, sum(n) FILTER (WHERE is_now) AS n_now, sum(n) FILTER (WHERE NOT is_now) AS n_before,
       CASE WHEN s.metric = 'Volume' THEN sum(x) FILTER (WHERE is_now) ELSE round(CASE WHEN s.metric IN ('ASA', 'AHT') THEN 1 ELSE 100 END * sum(x) FILTER (WHERE is_now)::numeric / nullif(sum(n) FILTER (WHERE is_now), 0), 1) END AS value_now,
       CASE WHEN s.metric = 'Volume' THEN sum(x) FILTER (WHERE NOT is_now) ELSE round(CASE WHEN s.metric IN ('ASA', 'AHT') THEN 1 ELSE 100 END * sum(x) FILTER (WHERE NOT is_now)::numeric / nullif(sum(n) FILTER (WHERE NOT is_now), 0), 1) END AS value_before,
       CASE WHEN s.metric = 'Volume' THEN sum(x) FILTER (WHERE is_now) - sum(x) FILTER (WHERE NOT is_now)
            ELSE round(CASE WHEN s.metric IN ('ASA', 'AHT') THEN 1 ELSE 100 END * (sum(x) FILTER (WHERE is_now)::numeric / nullif(sum(n) FILTER (WHERE is_now), 0) - sum(x) FILTER (WHERE NOT is_now)::numeric / nullif(sum(n) FILTER (WHERE NOT is_now), 0)), 2) END AS change
FROM x CROSS JOIN settings s
GROUP BY s.metric;


-- ====================================================================================================
-- 9.2  What drove the change: mix and rate by group
-- On the page: the breakdown table and the contribution chart
-- Expected with the values below (checked Nov 24, 2026): Phone - General Servicing: 82.2, 79.2, mix 0.00, rate +1.38, n 36,642; contributions add up to +3.02. Volume has no mix or rate: use 9.1 or 9.5
-- ====================================================================================================
WITH settings AS (
  SELECT   -- <<< CHANGE THESE VALUES >>>
    DATE '2026-10-01'              AS start_date,              -- first day
    DATE '2026-10-31'              AS end_date,                -- last day (included)
    DATE '2026-09-01'              AS compare_start,           -- first day of the comparison period
    DATE '2026-09-30'              AS compare_end,             -- last day of it
    'Service level'::text          AS metric,                  -- Service level, ASA, Abandon rate, AHT, FCR, Digital share, Volume
    'Queue'::text                  AS break_down_by,           -- Channel, Queue, Reason group, Reason, Persona, Segment, Age band, Site, Team, Agent
    'Phone'::text                  AS channel,                 -- Phone, Chat, Email, Callback, Secure Message (see the note at the top)
    'All'::text                    AS queue,                   -- e.g. Phone - Fraud & Disputes
    'All'::text                    AS reason_group,            -- Account Servicing, Card, Fraud/Dispute, Digital Access, Lending, Product Inquiry, Complaint
    'All'::text                    AS reason,                  -- e.g. Card Activation
    'All'::text                    AS persona,                 -- e.g. Credit Builder, Retiree Traditionalist
    'All'::text                    AS segment,                 -- Mass, Mass Affluent, Private, Small Business
    'All'::text                    AS age_band                 -- as on the page
),
x AS (
  SELECT coalesce(CASE s.break_down_by WHEN 'Channel' THEN ch.channel_name WHEN 'Queue' THEN q.queue_name WHEN 'Reason group' THEN r.reason_group WHEN 'Reason' THEN r.reason
         WHEN 'Persona' THEN p.persona_name WHEN 'Segment' THEN cu.segment WHEN 'Age band' THEN cu.age_band WHEN 'Month' THEN d.year_month
         WHEN 'Site' THEN si.site_name WHEN 'Team' THEN t.team_name WHEN 'Agent' THEN a.display_name || ' (' || a.employee_number || ')' END, 'Not identified') AS grp, d.full_date BETWEEN s.start_date AND s.end_date AS is_now,
         CASE s.metric WHEN 'Service level' THEN c.met_service_level::int WHEN 'ASA' THEN CASE WHEN c.answered THEN c.queue_wait_sec ELSE 0 END
           WHEN 'Abandon rate' THEN c.abandoned::int WHEN 'AHT' THEN CASE WHEN c.answered THEN c.handle_sec ELSE 0 END
           WHEN 'FCR' THEN (c.answered AND coalesce(c.first_contact_resolved, false))::int WHEN 'Digital share' THEN (c.channel_id IN (2, 3, 5))::int ELSE 1 END AS x,
         CASE s.metric WHEN 'Service level' THEN (c.answered OR (c.abandoned AND NOT c.short_abandon))::int
           WHEN 'ASA' THEN c.answered::int WHEN 'AHT' THEN c.answered::int WHEN 'FCR' THEN c.answered::int ELSE 1 END AS n
  FROM cc.contact c JOIN cc.dim_date d ON d.date_key = c.date_key
  JOIN cc.dim_queue q ON q.queue_id = c.queue_id
  JOIN cc.dim_channel ch ON ch.channel_id = c.channel_id
  JOIN cc.dim_contact_reason r ON r.reason_id = c.reason_id
  LEFT JOIN cc.customer cu ON cu.customer_id = c.customer_id
  LEFT JOIN cc.dim_persona p ON p.persona_id = cu.persona_id
  LEFT JOIN cc.dim_agent a ON a.agent_id = c.agent_id
  LEFT JOIN cc.dim_team t ON t.team_id = a.team_id
  LEFT JOIN cc.dim_site si ON si.site_id = t.site_id
  CROSS JOIN settings s
  WHERE (d.full_date BETWEEN s.start_date AND s.end_date OR d.full_date BETWEEN s.compare_start AND s.compare_end)
    AND (s.channel = 'All' OR ch.channel_name = ANY (string_to_array(s.channel, ' | ')))
    AND (s.queue = 'All' OR q.queue_name = ANY (string_to_array(s.queue, ' | ')))
    AND (s.reason_group = 'All' OR r.reason_group = ANY (string_to_array(s.reason_group, ' | ')))
    AND (s.reason = 'All' OR r.reason = ANY (string_to_array(s.reason, ' | ')))
    AND (s.persona = 'All' OR p.persona_name = ANY (string_to_array(s.persona, ' | ')))
    AND (s.segment = 'All' OR cu.segment = ANY (string_to_array(s.segment, ' | ')))
    AND (s.age_band = 'All' OR cu.age_band = ANY (string_to_array(s.age_band, ' | ')))
),
g AS (
  SELECT grp, coalesce(sum(x) FILTER (WHERE is_now), 0)::numeric AS x1, coalesce(sum(n) FILTER (WHERE is_now), 0)::numeric AS n1,
         coalesce(sum(x) FILTER (WHERE NOT is_now), 0)::numeric AS x0, coalesce(sum(n) FILTER (WHERE NOT is_now), 0)::numeric AS n0
  FROM x GROUP BY 1
),
y AS (   -- a group with nothing in one period borrows the other period's value, so all of its change is mix
  SELECT grp, n1, n0, n1 / sum(n1) OVER () AS s1, n0 / sum(n0) OVER () AS s0,
         coalesce(x1 / nullif(n1, 0), x0 / nullif(n0, 0)) AS r1, coalesce(x0 / nullif(n0, 0), x1 / nullif(n1, 0)) AS r0,
         sum(x1) OVER () / sum(n1) OVER () AS all1, sum(x0) OVER () / sum(n0) OVER () AS all0
  FROM g WHERE n1 + n0 > 0
)
SELECT grp, round(CASE WHEN s.metric IN ('ASA', 'AHT') THEN 1 ELSE 100 END * r1, 1) AS value_now, round(CASE WHEN s.metric IN ('ASA', 'AHT') THEN 1 ELSE 100 END * r0, 1) AS value_before, round(100 * s1, 1) AS share_now_pct, round(100 * s0, 1) AS share_before_pct,
       round(CASE WHEN s.metric IN ('ASA', 'AHT') THEN 1 ELSE 100 END * (s1 - s0) * ((r1 + r0) / 2 - (all1 + all0) / 2), 2) AS mix,
       round(CASE WHEN s.metric IN ('ASA', 'AHT') THEN 1 ELSE 100 END * (s1 + s0) / 2 * (r1 - r0), 2) AS rate,
       round(CASE WHEN s.metric IN ('ASA', 'AHT') THEN 1 ELSE 100 END * ((s1 - s0) * ((r1 + r0) / 2 - (all1 + all0) / 2) + (s1 + s0) / 2 * (r1 - r0)), 2) AS contribution, n1 AS n_now
FROM y CROSS JOIN settings s
ORDER BY abs((s1 - s0) * ((r1 + r0) / 2 - (all1 + all0) / 2) + (s1 + s0) / 2 * (r1 - r0)) DESC;


-- ====================================================================================================
-- 9.3  CSAT and NPS by group, this period against the comparison
-- On the page: the breakdown table when the metric is CSAT or NPS
-- Expected with the values below (checked Nov 24, 2026): the total row should match the Executive scorecard: CSAT 83.4 now and 84.3 before; NPS +36 now
-- ====================================================================================================
WITH settings AS (
  SELECT   -- <<< CHANGE THESE VALUES >>>
    DATE '2026-10-01'              AS start_date,              -- first day
    DATE '2026-10-31'              AS end_date,                -- last day (included)
    DATE '2026-09-01'              AS compare_start,           -- first day of the comparison period
    DATE '2026-09-30'              AS compare_end,             -- last day of it
    'Channel'::text                AS break_down_by,           -- Channel, Queue, Reason group, Reason, Persona, Segment, Age band, Site, Team, Agent
    'All'::text                    AS channel,                 -- Phone, Chat, Email, Callback, Secure Message
    'All'::text                    AS queue,                   -- e.g. Phone - Fraud & Disputes
    'All'::text                    AS reason_group,            -- Account Servicing, Card, Fraud/Dispute, Digital Access, Lending, Product Inquiry, Complaint
    'All'::text                    AS reason,                  -- e.g. Card Activation
    'All'::text                    AS persona,                 -- e.g. Credit Builder, Retiree Traditionalist
    'All'::text                    AS segment,                 -- Mass, Mass Affluent, Private, Small Business
    'All'::text                    AS age_band                 -- as on the page
),
x AS (   -- surveys, by the day they were answered
  SELECT coalesce(CASE s.break_down_by WHEN 'Channel' THEN ch.channel_name WHEN 'Queue' THEN q.queue_name WHEN 'Reason group' THEN r.reason_group WHEN 'Reason' THEN r.reason
         WHEN 'Persona' THEN p.persona_name WHEN 'Segment' THEN cu.segment WHEN 'Age band' THEN cu.age_band WHEN 'Month' THEN d.year_month
         WHEN 'Site' THEN si.site_name WHEN 'Team' THEN t.team_name WHEN 'Agent' THEN a.display_name || ' (' || a.employee_number || ')' END, 'Not identified') AS grp, d.full_date BETWEEN s.start_date AND s.end_date AS is_now, v.csat, v.nps
  FROM cc.survey_response v JOIN cc.dim_date d ON d.date_key = v.date_key JOIN cc.contact c ON c.contact_id = v.contact_id
  JOIN cc.dim_queue q ON q.queue_id = c.queue_id
  JOIN cc.dim_channel ch ON ch.channel_id = c.channel_id
  JOIN cc.dim_contact_reason r ON r.reason_id = c.reason_id
  LEFT JOIN cc.customer cu ON cu.customer_id = c.customer_id
  LEFT JOIN cc.dim_persona p ON p.persona_id = cu.persona_id
  LEFT JOIN cc.dim_agent a ON a.agent_id = v.agent_id
  LEFT JOIN cc.dim_team t ON t.team_id = a.team_id
  LEFT JOIN cc.dim_site si ON si.site_id = t.site_id
  CROSS JOIN settings s
  WHERE (d.full_date BETWEEN s.start_date AND s.end_date OR d.full_date BETWEEN s.compare_start AND s.compare_end)
    AND (s.channel = 'All' OR ch.channel_name = ANY (string_to_array(s.channel, ' | ')))
    AND (s.queue = 'All' OR q.queue_name = ANY (string_to_array(s.queue, ' | ')))
    AND (s.reason_group = 'All' OR r.reason_group = ANY (string_to_array(s.reason_group, ' | ')))
    AND (s.reason = 'All' OR r.reason = ANY (string_to_array(s.reason, ' | ')))
    AND (s.persona = 'All' OR p.persona_name = ANY (string_to_array(s.persona, ' | ')))
    AND (s.segment = 'All' OR cu.segment = ANY (string_to_array(s.segment, ' | ')))
    AND (s.age_band = 'All' OR cu.age_band = ANY (string_to_array(s.age_band, ' | ')))
)
SELECT coalesce(grp, '** Total **') AS grp, count(*) FILTER (WHERE is_now) AS surveys_now, count(*) FILTER (WHERE NOT is_now) AS surveys_before,
       round(100.0 * count(*) FILTER (WHERE is_now AND csat >= 4) / nullif(count(*) FILTER (WHERE is_now), 0), 1) AS csat_now_pct,
       round(100.0 * count(*) FILTER (WHERE NOT is_now AND csat >= 4) / nullif(count(*) FILTER (WHERE NOT is_now), 0), 1) AS csat_before_pct,
       round(100.0 * (count(*) FILTER (WHERE is_now AND nps >= 9) - count(*) FILTER (WHERE is_now AND nps <= 6)) / nullif(count(*) FILTER (WHERE is_now), 0), 0) AS nps_now,
       round(100.0 * (count(*) FILTER (WHERE NOT is_now AND nps >= 9) - count(*) FILTER (WHERE NOT is_now AND nps <= 6)) / nullif(count(*) FILTER (WHERE NOT is_now), 0), 0) AS nps_before
FROM x
GROUP BY ROLLUP (grp)
ORDER BY GROUPING(grp) DESC, 2 DESC;


-- ====================================================================================================
-- 9.4  Month by month
-- On the page: the monthly chart; set start_date to a year earlier for the full chart
-- Expected with the values below (checked Nov 24, 2026): phone service level: 2026-09 78.9, 2026-10 81.9
-- ====================================================================================================
WITH settings AS (
  SELECT   -- <<< CHANGE THESE VALUES >>>
    DATE '2025-10-01'              AS start_date,              -- first day
    DATE '2026-10-31'              AS end_date,                -- last day (included)
    'Service level'::text          AS metric,                  -- Service level, ASA, Abandon rate, AHT, FCR, Digital share, Volume
    'Phone'::text                  AS channel,                 -- Phone, Chat, Email, Callback, Secure Message (see the note at the top)
    'All'::text                    AS queue,                   -- e.g. Phone - Fraud & Disputes
    'All'::text                    AS reason_group,            -- Account Servicing, Card, Fraud/Dispute, Digital Access, Lending, Product Inquiry, Complaint
    'All'::text                    AS reason,                  -- e.g. Card Activation
    'All'::text                    AS persona,                 -- e.g. Credit Builder, Retiree Traditionalist
    'All'::text                    AS segment,                 -- Mass, Mass Affluent, Private, Small Business
    'All'::text                    AS age_band                 -- as on the page
),
x AS (
  SELECT d.year_month,
         CASE s.metric WHEN 'Service level' THEN c.met_service_level::int WHEN 'ASA' THEN CASE WHEN c.answered THEN c.queue_wait_sec ELSE 0 END
           WHEN 'Abandon rate' THEN c.abandoned::int WHEN 'AHT' THEN CASE WHEN c.answered THEN c.handle_sec ELSE 0 END
           WHEN 'FCR' THEN (c.answered AND coalesce(c.first_contact_resolved, false))::int WHEN 'Digital share' THEN (c.channel_id IN (2, 3, 5))::int ELSE 1 END AS x,
         CASE s.metric WHEN 'Service level' THEN (c.answered OR (c.abandoned AND NOT c.short_abandon))::int
           WHEN 'ASA' THEN c.answered::int WHEN 'AHT' THEN c.answered::int WHEN 'FCR' THEN c.answered::int ELSE 1 END AS n
  FROM cc.contact c JOIN cc.dim_date d ON d.date_key = c.date_key
  JOIN cc.dim_queue q ON q.queue_id = c.queue_id
  JOIN cc.dim_channel ch ON ch.channel_id = c.channel_id
  JOIN cc.dim_contact_reason r ON r.reason_id = c.reason_id
  LEFT JOIN cc.customer cu ON cu.customer_id = c.customer_id
  LEFT JOIN cc.dim_persona p ON p.persona_id = cu.persona_id
  LEFT JOIN cc.dim_agent a ON a.agent_id = c.agent_id
  LEFT JOIN cc.dim_team t ON t.team_id = a.team_id
  LEFT JOIN cc.dim_site si ON si.site_id = t.site_id
  CROSS JOIN settings s
  WHERE d.full_date BETWEEN s.start_date AND s.end_date
    AND (s.channel = 'All' OR ch.channel_name = ANY (string_to_array(s.channel, ' | ')))
    AND (s.queue = 'All' OR q.queue_name = ANY (string_to_array(s.queue, ' | ')))
    AND (s.reason_group = 'All' OR r.reason_group = ANY (string_to_array(s.reason_group, ' | ')))
    AND (s.reason = 'All' OR r.reason = ANY (string_to_array(s.reason, ' | ')))
    AND (s.persona = 'All' OR p.persona_name = ANY (string_to_array(s.persona, ' | ')))
    AND (s.segment = 'All' OR cu.segment = ANY (string_to_array(s.segment, ' | ')))
    AND (s.age_band = 'All' OR cu.age_band = ANY (string_to_array(s.age_band, ' | ')))
)
SELECT year_month, sum(n) AS n, CASE WHEN s.metric = 'Volume' THEN sum(x) ELSE round(CASE WHEN s.metric IN ('ASA', 'AHT') THEN 1 ELSE 100 END * sum(x)::numeric / nullif(sum(n), 0), 1) END AS value
FROM x CROSS JOIN settings s
GROUP BY year_month, s.metric
ORDER BY 1;
