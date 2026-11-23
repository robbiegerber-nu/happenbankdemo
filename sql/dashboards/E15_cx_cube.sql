-- Customer Experience: three monthly tables, all with queue, reason, segment and persona so the page can filter exactly.
--   dash.cx_contact    contacts offered, answered, resolved on first contact, identified and repeated (additive)
--   dash.cx_survey     one row per survey (scores, theme and what happened on the contact), with no customer or agent
--   dash.cx_complaint  one row per complaint, including those with no contact (branch, web form, social media, regulator)
-- 0 means "none": the customer was not identified, or the complaint has no contact.
-- Surveys count in the month they were answered, complaints in the month they were opened, as on the scorecard.
\set ON_ERROR_STOP on
SET client_min_messages = warning;
SET work_mem = '512MB';
SET TimeZone = 'America/Chicago';

DROP TABLE IF EXISTS dash.cx_contact, dash.cx_survey, dash.cx_complaint, dash.cx_name;

-- Names behind the codes (segments and text categories have no id in cc)
CREATE TABLE dash.cx_name AS
SELECT 'segment' AS k, row_number() OVER (ORDER BY segment)::int AS id, segment AS name FROM (SELECT DISTINCT segment FROM cc.customer) x
UNION ALL SELECT 'theme', row_number() OVER (ORDER BY verbatim_theme)::int, verbatim_theme FROM (SELECT DISTINCT verbatim_theme FROM cc.survey_response) x
UNION ALL SELECT 'category', row_number() OVER (ORDER BY category)::int, category FROM (SELECT DISTINCT category FROM cc.complaint) x
UNION ALL SELECT 'cause', row_number() OVER (ORDER BY root_cause)::int, root_cause FROM (SELECT DISTINCT root_cause FROM cc.complaint) x
UNION ALL SELECT 'via', row_number() OVER (ORDER BY channel_received)::int, channel_received FROM (SELECT DISTINCT channel_received FROM cc.complaint) x
UNION ALL SELECT 'severity', i, n FROM (VALUES (1, 'High'), (2, 'Medium'), (3, 'Low')) x(i, n);

CREATE TEMP TABLE cust AS SELECT c.customer_id, coalesce(c.persona_id, 0) AS p, n.id AS s FROM cc.customer c JOIN dash.cx_name n ON n.k = 'segment' AND n.name = c.segment;
CREATE UNIQUE INDEX ON cust (customer_id); ANALYZE cust;

CREATE UNLOGGED TABLE dash.cx_contact AS
SELECT c.date_key / 100 AS mk, c.queue_id AS q, c.reason_id AS r, coalesce(u.s, 0) AS s, coalesce(u.p, 0) AS p,
       count(*) AS o, count(*) FILTER (WHERE c.answered) AS a,
       count(*) FILTER (WHERE c.answered AND c.first_contact_resolved) AS f,
       count(c.customer_id) AS i, count(*) FILTER (WHERE c.customer_id IS NOT NULL AND c.repeat_within_7d) AS e
FROM cc.contact c LEFT JOIN cust u USING (customer_id)
GROUP BY 1, 2, 3, 4, 5;

-- hap: 1 resolved on first contact, 2 transferred, 4 escalated, 8 answered within the service level, 16 contacted again within 7 days
CREATE UNLOGGED TABLE dash.cx_survey AS
SELECT sv.date_key / 100 AS mk, c.queue_id AS q, c.reason_id AS r, coalesce(u.s, 0) AS s, coalesce(u.p, 0) AS p,
       sv.csat AS cs, sv.nps AS np, sv.ces AS ce, t.id AS t,
       coalesce(c.first_contact_resolved, false)::int + 2 * c.transferred::int + 4 * c.escalated::int + 8 * c.met_service_level::int + 16 * c.repeat_within_7d::int AS hap
FROM cc.survey_response sv JOIN cc.contact c USING (contact_id)
JOIN dash.cx_name t ON t.k = 'theme' AND t.name = sv.verbatim_theme
LEFT JOIN cust u ON u.customer_id = sv.customer_id;

CREATE UNLOGGED TABLE dash.cx_complaint AS
SELECT cp.date_key / 100 AS mk, coalesce(c.queue_id, 0) AS q, coalesce(c.reason_id, 0) AS r, coalesce(u.s, 0) AS s, coalesce(u.p, 0) AS p,
       ca.id AS cat, se.id AS sev, rc.id AS cause, v.id AS via, cp.regulatory_flag::int AS reg,
       CASE WHEN cp.closed_ts IS NULL THEN NULL ELSE cp.days_to_close END AS dtc
FROM cc.complaint cp LEFT JOIN cc.contact c USING (contact_id) LEFT JOIN cust u ON u.customer_id = cp.customer_id
JOIN dash.cx_name ca ON ca.k = 'category' AND ca.name = cp.category
JOIN dash.cx_name se ON se.k = 'severity' AND se.name = cp.severity
JOIN dash.cx_name rc ON rc.k = 'cause' AND rc.name = cp.root_cause
JOIN dash.cx_name v ON v.k = 'via' AND v.name = cp.channel_received;

CREATE INDEX ON dash.cx_contact (mk);
CREATE INDEX ON dash.cx_survey (mk);
CREATE INDEX ON dash.cx_complaint (mk);
ANALYZE dash.cx_contact; ANALYZE dash.cx_survey; ANALYZE dash.cx_complaint;

-- Every survey and complaint must have found its names
DO $$ BEGIN
  IF (SELECT count(*) FROM dash.cx_survey) <> (SELECT count(*) FROM cc.survey_response) THEN RAISE EXCEPTION 'cx_survey row count differs'; END IF;
  IF (SELECT count(*) FROM dash.cx_complaint) <> (SELECT count(*) FROM cc.complaint) THEN RAISE EXCEPTION 'cx_complaint row count differs'; END IF;
  IF (SELECT sum(o) FROM dash.cx_contact) <> (SELECT count(*) FROM cc.contact) THEN RAISE EXCEPTION 'cx_contact total differs'; END IF;
END $$;
COMMENT ON TABLE dash.cx_contact IS 'Contact counts by month, queue, reason, segment and persona, for Customer Experience. Rebuilt by E15_cx_cube.sql.';
COMMENT ON TABLE dash.cx_survey IS 'Surveys with scores, theme and what happened on the contact, for Customer Experience. Rebuilt by E15_cx_cube.sql.';
COMMENT ON TABLE dash.cx_complaint IS 'Complaints with category, severity, cause and days to close, for Customer Experience. Rebuilt by E15_cx_cube.sql.';
COMMENT ON TABLE dash.cx_name IS 'Names behind the codes in dash.cx_survey and dash.cx_complaint.';
