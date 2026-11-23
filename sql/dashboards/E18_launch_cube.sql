-- Product Launch Impact: each launch from 8 weeks before to 12 weeks after, in 7-day weeks counted from the launch date
-- (week 0 starts on launch day). Contacts, and the surveys about them, are placed by the date of the contact.
--   dash.launch_week   launch x week x reason, additive parts for every reason (affected or not)
--   dash.launch_who    contacts tagged to the launch, by week and channel or persona
--   dash.launch_comp   complaints tagged to the launch, by week and category
-- Data from November 2026 is left out: those days replay 4-18 October, launch contacts included, so a launch's
-- decline could not be read from them.
\set ON_ERROR_STOP on
SET client_min_messages = warning;
SET work_mem = '512MB';
SET TimeZone = 'America/Chicago';

DROP TABLE IF EXISTS dash.launch_week, dash.launch_who, dash.launch_comp;

CREATE TEMP TABLE lw AS
SELECT l.launch_id AS l, d.date_key, floor((d.full_date - l.launch_date) / 7.0)::int AS w
FROM cc.product_launch l JOIN cc.dim_date d ON d.full_date BETWEEN l.launch_date - 56 AND l.launch_date + 90
WHERE d.full_date <= DATE '2026-10-31'
  AND l.launch_date + floor((d.full_date - l.launch_date) / 7.0)::int * 7 + 6 <= DATE '2026-10-31';   -- whole weeks only
CREATE INDEX ON lw (date_key); ANALYZE lw;

-- one row per day, reason and launch tag, then spread over the launches whose window covers the day
CREATE TEMP TABLE dayr AS
SELECT c.date_key, c.reason_id AS r, count(*) AS o, count(*) FILTER (WHERE c.answered) AS a,
       coalesce(sum(c.handle_sec) FILTER (WHERE c.answered), 0) AS h, count(*) FILTER (WHERE c.answered AND c.first_contact_resolved) AS f,
       count(*) FILTER (WHERE c.answered OR (c.abandoned AND NOT c.short_abandon)) AS g, count(*) FILTER (WHERE c.met_service_level) AS met,
       count(c.customer_id) AS i, count(*) FILTER (WHERE c.customer_id IS NOT NULL AND c.repeat_within_7d) AS e,
       count(s.survey_id) AS sv, count(*) FILTER (WHERE s.csat >= 4) AS sat
FROM cc.contact c LEFT JOIN cc.survey_response s USING (contact_id) GROUP BY 1, 2;

CREATE TEMP TABLE dayt AS SELECT date_key, reason_id AS r, launch_id AS l, count(*) AS t FROM cc.contact WHERE launch_id IS NOT NULL GROUP BY 1, 2, 3;

CREATE UNLOGGED TABLE dash.launch_week AS
SELECT lw.l, lw.w, d.r, sum(o) AS o, sum(a) AS a, sum(h) AS h, sum(f) AS f, sum(g) AS g, sum(met) AS met, sum(i) AS i, sum(e) AS e, sum(sv) AS sv, sum(sat) AS sat, coalesce(sum(t.t), 0) AS t
FROM lw JOIN dayr d USING (date_key) LEFT JOIN dayt t ON t.date_key = d.date_key AND t.r = d.r AND t.l = lw.l
GROUP BY 1, 2, 3;

CREATE UNLOGGED TABLE dash.launch_who AS
SELECT lw.l, lw.w, 'channel' AS k, c.channel_id::int AS id, count(*) AS n FROM cc.contact c JOIN lw ON lw.date_key = c.date_key AND lw.l = c.launch_id GROUP BY 1, 2, 4
UNION ALL
SELECT lw.l, lw.w, 'persona', coalesce(u.persona_id, 0)::int, count(*) FROM cc.contact c JOIN lw ON lw.date_key = c.date_key AND lw.l = c.launch_id LEFT JOIN cc.customer u USING (customer_id) GROUP BY 1, 2, 4
UNION ALL   -- week NULL: the bank's usual mix, all contacts in the 6 weeks before the pre-announcement (weeks -8 to -3)
SELECT lw.l, NULL, 'channel', c.channel_id::int, count(*) FROM cc.contact c JOIN lw USING (date_key) WHERE lw.w BETWEEN -8 AND -3 GROUP BY 1, 4
UNION ALL
SELECT lw.l, NULL, 'persona', coalesce(u.persona_id, 0)::int, count(*) FROM cc.contact c JOIN lw USING (date_key) LEFT JOIN cc.customer u USING (customer_id) WHERE lw.w BETWEEN -8 AND -3 GROUP BY 1, 4;

CREATE UNLOGGED TABLE dash.launch_comp AS
SELECT lw.l, lw.w, cp.category, count(*) AS n, count(*) FILTER (WHERE cp.severity = 'High') AS hi
FROM cc.complaint cp JOIN lw ON lw.date_key = cp.date_key AND lw.l = cp.launch_id GROUP BY 1, 2, 3;

ANALYZE dash.launch_week; ANALYZE dash.launch_who; ANALYZE dash.launch_comp;
COMMENT ON TABLE dash.launch_week IS 'Weekly results by launch window and contact reason, for Product Launch Impact. Rebuilt by E18_launch_cube.sql.';
COMMENT ON TABLE dash.launch_who IS 'Contacts tagged to a launch by channel and persona, with the usual mix, for Product Launch Impact. Rebuilt by E18_launch_cube.sql.';
COMMENT ON TABLE dash.launch_comp IS 'Complaints tagged to a launch by week and category, for Product Launch Impact. Rebuilt by E18_launch_cube.sql.';
