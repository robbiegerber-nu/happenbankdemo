-- Customer & Persona Insights: identified customers only, by persona, segment, age band and digital enrollment.
--   dash.pi_cell    the combinations that exist, with customers on the books at each quarter end
--   dash.pi_month   month x cell x channel x reason, additive parts (channel and reason 0 = complaint with no contact)
--   dash.pi_reach   quarter x cell: customers by how many times they contacted
-- Surveys count in the month they were answered, complaints in the month they were opened, as on the scorecard.
\set ON_ERROR_STOP on
SET client_min_messages = warning;
SET work_mem = '512MB';
SET TimeZone = 'America/Chicago';

DROP TABLE IF EXISTS dash.pi_cell, dash.pi_month, dash.pi_reach, dash.pi_name;

CREATE TABLE dash.pi_name AS
SELECT 's' AS k, row_number() OVER (ORDER BY segment)::int AS id, segment AS name FROM (SELECT DISTINCT segment FROM cc.customer) x
UNION ALL SELECT 'a', row_number() OVER (ORDER BY m)::int, age_band FROM (SELECT age_band, min(age) AS m FROM cc.customer GROUP BY 1) x;

CREATE TEMP TABLE cu AS
SELECT c.customer_id, c.customer_since, dense_rank() OVER (ORDER BY c.persona_id, s.id, a.id, c.digital_enrolled)::int AS cell,
       c.persona_id::int AS p, s.id AS s, a.id AS a, c.digital_enrolled::int AS d
FROM cc.customer c JOIN dash.pi_name s ON s.k = 's' AND s.name = c.segment JOIN dash.pi_name a ON a.k = 'a' AND a.name = c.age_band;
CREATE UNIQUE INDEX ON cu (customer_id); ANALYZE cu;

-- full quarters in the data
CREATE TEMP TABLE qs AS
SELECT q AS start, (q + interval '3 months' - interval '1 day')::date AS fin
FROM generate_series((SELECT min(full_date) FROM cc.contact JOIN cc.dim_date USING (date_key)), (SELECT max(full_date) FROM cc.contact JOIN cc.dim_date USING (date_key)), interval '3 months') g(x)
CROSS JOIN LATERAL (SELECT date_trunc('quarter', x)::date AS q) y
WHERE (q + interval '3 months' - interval '1 day')::date <= (SELECT max(full_date) FROM cc.contact JOIN cc.dim_date USING (date_key));

CREATE UNLOGGED TABLE dash.pi_cell AS
SELECT q.start AS q, cell, p, s, a, d, count(*) AS n FROM cu JOIN qs q ON cu.customer_since <= q.fin GROUP BY 1, 2, 3, 4, 5, 6;

CREATE UNLOGGED TABLE dash.pi_month AS
WITH x AS (
  SELECT c.date_key / 100 AS mk, u.cell, c.channel_id::int AS c, c.reason_id::int AS r, 1 AS o, c.answered::int AS a, (c.answered AND coalesce(c.first_contact_resolved, false))::int AS f,
         c.repeat_within_7d::int AS e, 0 AS sv, 0 AS sat, 0 AS net, 0 AS cp
  FROM cc.contact c JOIN cu u USING (customer_id)
  UNION ALL
  SELECT v.date_key / 100, u.cell, c.channel_id, c.reason_id, 0, 0, 0, 0, 1, (v.csat >= 4)::int, CASE WHEN v.nps >= 9 THEN 1 WHEN v.nps <= 6 THEN -1 ELSE 0 END, 0
  FROM cc.survey_response v JOIN cc.contact c USING (contact_id) JOIN cu u ON u.customer_id = v.customer_id
  UNION ALL
  SELECT k.date_key / 100, u.cell, coalesce(c.channel_id, 0), coalesce(c.reason_id, 0), 0, 0, 0, 0, 0, 0, 0, 1
  FROM cc.complaint k JOIN cu u ON u.customer_id = k.customer_id LEFT JOIN cc.contact c USING (contact_id)
)
SELECT mk, cell, c, r, sum(o) AS o, sum(a) AS a, sum(f) AS f, sum(e) AS e, sum(sv) AS sv, sum(sat) AS sat, sum(net) AS net, sum(abs(net)) AS nn, sum(cp) AS cp
FROM x GROUP BY 1, 2, 3, 4;

CREATE UNLOGGED TABLE dash.pi_reach AS
WITH n AS (
  SELECT q.start AS q, u.cell, u.customer_id, count(*) AS k
  FROM cc.contact c JOIN cc.dim_date d USING (date_key) JOIN qs q ON d.full_date BETWEEN q.start AND q.fin JOIN cu u USING (customer_id)
  GROUP BY 1, 2, 3)
SELECT q, cell, count(*) FILTER (WHERE k = 1) AS c1, count(*) FILTER (WHERE k BETWEEN 2 AND 3) AS c2, count(*) FILTER (WHERE k >= 4) AS c4, sum(k) AS k, sum(k) FILTER (WHERE k >= 4) AS k4
FROM n GROUP BY 1, 2;

CREATE INDEX ON dash.pi_month (mk);
ANALYZE dash.pi_month; ANALYZE dash.pi_reach; ANALYZE dash.pi_cell;
DO $$ BEGIN
  IF (SELECT sum(o) FROM dash.pi_month) <> (SELECT count(customer_id) FROM cc.contact) THEN RAISE EXCEPTION 'pi_month contacts differ'; END IF;
  IF (SELECT sum(sv) FROM dash.pi_month) <> (SELECT count(*) FROM cc.survey_response) THEN RAISE EXCEPTION 'pi_month surveys differ'; END IF;
  IF (SELECT sum(cp) FROM dash.pi_month) <> (SELECT count(*) FROM cc.complaint) THEN RAISE EXCEPTION 'pi_month complaints differ'; END IF;
END $$;
COMMENT ON TABLE dash.pi_cell IS 'Customers on the books by persona, segment, age band and digital enrollment at each quarter end, for Customer & Persona Insights. Rebuilt by E20_persona_cube.sql.';
COMMENT ON TABLE dash.pi_month IS 'Monthly contact, survey and complaint parts by customer cell, channel and reason, for Customer & Persona Insights. Rebuilt by E20_persona_cube.sql.';
COMMENT ON TABLE dash.pi_reach IS 'Customers by number of contacts in the quarter, for Customer & Persona Insights. Rebuilt by E20_persona_cube.sql.';
COMMENT ON TABLE dash.pi_name IS 'Segment and age band names behind the codes in dash.pi_cell.';
