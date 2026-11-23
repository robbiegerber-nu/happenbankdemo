-- Monthly cubes for the Performance Driver Explorer: additive KPI parts for every combination of dimensions that
-- actually occurs, so the page can filter and split by several at once and always compute ratios from totals.
--   dash.driver        queue x reason x team x persona x segment x age band
--   dash.driver_agent  queue x reason x agent (handled contacts only)
-- 0 means "none": no agent took the contact, or the customer was not identified.
-- Surveys count in the month they were answered, as on the scorecard.
\set ON_ERROR_STOP on
SET client_min_messages = warning;
SET work_mem = '512MB';

DROP TABLE IF EXISTS dash.driver, dash.driver_agent;

CREATE TEMP TABLE seg ON COMMIT PRESERVE ROWS AS SELECT row_number() OVER (ORDER BY segment)::int AS seg_id, segment FROM (SELECT DISTINCT segment FROM cc.customer) x;
CREATE TEMP TABLE age ON COMMIT PRESERVE ROWS AS SELECT row_number() OVER (ORDER BY min_age)::int AS age_id, age_band FROM (SELECT age_band, min(age) AS min_age FROM cc.customer GROUP BY 1) x;

CREATE TEMP VIEW parts AS
SELECT to_char(d.full_date, 'YYYY-MM') AS m, c.queue_id, c.reason_id, c.agent_id, c.customer_id,
       1 AS offered,
       (c.answered OR (c.abandoned AND NOT c.short_abandon))::int AS elig,
       c.met_service_level::int AS met, c.abandoned::int AS aband, c.answered::int AS ans,
       CASE WHEN c.answered THEN c.queue_wait_sec ELSE 0 END AS wait,
       CASE WHEN c.answered THEN c.handle_sec ELSE 0 END AS handle,
       (c.answered AND coalesce(c.first_contact_resolved, false))::int AS resolved,
       0 AS sv, 0 AS sat, 0 AS net
FROM cc.contact c JOIN cc.dim_date d USING (date_key)
UNION ALL
SELECT to_char(d.full_date, 'YYYY-MM'), c.queue_id, c.reason_id, sv.agent_id, sv.customer_id,
       0, 0, 0, 0, 0, 0, 0, 0, 1, (sv.csat >= 4)::int, CASE WHEN sv.nps >= 9 THEN 1 WHEN sv.nps <= 6 THEN -1 ELSE 0 END
FROM cc.survey_response sv JOIN cc.dim_date d ON d.date_key = sv.date_key JOIN cc.contact c ON c.contact_id = sv.contact_id;

CREATE UNLOGGED TABLE dash.driver AS
SELECT p.m, p.queue_id AS q, p.reason_id AS r, coalesce(a.team_id, 0) AS t, coalesce(cu.persona_id, 0) AS p,
       coalesce(s.seg_id, 0) AS s, coalesce(g.age_id, 0) AS a,
       sum(offered) AS offered, sum(elig) AS elig, sum(met) AS met, sum(aband) AS aband, sum(ans) AS ans, sum(wait) AS wait,
       sum(handle) AS handle, sum(resolved) AS resolved, sum(sv) AS sv, sum(sat) AS sat, sum(net) AS net
FROM parts p
LEFT JOIN cc.dim_agent a ON a.agent_id = p.agent_id
LEFT JOIN cc.customer cu ON cu.customer_id = p.customer_id
LEFT JOIN seg s ON s.segment = cu.segment
LEFT JOIN age g ON g.age_band = cu.age_band
GROUP BY 1, 2, 3, 4, 5, 6, 7;

CREATE UNLOGGED TABLE dash.driver_agent AS
SELECT p.m, p.queue_id AS q, p.reason_id AS r, p.agent_id AS g,
       sum(offered) AS offered, sum(elig) AS elig, sum(met) AS met, sum(aband) AS aband, sum(ans) AS ans, sum(wait) AS wait,
       sum(handle) AS handle, sum(resolved) AS resolved, sum(sv) AS sv, sum(sat) AS sat, sum(net) AS net
FROM parts p WHERE p.agent_id IS NOT NULL
GROUP BY 1, 2, 3, 4;

-- Names behind the codes
DROP TABLE IF EXISTS dash.driver_name;
CREATE TABLE dash.driver_name AS
SELECT 'q' AS k, queue_id AS id, queue_name AS name, channel_id AS parent, NULL::text AS extra FROM cc.dim_queue
UNION ALL SELECT 'c', channel_id, channel_name, NULL, NULL FROM cc.dim_channel
UNION ALL SELECT 'r', reason_id, reason, NULL, reason_group FROM cc.dim_contact_reason
UNION ALL SELECT 't', t.team_id, t.team_name, t.site_id, sup.display_name FROM cc.dim_team t LEFT JOIN cc.dim_agent sup ON sup.agent_id = t.supervisor_id
UNION ALL SELECT 'site', site_id, site_name, NULL, NULL FROM cc.dim_site
UNION ALL SELECT 'p', persona_id, persona_name, NULL, NULL FROM cc.dim_persona
UNION ALL SELECT 's', seg_id, segment, NULL, NULL FROM seg
UNION ALL SELECT 'a', age_id, age_band, NULL, NULL FROM age
UNION ALL SELECT 'g', agent_id, display_name || ' (' || employee_number || ')', team_id, NULL FROM cc.dim_agent WHERE agent_id IN (SELECT g FROM dash.driver_agent);

CREATE INDEX ON dash.driver (m);
CREATE INDEX ON dash.driver_agent (m);
ANALYZE dash.driver;
ANALYZE dash.driver_agent;
COMMENT ON TABLE dash.driver IS 'Monthly additive KPI parts by queue, reason, team, persona, segment and age band, for the Performance Driver Explorer. Rebuilt by E05_driver_cube.sql.';
COMMENT ON TABLE dash.driver_agent IS 'Monthly additive KPI parts by queue, reason and agent, for the Performance Driver Explorer. Rebuilt by E05_driver_cube.sql.';
COMMENT ON TABLE dash.driver_name IS 'Names behind the codes in dash.driver and dash.driver_agent.';
