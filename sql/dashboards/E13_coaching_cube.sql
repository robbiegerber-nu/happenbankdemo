-- Agent & Team Coaching: one row per month x agent, as additive parts.
-- Handle time, resolution, transfers and satisfaction are compared with what the same contacts (same queue and reason)
-- took the agent's group that month, so a different mix of work is not mistaken for a difference in skill:
--   e*  = expected from the group's average for the same queue and reason
--   v*  = variance of the total, used to tell a real difference from chance
-- Adherence and quality do not depend on the mix of contacts; their group average is worked out on the page.
-- Groups are the agents' primary channel (1 phone, 2 chat, 3 email). Surveys count in the month they were answered.
\set ON_ERROR_STOP on
SET client_min_messages = warning;
SET work_mem = '512MB';
SET TimeZone = 'America/Chicago';

DROP TABLE IF EXISTS dash.coaching;

CREATE TEMP TABLE co AS
SELECT d.date_key / 100 AS mk, c.agent_id AS g, a.primary_channel_id AS grp, c.queue_id AS q, c.reason_id AS r,
       c.handle_sec AS h, c.talk_sec AS tk, c.hold_sec AS hd, c.wrap_sec AS wr,
       coalesce(c.first_contact_resolved, false)::int AS res, c.transferred::int AS tr
FROM cc.contact c JOIN cc.dim_date d USING (date_key) JOIN cc.dim_agent a USING (agent_id)
WHERE c.answered;

CREATE TEMP TABLE peer AS
SELECT mk, grp, q, r, avg(h) AS h, avg(tk) AS tk, avg(hd) AS hd, avg(wr) AS wr, avg(res) AS res, avg(tr) AS tr
FROM co GROUP BY 1, 2, 3, 4;

CREATE TEMP TABLE sv AS
SELECT s.date_key / 100 AS mk, s.agent_id AS g, a.primary_channel_id AS grp, c.queue_id AS q, c.reason_id AS r, (s.csat >= 4)::int AS sat
FROM cc.survey_response s JOIN cc.contact c USING (contact_id) JOIN cc.dim_agent a ON a.agent_id = s.agent_id;

CREATE TEMP TABLE peer_sv AS SELECT mk, grp, q, r, avg(sat) AS sat FROM sv GROUP BY 1, 2, 3, 4;

ANALYZE co; ANALYZE peer; ANALYZE sv; ANALYZE peer_sv;

CREATE UNLOGGED TABLE dash.coaching AS
WITH k AS (
  SELECT mk, g, count(*) AS ans, sum(co.h) AS h, sum(p.h) AS eh, sum((co.h - p.h) ^ 2) AS vh,
         sum(co.tk) AS tk, sum(p.tk) AS etk, sum(co.hd) AS hd, sum(p.hd) AS ehd, sum(co.wr) AS wr, sum(p.wr) AS ewr,
         sum(co.res) AS res, sum(p.res) AS eres, sum(p.res * (1 - p.res)) AS vres,
         sum(co.tr) AS tr, sum(p.tr) AS etr, sum(p.tr * (1 - p.tr)) AS vtr
  FROM co JOIN peer p USING (mk, grp, q, r) GROUP BY 1, 2
), s AS (
  SELECT mk, g, count(*) AS sv, sum(sv.sat) AS sat, sum(p.sat) AS esat, sum(p.sat * (1 - p.sat)) AS vsat
  FROM sv JOIN peer_sv p USING (mk, grp, q, r) GROUP BY 1, 2
), w AS (
  SELECT date_key / 100 AS mk, agent_id AS g, count(*) AS n,
         sum(scheduled_min) AS sch, sum(in_adherence_min) AS adh,
         sum(in_adherence_min ^ 2) AS aa, sum(in_adherence_min * scheduled_min) AS ab, sum(scheduled_min::numeric ^ 2) AS bb,
         sum(late_login_min) AS late, sum(early_logout_min) AS early, sum(extended_break_min) AS ext, sum(unplanned_aux_min) AS aux,
         sum(shrinkage_coaching_min) AS coa, sum(shrinkage_training_min) AS trn,
         count(quality_score) AS qn, coalesce(sum(quality_score), 0) AS qs, coalesce(sum(quality_score::int ^ 2), 0) AS qq
  FROM cc.agent_daily WHERE NOT is_pto AND NOT is_absent AND scheduled_min > 0 GROUP BY 1, 2
)
-- FULL: next-day answers and surveys can land in a month the agent no longer worked
SELECT mk, g, coalesce(n, 0) AS n, coalesce(sch, 0) AS sch, coalesce(adh, 0) AS adh, coalesce(aa, 0) AS aa, coalesce(ab, 0) AS ab, coalesce(bb, 0) AS bb,
       coalesce(late, 0) AS late, coalesce(early, 0) AS early, coalesce(ext, 0) AS ext, coalesce(aux, 0) AS aux, coalesce(coa, 0) AS coa, coalesce(trn, 0) AS trn,
       coalesce(qn, 0) AS qn, coalesce(qs, 0) AS qs, coalesce(qq, 0) AS qq,
       coalesce(ans, 0) AS ans, coalesce(h, 0) AS h, coalesce(eh, 0) AS eh, coalesce(vh, 0) AS vh,
       coalesce(tk, 0) AS tk, coalesce(etk, 0) AS etk, coalesce(hd, 0) AS hd, coalesce(ehd, 0) AS ehd, coalesce(wr, 0) AS wr, coalesce(ewr, 0) AS ewr,
       coalesce(res, 0) AS res, coalesce(eres, 0) AS eres, coalesce(vres, 0) AS vres, coalesce(tr, 0) AS tr, coalesce(etr, 0) AS etr, coalesce(vtr, 0) AS vtr,
       coalesce(sv, 0) AS sv, coalesce(sat, 0) AS sat, coalesce(esat, 0) AS esat, coalesce(vsat, 0) AS vsat
FROM w FULL JOIN k USING (mk, g) FULL JOIN s USING (mk, g);

CREATE INDEX ON dash.coaching (mk);
ANALYZE dash.coaching;
COMMENT ON TABLE dash.coaching IS 'Agent results by month with group expectations for the same queues and reasons, for Agent & Team Coaching. Rebuilt by E13_coaching_cube.sql.';
