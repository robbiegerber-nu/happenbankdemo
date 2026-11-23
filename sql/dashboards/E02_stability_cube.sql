-- Daily KPI cube for the Process Stability Monitor.
-- One row per metric × dimension × member × day, holding the KPI's additive parts:
--   x = numerator (or the total, for sums), n = denominator, k = sample count used for the minimum-sample rule
-- The page rebuilds any value from these (x ÷ n), so daily and weekly figures, and every slice, follow the
-- golden rule: ratios come from totals, never from averaging percentages.
-- Which dimensions each metric can be split by is decided here (a dimension a metric can't honestly be split by,
-- like service level by agent site when abandoned calls have no agent, is simply not exported).
\set ON_ERROR_STOP on
SET client_min_messages = warning;
SET work_mem = '512MB';

DROP TABLE IF EXISTS dash.stability;
CREATE UNLOGGED TABLE dash.stability (
  metric text NOT NULL, dim text NOT NULL, member text NOT NULL, d date NOT NULL,
  x numeric NOT NULL, n numeric NOT NULL, k numeric NOT NULL
);
COMMENT ON TABLE dash.stability IS 'Daily KPI parts (x numerator, n denominator, k sample count) by metric, dimension and member, for the Process Stability Monitor. Rebuilt by E02_stability_cube.sql.';

-- Dimensions each metric may be split by ('All' is the whole center)
CREATE TEMP TABLE metric_dim (metric text, dim text) ON COMMIT PRESERVE ROWS;
INSERT INTO metric_dim
SELECT m, unnest(dims) FROM (VALUES
  ('sl_phone',        ARRAY['All', 'Queue', 'Contact reason', 'Persona', 'Customer segment']),
  ('sl_chat',         ARRAY['All', 'Queue', 'Contact reason', 'Persona', 'Customer segment']),
  ('sl_email',        ARRAY['All', 'Queue', 'Contact reason', 'Persona', 'Customer segment']),
  ('sl_callback',     ARRAY['All', 'Contact reason', 'Persona', 'Customer segment']),
  ('asa_phone',       ARRAY['All', 'Queue', 'Contact reason', 'Persona', 'Customer segment']),
  ('abandon',         ARRAY['All', 'Channel', 'Queue', 'Contact reason', 'Persona', 'Customer segment']),
  ('aht_phone',       ARRAY['All', 'Queue', 'Contact reason', 'Site', 'Team', 'Persona']),
  ('fcr',             ARRAY['All', 'Channel', 'Queue', 'Contact reason', 'Site', 'Team', 'Persona', 'Customer segment']),
  ('volume',          ARRAY['All', 'Channel', 'Queue', 'Contact reason', 'Persona', 'Customer segment']),
  ('digital_share',   ARRAY['All', 'Contact reason', 'Persona', 'Customer segment']),
  ('csat',            ARRAY['All', 'Channel', 'Contact reason', 'Site', 'Team', 'Persona', 'Customer segment']),
  ('nps',             ARRAY['All', 'Channel', 'Contact reason', 'Site', 'Team', 'Persona', 'Customer segment']),
  ('complaints',      ARRAY['All', 'Category', 'Persona', 'Customer segment']),
  ('adherence',       ARRAY['All', 'Site', 'Team']),
  ('occupancy',       ARRAY['All', 'Site', 'Team']),
  ('staffing',        ARRAY['All', 'Queue']),
  ('ivr_containment', ARRAY['All'])
) v(m, dims);

-- ---------- Contacts: one pass over 6M rows with grouping sets ----------
CREATE TEMP TABLE c_cube ON COMMIT PRESERVE ROWS AS
SELECT d.full_date AS d,
       CASE WHEN GROUPING(ch.channel_name) = 0 THEN 'Channel'
            WHEN GROUPING(q.queue_name) = 0 THEN 'Queue'
            WHEN GROUPING(r.reason_group) = 0 THEN 'Contact reason'
            WHEN GROUPING(p.persona_name) = 0 THEN 'Persona'
            WHEN GROUPING(cu.segment) = 0 THEN 'Customer segment'
            WHEN GROUPING(s.site_name) = 0 THEN 'Site'
            WHEN GROUPING(t.team_name) = 0 THEN 'Team'
            ELSE 'All' END AS dim,
       coalesce(ch.channel_name, q.queue_name, r.reason_group, p.persona_name, cu.segment, s.site_name, t.team_name,
                CASE WHEN GROUPING(p.persona_name) = 0 OR GROUPING(cu.segment) = 0 THEN 'Unidentified customer' END,
                'All') AS member,
       GROUPING(s.site_name) = 0 OR GROUPING(t.team_name) = 0 AS agent_dim,
       count(*) AS offered,
       count(*) FILTER (WHERE c.channel_id IN (2, 3, 5)) AS offered_digital,
       count(*) FILTER (WHERE c.channel_id = 1 AND c.met_service_level) AS met_ph,
       count(*) FILTER (WHERE c.channel_id = 1 AND (c.answered OR (c.abandoned AND NOT c.short_abandon))) AS elig_ph,
       count(*) FILTER (WHERE c.channel_id = 2 AND c.met_service_level) AS met_ch,
       count(*) FILTER (WHERE c.channel_id = 2 AND (c.answered OR (c.abandoned AND NOT c.short_abandon))) AS elig_ch,
       count(*) FILTER (WHERE c.channel_id IN (3, 5) AND c.met_service_level) AS met_em,
       count(*) FILTER (WHERE c.channel_id IN (3, 5) AND (c.answered OR (c.abandoned AND NOT c.short_abandon))) AS elig_em,
       count(*) FILTER (WHERE c.channel_id = 4 AND c.met_service_level) AS met_cb,
       count(*) FILTER (WHERE c.channel_id = 4 AND (c.answered OR (c.abandoned AND NOT c.short_abandon))) AS elig_cb,
       count(*) FILTER (WHERE c.channel_id = 1 AND c.answered) AS ans_ph,
       coalesce(sum(c.queue_wait_sec) FILTER (WHERE c.channel_id = 1 AND c.answered), 0) AS wait_ph,
       coalesce(sum(c.handle_sec) FILTER (WHERE c.channel_id = 1 AND c.answered), 0) AS handle_ph,
       count(*) FILTER (WHERE c.channel_id IN (1, 2)) AS offered_pc,
       count(*) FILTER (WHERE c.channel_id IN (1, 2) AND c.abandoned) AS aband_pc,
       count(*) FILTER (WHERE c.answered) AS answered,
       count(*) FILTER (WHERE c.answered AND c.first_contact_resolved) AS resolved
FROM cc.contact c
JOIN cc.dim_date d ON d.date_key = c.date_key
JOIN cc.dim_channel ch ON ch.channel_id = c.channel_id
JOIN cc.dim_queue q ON q.queue_id = c.queue_id
JOIN cc.dim_contact_reason r ON r.reason_id = c.reason_id
LEFT JOIN cc.customer cu ON cu.customer_id = c.customer_id
LEFT JOIN cc.dim_persona p ON p.persona_id = cu.persona_id
LEFT JOIN cc.dim_agent a ON a.agent_id = c.agent_id
LEFT JOIN cc.dim_team t ON t.team_id = a.team_id
LEFT JOIN cc.dim_site s ON s.site_id = t.site_id
GROUP BY GROUPING SETS ((d.full_date), (d.full_date, ch.channel_name), (d.full_date, q.queue_name),
                        (d.full_date, r.reason_group), (d.full_date, p.persona_name), (d.full_date, cu.segment),
                        (d.full_date, s.site_name), (d.full_date, t.team_name));
-- Site and team rows for contacts that never reached an agent have no member: drop them
DELETE FROM c_cube WHERE agent_dim AND member = 'All';

INSERT INTO dash.stability (metric, dim, member, d, x, n, k)
SELECT v.metric, c.dim, c.member, c.d, v.x, v.n, v.n
FROM c_cube c
CROSS JOIN LATERAL (VALUES
  ('sl_phone', c.met_ph, c.elig_ph), ('sl_chat', c.met_ch, c.elig_ch), ('sl_email', c.met_em, c.elig_em),
  ('sl_callback', c.met_cb, c.elig_cb),
  ('asa_phone', c.wait_ph, c.ans_ph), ('aht_phone', c.handle_ph, c.ans_ph),
  ('abandon', c.aband_pc, c.offered_pc), ('fcr', c.resolved, c.answered),
  ('volume', c.offered, c.offered), ('digital_share', c.offered_digital, c.offered)
) v(metric, x, n)
JOIN metric_dim md ON md.metric = v.metric AND md.dim = c.dim
WHERE v.n > 0;

-- ---------- Surveys (CSAT, NPS), split by the surveyed contact and the agent who handled it ----------
INSERT INTO dash.stability (metric, dim, member, d, x, n, k)
SELECT v.metric, g.dim, g.member, g.d, v.x, g.surveys, g.surveys
FROM (
  SELECT d.full_date AS d,
         CASE WHEN GROUPING(ch.channel_name) = 0 THEN 'Channel' WHEN GROUPING(r.reason_group) = 0 THEN 'Contact reason'
              WHEN GROUPING(p.persona_name) = 0 THEN 'Persona' WHEN GROUPING(cu.segment) = 0 THEN 'Customer segment'
              WHEN GROUPING(si.site_name) = 0 THEN 'Site' WHEN GROUPING(t.team_name) = 0 THEN 'Team' ELSE 'All' END AS dim,
         coalesce(ch.channel_name, r.reason_group, p.persona_name, cu.segment, si.site_name, t.team_name, 'All') AS member,
         count(*) AS surveys,
         count(*) FILTER (WHERE sv.csat >= 4) AS satisfied,
         count(*) FILTER (WHERE sv.nps >= 9) - count(*) FILTER (WHERE sv.nps <= 6) AS net_promoters
  FROM cc.survey_response sv
  JOIN cc.dim_date d ON d.date_key = sv.date_key
  JOIN cc.contact c ON c.contact_id = sv.contact_id
  JOIN cc.dim_channel ch ON ch.channel_id = c.channel_id
  JOIN cc.dim_contact_reason r ON r.reason_id = c.reason_id
  JOIN cc.customer cu ON cu.customer_id = sv.customer_id
  JOIN cc.dim_persona p ON p.persona_id = cu.persona_id
  JOIN cc.dim_agent a ON a.agent_id = sv.agent_id
  JOIN cc.dim_team t ON t.team_id = a.team_id
  JOIN cc.dim_site si ON si.site_id = t.site_id
  GROUP BY GROUPING SETS ((d.full_date), (d.full_date, ch.channel_name), (d.full_date, r.reason_group),
                          (d.full_date, p.persona_name), (d.full_date, cu.segment), (d.full_date, si.site_name),
                          (d.full_date, t.team_name))
) g
CROSS JOIN LATERAL (VALUES ('csat', g.satisfied), ('nps', g.net_promoters)) v(metric, x)
JOIN metric_dim md ON md.metric = v.metric AND md.dim = g.dim;

-- ---------- Complaints per 1,000 contacts: complaints by day over contacts offered that day ----------
-- Starts from the days with contacts, so a day with no complaints counts as zero instead of dropping out.
CREATE TEMP TABLE cp_cube ON COMMIT PRESERVE ROWS AS
SELECT d.full_date AS d,
       CASE WHEN GROUPING(cp.category) = 0 THEN 'Category' WHEN GROUPING(p.persona_name) = 0 THEN 'Persona'
            WHEN GROUPING(cu.segment) = 0 THEN 'Customer segment' ELSE 'All' END AS dim,
       coalesce(cp.category, p.persona_name, cu.segment, 'All') AS member,
       count(*) AS complaints
FROM cc.complaint cp
JOIN cc.dim_date d ON d.date_key = cp.date_key
JOIN cc.customer cu ON cu.customer_id = cp.customer_id
JOIN cc.dim_persona p ON p.persona_id = cu.persona_id
GROUP BY GROUPING SETS ((d.full_date), (d.full_date, cp.category), (d.full_date, p.persona_name), (d.full_date, cu.segment));

-- Category rates are per 1,000 of ALL contacts; persona and segment rates are per 1,000 of that group's contacts
INSERT INTO dash.stability (metric, dim, member, d, x, n, k)
SELECT 'complaints', m.dim, m.member, den.d, coalesce(g.complaints, 0), den.offered, den.offered
FROM (SELECT DISTINCT dim, member FROM cp_cube) m
JOIN c_cube den ON (m.dim IN ('All', 'Category') AND den.dim = 'All') OR (m.dim = den.dim AND m.member = den.member)
LEFT JOIN cp_cube g ON g.dim = m.dim AND g.member = m.member AND g.d = den.d
WHERE den.offered > 0;

-- ---------- Agent-days (adherence, occupancy); PTO and absence excluded ----------
INSERT INTO dash.stability (metric, dim, member, d, x, n, k)
SELECT v.metric, g.dim, g.member, g.d, v.x, v.n, g.agent_days
FROM (
  SELECT full_date AS d,
         CASE WHEN GROUPING(site_name) = 0 THEN 'Site' WHEN GROUPING(team_name) = 0 THEN 'Team' ELSE 'All' END AS dim,
         coalesce(site_name, team_name, 'All') AS member,
         count(*) AS agent_days, sum(in_adherence_min) AS in_adh, sum(scheduled_min) AS sched,
         sum(occupancy_pct * available_min) AS occ_w, sum(available_min) AS avail
  FROM cc.v_agent_adherence
  WHERE NOT is_pto AND NOT is_absent AND scheduled_min > 0
  GROUP BY GROUPING SETS ((full_date), (full_date, site_name), (full_date, team_name))
) g
CROSS JOIN LATERAL (VALUES ('adherence', g.in_adh, g.sched), ('occupancy', g.occ_w, g.avail)) v(metric, x, n)
JOIN metric_dim md ON md.metric = v.metric AND md.dim = g.dim
WHERE v.n > 0;

-- ---------- Staffing vs required (phone and chat queues) ----------
INSERT INTO dash.stability (metric, dim, member, d, x, n, k)
SELECT 'staffing', CASE WHEN GROUPING(q.queue_name) = 0 THEN 'Queue' ELSE 'All' END, coalesce(q.queue_name, 'All'),
       d.full_date, sum(v.scheduled_fte) - sum(v.required_fte), sum(v.required_fte), count(*)
FROM cc.interval_volume v JOIN cc.dim_date d USING (date_key) JOIN cc.dim_queue q USING (queue_id)
WHERE q.channel_id IN (1, 2)
GROUP BY GROUPING SETS ((d.full_date), (d.full_date, q.queue_name))
HAVING sum(v.required_fte) > 0;

-- ---------- IVR containment ----------
INSERT INTO dash.stability (metric, dim, member, d, x, n, k)
SELECT 'ivr_containment', 'All', 'All', d.full_date, count(*) FILTER (WHERE i.contained), count(*), count(*)
FROM cc.ivr_session i JOIN cc.dim_date d USING (date_key)
GROUP BY d.full_date;

CREATE INDEX ON dash.stability (metric, dim, member, d);
ANALYZE dash.stability;
