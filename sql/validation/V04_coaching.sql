-- Validation queries: Agent & team coaching
-- The page defaults to Phone agents and one month (October 2026). Agents count under their current team.
-- In the agent table the page shows quality over 3 months; use query 4.5 for that.
-- Run one query at a time (select it, then run). Every query only reads data.
-- Filters: 'All' means no filter. Separate several values with ' | ', for example 'Phone | Chat'.
-- Names must match exactly, including capitals. See README.md in this folder.

-- ====================================================================================================
-- 4.1  The six KPI tiles
-- On the page: tiles at the top
-- Expected with the values below (checked Nov 24, 2026): adherence 91.2, AHT 463 s (7m 43s), FCR 77.6, transfer 9.0, CSAT 85.6, quality 85.2
-- ====================================================================================================
WITH settings AS (
  SELECT   -- <<< CHANGE THESE VALUES >>>
    DATE '2026-10-01'              AS start_date,              -- first day
    DATE '2026-10-31'              AS end_date,                -- last day (included)
    'Phone'::text                  AS agent_group,             -- Phone, Chat, Email
    'All'::text                    AS site,                    -- Central Campus, Lakeside Center, Partner Site (Outsourced)
    'All'::text                    AS team,                    -- e.g. Phone - Team Beacon
    'All'::text                    AS agent                    -- e.g. Aaron Roberts
),
people AS (
  SELECT a.agent_id, a.display_name AS agent, t.team_name AS team, si.site_name AS site
  FROM cc.dim_agent a JOIN cc.dim_team t ON t.team_id = a.team_id JOIN cc.dim_site si ON si.site_id = t.site_id
  JOIN cc.dim_channel ch ON ch.channel_id = a.primary_channel_id CROSS JOIN settings s
  WHERE true
    AND (s.agent_group = 'All' OR ch.channel_name = ANY (string_to_array(s.agent_group, ' | ')))
    AND (s.site = 'All' OR si.site_name = ANY (string_to_array(s.site, ' | ')))
    AND (s.team = 'All' OR t.team_name = ANY (string_to_array(s.team, ' | ')))
    AND (s.agent = 'All' OR a.display_name = ANY (string_to_array(s.agent, ' | ')))
),
ct AS (
  SELECT c.agent_id, count(*) AS answered, sum(c.handle_sec) AS handle, count(*) FILTER (WHERE c.first_contact_resolved) AS resolved,
         count(*) FILTER (WHERE c.transferred) AS transferred
  FROM cc.contact c JOIN cc.dim_date d ON d.date_key = c.date_key CROSS JOIN settings s WHERE d.full_date BETWEEN s.start_date AND s.end_date AND c.answered GROUP BY 1
),
sv AS (
  SELECT v.agent_id, count(*) AS surveys, count(*) FILTER (WHERE v.csat >= 4) AS satisfied
  FROM cc.survey_response v JOIN cc.dim_date d ON d.date_key = v.date_key CROSS JOIN settings s WHERE d.full_date BETWEEN s.start_date AND s.end_date GROUP BY 1
),
wk AS (   -- days worked only
  SELECT ad.agent_id, count(*) AS days, sum(ad.in_adherence_min) AS adh, sum(ad.scheduled_min) AS sched, sum(ad.quality_score) AS q,
         count(ad.quality_score) AS qn, sum(ad.shrinkage_coaching_min) AS coaching_min
  FROM cc.agent_daily ad JOIN cc.dim_date d ON d.date_key = ad.date_key CROSS JOIN settings s
  WHERE d.full_date BETWEEN s.start_date AND s.end_date AND NOT ad.is_pto AND NOT ad.is_absent AND ad.scheduled_min > 0 GROUP BY 1
)
SELECT sum(ct.answered) AS answered_contacts, round(100.0 * sum(adh) / nullif(sum(sched), 0), 1) AS adherence_pct,
       round(sum(handle)::numeric / nullif(sum(ct.answered), 0), 0) AS aht_sec, round(100.0 * sum(resolved) / nullif(sum(ct.answered), 0), 1) AS fcr_pct,
       round(100.0 * sum(transferred) / nullif(sum(ct.answered), 0), 1) AS transfer_pct,
       round(100.0 * sum(satisfied) / nullif(sum(surveys), 0), 1) AS csat_pct, sum(surveys) AS surveys,
       round(sum(q)::numeric / nullif(sum(qn), 0), 1) AS quality_score, sum(days) AS agent_days_worked,
       round(sum(coaching_min) / nullif(sum(days), 0), 1) AS coaching_min_per_day
FROM people p LEFT JOIN ct USING (agent_id) LEFT JOIN sv USING (agent_id) LEFT JOIN wk USING (agent_id)
;


-- ====================================================================================================
-- 4.2  Teams
-- On the page: the team table
-- Expected with the values below (checked Nov 24, 2026): Phone - Team Atlas: 7,766 contacts, 90.2, 470 s (7m 50s), 78.0, 8.8, 87.4, 84.9, coaching 4.3 min
-- ====================================================================================================
WITH settings AS (
  SELECT   -- <<< CHANGE THESE VALUES >>>
    DATE '2026-10-01'              AS start_date,              -- first day
    DATE '2026-10-31'              AS end_date,                -- last day (included)
    'Phone'::text                  AS agent_group,             -- Phone, Chat, Email
    'All'::text                    AS site,                    -- Central Campus, Lakeside Center, Partner Site (Outsourced)
    'All'::text                    AS team,                    -- e.g. Phone - Team Beacon
    'All'::text                    AS agent                    -- e.g. Aaron Roberts
),
people AS (
  SELECT a.agent_id, a.display_name AS agent, t.team_name AS team, si.site_name AS site
  FROM cc.dim_agent a JOIN cc.dim_team t ON t.team_id = a.team_id JOIN cc.dim_site si ON si.site_id = t.site_id
  JOIN cc.dim_channel ch ON ch.channel_id = a.primary_channel_id CROSS JOIN settings s
  WHERE true
    AND (s.agent_group = 'All' OR ch.channel_name = ANY (string_to_array(s.agent_group, ' | ')))
    AND (s.site = 'All' OR si.site_name = ANY (string_to_array(s.site, ' | ')))
    AND (s.team = 'All' OR t.team_name = ANY (string_to_array(s.team, ' | ')))
    AND (s.agent = 'All' OR a.display_name = ANY (string_to_array(s.agent, ' | ')))
),
ct AS (
  SELECT c.agent_id, count(*) AS answered, sum(c.handle_sec) AS handle, count(*) FILTER (WHERE c.first_contact_resolved) AS resolved,
         count(*) FILTER (WHERE c.transferred) AS transferred
  FROM cc.contact c JOIN cc.dim_date d ON d.date_key = c.date_key CROSS JOIN settings s WHERE d.full_date BETWEEN s.start_date AND s.end_date AND c.answered GROUP BY 1
),
sv AS (
  SELECT v.agent_id, count(*) AS surveys, count(*) FILTER (WHERE v.csat >= 4) AS satisfied
  FROM cc.survey_response v JOIN cc.dim_date d ON d.date_key = v.date_key CROSS JOIN settings s WHERE d.full_date BETWEEN s.start_date AND s.end_date GROUP BY 1
),
wk AS (   -- days worked only
  SELECT ad.agent_id, count(*) AS days, sum(ad.in_adherence_min) AS adh, sum(ad.scheduled_min) AS sched, sum(ad.quality_score) AS q,
         count(ad.quality_score) AS qn, sum(ad.shrinkage_coaching_min) AS coaching_min
  FROM cc.agent_daily ad JOIN cc.dim_date d ON d.date_key = ad.date_key CROSS JOIN settings s
  WHERE d.full_date BETWEEN s.start_date AND s.end_date AND NOT ad.is_pto AND NOT ad.is_absent AND ad.scheduled_min > 0 GROUP BY 1
)
SELECT p.team, p.site, sum(ct.answered) AS answered_contacts, round(100.0 * sum(adh) / nullif(sum(sched), 0), 1) AS adherence_pct,
       round(sum(handle)::numeric / nullif(sum(ct.answered), 0), 0) AS aht_sec, round(100.0 * sum(resolved) / nullif(sum(ct.answered), 0), 1) AS fcr_pct,
       round(100.0 * sum(transferred) / nullif(sum(ct.answered), 0), 1) AS transfer_pct,
       round(100.0 * sum(satisfied) / nullif(sum(surveys), 0), 1) AS csat_pct, sum(surveys) AS surveys,
       round(sum(q)::numeric / nullif(sum(qn), 0), 1) AS quality_score, sum(days) AS agent_days_worked,
       round(sum(coaching_min) / nullif(sum(days), 0), 1) AS coaching_min_per_day
FROM people p LEFT JOIN ct USING (agent_id) LEFT JOIN sv USING (agent_id) LEFT JOIN wk USING (agent_id)
GROUP BY p.team, p.site
HAVING sum(ct.answered) > 0
ORDER BY p.team;


-- ====================================================================================================
-- 4.3  Agents
-- On the page: the all-agents table
-- Expected with the values below (checked Nov 24, 2026): Aaron Roberts: 908 contacts, 92.4, 517 s (8m 37s), 69.6, 11.0, 68.4, 22 days
-- ====================================================================================================
WITH settings AS (
  SELECT   -- <<< CHANGE THESE VALUES >>>
    DATE '2026-10-01'              AS start_date,              -- first day
    DATE '2026-10-31'              AS end_date,                -- last day (included)
    'Phone'::text                  AS agent_group,             -- Phone, Chat, Email
    'All'::text                    AS site,                    -- Central Campus, Lakeside Center, Partner Site (Outsourced)
    'All'::text                    AS team,                    -- e.g. Phone - Team Beacon
    'All'::text                    AS agent                    -- e.g. Aaron Roberts
),
people AS (
  SELECT a.agent_id, a.display_name AS agent, t.team_name AS team, si.site_name AS site
  FROM cc.dim_agent a JOIN cc.dim_team t ON t.team_id = a.team_id JOIN cc.dim_site si ON si.site_id = t.site_id
  JOIN cc.dim_channel ch ON ch.channel_id = a.primary_channel_id CROSS JOIN settings s
  WHERE true
    AND (s.agent_group = 'All' OR ch.channel_name = ANY (string_to_array(s.agent_group, ' | ')))
    AND (s.site = 'All' OR si.site_name = ANY (string_to_array(s.site, ' | ')))
    AND (s.team = 'All' OR t.team_name = ANY (string_to_array(s.team, ' | ')))
    AND (s.agent = 'All' OR a.display_name = ANY (string_to_array(s.agent, ' | ')))
),
ct AS (
  SELECT c.agent_id, count(*) AS answered, sum(c.handle_sec) AS handle, count(*) FILTER (WHERE c.first_contact_resolved) AS resolved,
         count(*) FILTER (WHERE c.transferred) AS transferred
  FROM cc.contact c JOIN cc.dim_date d ON d.date_key = c.date_key CROSS JOIN settings s WHERE d.full_date BETWEEN s.start_date AND s.end_date AND c.answered GROUP BY 1
),
sv AS (
  SELECT v.agent_id, count(*) AS surveys, count(*) FILTER (WHERE v.csat >= 4) AS satisfied
  FROM cc.survey_response v JOIN cc.dim_date d ON d.date_key = v.date_key CROSS JOIN settings s WHERE d.full_date BETWEEN s.start_date AND s.end_date GROUP BY 1
),
wk AS (   -- days worked only
  SELECT ad.agent_id, count(*) AS days, sum(ad.in_adherence_min) AS adh, sum(ad.scheduled_min) AS sched, sum(ad.quality_score) AS q,
         count(ad.quality_score) AS qn, sum(ad.shrinkage_coaching_min) AS coaching_min
  FROM cc.agent_daily ad JOIN cc.dim_date d ON d.date_key = ad.date_key CROSS JOIN settings s
  WHERE d.full_date BETWEEN s.start_date AND s.end_date AND NOT ad.is_pto AND NOT ad.is_absent AND ad.scheduled_min > 0 GROUP BY 1
)
SELECT p.agent, p.team, sum(ct.answered) AS answered_contacts, round(100.0 * sum(adh) / nullif(sum(sched), 0), 1) AS adherence_pct,
       round(sum(handle)::numeric / nullif(sum(ct.answered), 0), 0) AS aht_sec, round(100.0 * sum(resolved) / nullif(sum(ct.answered), 0), 1) AS fcr_pct,
       round(100.0 * sum(transferred) / nullif(sum(ct.answered), 0), 1) AS transfer_pct,
       round(100.0 * sum(satisfied) / nullif(sum(surveys), 0), 1) AS csat_pct, sum(surveys) AS surveys,
       round(sum(q)::numeric / nullif(sum(qn), 0), 1) AS quality_score, sum(days) AS agent_days_worked,
       round(sum(coaching_min) / nullif(sum(days), 0), 1) AS coaching_min_per_day
FROM people p LEFT JOIN ct USING (agent_id) LEFT JOIN sv USING (agent_id) LEFT JOIN wk USING (agent_id)
GROUP BY p.agent_id, p.agent, p.team
HAVING sum(days) > 0 OR sum(ct.answered) >= 20
ORDER BY p.agent;


-- ====================================================================================================
-- 4.4  An agent against the group for the same work
-- On the page: the Agent, Group and Gap columns of the coaching focus table
-- Expected with the values below (checked Nov 24, 2026): Aaron Roberts: AHT 517 against 465 s (+52 s), FCR 69.6 against 77.5
-- ====================================================================================================
WITH settings AS (
  SELECT   -- <<< CHANGE THESE VALUES >>>
    DATE '2026-10-01'              AS start_date,              -- first day
    DATE '2026-10-31'              AS end_date,                -- last day (included)
    'Aaron Roberts'::text          AS agent,                   -- one agent, as written on the page; All lists everyone
    'Phone'::text                  AS agent_group              -- Phone, Chat, Email
),
ct AS (   -- all answered contacts of the group. Use full months: the page works month by month
  SELECT a.agent_id, a.display_name, d.year_month, c.queue_id, c.reason_id, c.handle_sec,
         coalesce(c.first_contact_resolved, false)::int AS resolved, c.transferred::int AS transferred
  FROM cc.contact c JOIN cc.dim_date d ON d.date_key = c.date_key JOIN cc.dim_agent a ON a.agent_id = c.agent_id JOIN cc.dim_channel ch ON ch.channel_id = a.primary_channel_id CROSS JOIN settings s
  WHERE d.full_date BETWEEN s.start_date AND s.end_date AND c.answered
    AND (s.agent_group = 'All' OR ch.channel_name = ANY (string_to_array(s.agent_group, ' | ')))
),
peer AS (   -- the group's average for the same month, queue and reason
  SELECT year_month, queue_id, reason_id, avg(handle_sec) AS handle_sec, avg(resolved) AS resolved, avg(transferred) AS transferred FROM ct GROUP BY 1, 2, 3
)
SELECT ct.display_name AS agent, count(*) AS contacts,
       round(avg(ct.handle_sec), 0) AS aht_agent_sec, round(avg(p.handle_sec), 0) AS aht_group_sec, round(avg(ct.handle_sec), 0) - round(avg(p.handle_sec), 0) AS aht_gap_sec,
       round(100 * avg(ct.resolved), 1) AS fcr_agent_pct, round(100 * avg(p.resolved), 1) AS fcr_group_pct,
       round(100 * avg(ct.transferred), 1) AS transfer_agent_pct, round(100 * avg(p.transferred), 1) AS transfer_group_pct
FROM ct JOIN peer p USING (year_month, queue_id, reason_id) CROSS JOIN settings s
WHERE true
    AND (s.agent = 'All' OR ct.display_name = ANY (string_to_array(s.agent, ' | ')))
GROUP BY ct.agent_id, ct.display_name
ORDER BY 1;


-- ====================================================================================================
-- 4.5  Quality score over 3 months
-- On the page: the Quality (3 mo) column
-- Expected with the values below (checked Nov 24, 2026): Aaron Roberts 73.7, Diego Edwards 91.5
-- ====================================================================================================
WITH settings AS (
  SELECT   -- <<< CHANGE THESE VALUES >>>
    DATE '2026-08-01'              AS start_date,              -- first day (3 months)
    DATE '2026-10-31'              AS end_date,                -- last day (included)
    'Phone'::text                  AS agent_group,             -- Phone, Chat, Email
    'All'::text                    AS site,                    -- Central Campus, Lakeside Center, Partner Site (Outsourced)
    'All'::text                    AS team,                    -- e.g. Phone - Team Beacon
    'All'::text                    AS agent                    -- e.g. Aaron Roberts
)
SELECT a.display_name AS agent, t.team_name, count(ad.quality_score) AS evaluations, round(avg(ad.quality_score), 1) AS quality_score
FROM cc.agent_daily ad
JOIN cc.dim_date d ON d.date_key = ad.date_key
JOIN cc.dim_agent a ON a.agent_id = ad.agent_id
JOIN cc.dim_team t ON t.team_id = a.team_id
JOIN cc.dim_site si ON si.site_id = t.site_id
JOIN cc.dim_channel ch ON ch.channel_id = a.primary_channel_id
CROSS JOIN settings s
WHERE d.full_date BETWEEN s.start_date AND s.end_date AND NOT ad.is_pto AND NOT ad.is_absent AND ad.scheduled_min > 0
    AND (s.agent_group = 'All' OR ch.channel_name = ANY (string_to_array(s.agent_group, ' | ')))
    AND (s.site = 'All' OR si.site_name = ANY (string_to_array(s.site, ' | ')))
    AND (s.team = 'All' OR t.team_name = ANY (string_to_array(s.team, ' | ')))
    AND (s.agent = 'All' OR a.display_name = ANY (string_to_array(s.agent, ' | ')))
GROUP BY a.agent_id, a.display_name, t.team_name
HAVING count(ad.quality_score) > 0
ORDER BY 1;
