-- Self-Service & Channel Shift: two monthly tables by persona (0 = not identified).
--   dash.ss_contact  contacts by channel and reason, additive parts
--   dash.ss_ivr      phone menu (IVR) sessions by task; task 0 = went to an agent
-- For contained sessions of identified customers, ss_ivr also counts how many of those customers contacted the bank on any
-- channel in the 7 days before and in the 1 and 7 days after. Sessions in the last 7 days of data are left out of those three
-- counts and their base (k), because their 7 days are not complete. Surveys are placed by the date of the contact.
\set ON_ERROR_STOP on
SET client_min_messages = warning;
SET work_mem = '512MB';
SET TimeZone = 'America/Chicago';

DROP TABLE IF EXISTS dash.ss_contact, dash.ss_ivr, dash.ss_task;

-- Menu tasks, with the contact reason an agent would record for the same need (our mapping; NULL = no close match)
CREATE TABLE dash.ss_task AS
SELECT t.id, t.name, r.reason_id AS r, t.reason
FROM (VALUES (1, 'Balance Inquiry', 'Balance & Transaction Inquiry'), (2, 'Recent Transactions', 'Balance & Transaction Inquiry'), (3, 'Card Activation', 'Card Activation'),
             (4, 'Confirm Fraud Alert', 'Fraud Alert Verification'), (5, 'Payment Due Date', 'Loan Payment Question'), (6, 'Make a Loan Payment', 'Loan Payment Question'),
             (7, 'Report Lost Card', 'Lost or Stolen Card'), (8, 'Reset PIN', NULL), (9, 'Branch Hours & Locations', NULL)) t(id, name, reason)
LEFT JOIN cc.dim_contact_reason r ON r.reason = t.reason;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM dash.ss_task WHERE reason IS NOT NULL AND r IS NULL) THEN RAISE EXCEPTION 'ss_task: a contact reason was not found'; END IF;
  IF EXISTS (SELECT 1 FROM cc.ivr_session WHERE contained AND self_service_task NOT IN (SELECT name FROM dash.ss_task)) THEN RAISE EXCEPTION 'ss_task: a menu task is not listed'; END IF;
  IF EXISTS (SELECT 1 FROM cc.ivr_session WHERE contained = opt_out_to_agent) THEN RAISE EXCEPTION 'ss_ivr: a session is neither contained nor sent to an agent'; END IF;
END $$;

CREATE UNLOGGED TABLE dash.ss_contact AS
SELECT c.date_key / 100 AS mk, coalesce(u.persona_id, 0)::int AS p, c.channel_id::int AS c, c.reason_id::int AS r,
       count(*) AS o, count(*) FILTER (WHERE c.answered) AS a, coalesce(sum(c.handle_sec) FILTER (WHERE c.answered), 0) AS h,
       count(*) FILTER (WHERE c.answered AND c.first_contact_resolved) AS f, count(c.customer_id) AS i,
       count(*) FILTER (WHERE c.customer_id IS NOT NULL AND c.repeat_within_7d) AS e, count(s.survey_id) AS sv, count(*) FILTER (WHERE s.csat >= 4) AS sat
FROM cc.contact c LEFT JOIN cc.customer u USING (customer_id) LEFT JOIN cc.survey_response s USING (contact_id)
GROUP BY 1, 2, 3, 4;

-- each contained session with the customer's nearest contacts before and after it
CREATE TEMP TABLE near AS
SELECT id, ts, prev, nxt FROM (
  SELECT x.id, x.ts,
         max(CASE WHEN x.id IS NULL THEN x.ts END) OVER (PARTITION BY x.cu ORDER BY x.ts ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prev,
         min(CASE WHEN x.id IS NULL THEN x.ts END) OVER (PARTITION BY x.cu ORDER BY x.ts ROWS BETWEEN 1 FOLLOWING AND UNBOUNDED FOLLOWING) AS nxt
  FROM (SELECT customer_id AS cu, NULL::bigint AS id, offered_ts AS ts FROM cc.contact WHERE customer_id IS NOT NULL
        UNION ALL SELECT customer_id, session_id, end_ts FROM cc.ivr_session WHERE contained AND customer_id IS NOT NULL) x) y
WHERE id IS NOT NULL;
CREATE UNIQUE INDEX ON near (id); ANALYZE near;

CREATE UNLOGGED TABLE dash.ss_ivr AS
WITH lim AS (SELECT max(d.full_date) + 1 - interval '7 days' AS t FROM cc.contact JOIN cc.dim_date d USING (date_key)),
     fst AS (SELECT min(d.full_date) + interval '7 days' AS t FROM cc.contact JOIN cc.dim_date d USING (date_key))
SELECT i.date_key / 100 AS mk, coalesce(u.persona_id, 0)::int AS p, coalesce(t.id, 0) AS t, count(*) AS n, sum(i.duration_sec) AS d,
       count(n.id) FILTER (WHERE n.ts < lim.t AND n.ts >= fst.t) AS k,
       count(*) FILTER (WHERE n.ts < lim.t AND n.ts >= fst.t AND n.prev >= n.ts - interval '7 days') AS b7,
       count(*) FILTER (WHERE n.ts < lim.t AND n.ts >= fst.t AND n.nxt <= n.ts + interval '1 day') AS a1,
       count(*) FILTER (WHERE n.ts < lim.t AND n.ts >= fst.t AND n.nxt <= n.ts + interval '7 days') AS a7
FROM cc.ivr_session i CROSS JOIN lim CROSS JOIN fst LEFT JOIN cc.customer u USING (customer_id) LEFT JOIN dash.ss_task t ON t.name = i.self_service_task LEFT JOIN near n ON n.id = i.session_id
GROUP BY 1, 2, 3;

CREATE INDEX ON dash.ss_contact (mk);
CREATE INDEX ON dash.ss_ivr (mk);
ANALYZE dash.ss_contact; ANALYZE dash.ss_ivr;
DO $$ BEGIN
  IF (SELECT sum(o) FROM dash.ss_contact) <> (SELECT count(*) FROM cc.contact) THEN RAISE EXCEPTION 'ss_contact total differs'; END IF;
  IF (SELECT sum(n) FROM dash.ss_ivr) <> (SELECT count(*) FROM cc.ivr_session) THEN RAISE EXCEPTION 'ss_ivr total differs'; END IF;
END $$;
COMMENT ON TABLE dash.ss_contact IS 'Contacts by month, persona, channel and reason, for Self-Service & Channel Shift. Rebuilt by E23_selfservice_cube.sql.';
COMMENT ON TABLE dash.ss_ivr IS 'Phone menu sessions by month, persona and task, with contacts before and after, for Self-Service & Channel Shift. Rebuilt by E23_selfservice_cube.sql.';
COMMENT ON TABLE dash.ss_task IS 'Phone menu tasks and the contact reason an agent would record for the same need.';
