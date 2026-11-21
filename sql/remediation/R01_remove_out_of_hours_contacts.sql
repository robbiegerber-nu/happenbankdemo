-- Remediation R01 - phone and chat contacts offered outside opening hours
-- ------------------------------------------------------------------------------------------------
-- Found by:   discovery run 1, rule VAL-005 (5,519 phone/chat contacts answered outside opening hours)
-- Root cause: agents who logged in up to ~2.5 minutes early were given contacts before the phones
--             opened (06:57-07:00 weekdays, 07:57-08:00 Saturdays). Abandoned calls were then placed
--             in the same pre-opening interval: 6,039 contacts offered before opening in total.
--             Run 2 (with the refined rule) found the mirror case: 8 contacts offered up to ~2 minutes
--             after closing to agents who logged out late.
-- Source fix: sql/05_demand.sql now clips agents' Available time to opening hours (both ends), so a
--             rebuild no longer creates these contacts.
-- Data fix:   remove the affected contacts (0.10% of all contacts) and the rows that depend on them,
--             refresh repeat-contact flags, then rebuild the summaries (sql/08_aggregates.sql).
--             Applied twice: before run 2 (6,039 pre-opening) and before run 3 (8 after-closing).
-- Safe to re-run: deletes nothing once the data is clean.
\set ON_ERROR_STOP on
SET client_min_messages = warning;
SET work_mem = '1GB';
BEGIN;

CREATE TEMP TABLE r01_bad ON COMMIT DROP AS
SELECT c.contact_id
FROM cc.contact c JOIN cc.dim_date d ON d.full_date = c.offered_ts::date
WHERE c.channel_id IN (1, 2)
  AND (d.is_center_closed
       OR c.offered_ts::time < CASE WHEN d.day_of_week = 6 THEN time '08:00' ELSE time '07:00' END
       OR c.offered_ts::time > CASE WHEN d.day_of_week = 6 THEN time '17:00' ELSE time '21:00' END);

SELECT 'contacts to remove' AS item, count(*) FROM r01_bad
UNION ALL SELECT 'ivr_session rows', count(*) FROM cc.ivr_session WHERE contact_id IN (SELECT contact_id FROM r01_bad)
UNION ALL SELECT 'survey_response rows', count(*) FROM cc.survey_response WHERE contact_id IN (SELECT contact_id FROM r01_bad)
UNION ALL SELECT 'complaint rows', count(*) FROM cc.complaint WHERE contact_id IN (SELECT contact_id FROM r01_bad);

DELETE FROM cc.ivr_session     WHERE contact_id IN (SELECT contact_id FROM r01_bad);
DELETE FROM cc.survey_response WHERE contact_id IN (SELECT contact_id FROM r01_bad);
DELETE FROM cc.complaint       WHERE contact_id IN (SELECT contact_id FROM r01_bad);
DELETE FROM cc.contact         WHERE contact_id IN (SELECT contact_id FROM r01_bad);

-- Repeat-contact flags may have pointed at a removed contact: recalculate for affected customers only
UPDATE cc.contact c SET repeat_within_7d = coalesce(x.nxt <= c.offered_ts + interval '7 days', false)
FROM (SELECT contact_id, lead(offered_ts) OVER (PARTITION BY customer_id ORDER BY offered_ts) AS nxt
      FROM cc.contact WHERE customer_id IN (SELECT DISTINCT customer_id FROM cc.contact WHERE repeat_within_7d)) x
WHERE x.contact_id = c.contact_id AND c.repeat_within_7d IS DISTINCT FROM coalesce(x.nxt <= c.offered_ts + interval '7 days', false);

COMMIT;
VACUUM ANALYZE cc.contact;
VACUUM ANALYZE cc.ivr_session;
