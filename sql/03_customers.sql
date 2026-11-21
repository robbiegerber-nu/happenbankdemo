-- Customers (~400K), grouped by persona so contacts can sample a persona's customers quickly.
-- customer_product is generated later (07) after first-contact dates are known.
\set ON_ERROR_STOP on
SET client_min_messages = warning;
SET max_parallel_workers_per_gather = 0;
SELECT setseed(0.42);

CREATE TABLE gen.region_cum AS
SELECT region_id, sum(w) OVER (ORDER BY region_id) / sum(w) OVER () AS cum_hi FROM gen.region_param;

CREATE TABLE gen.cust_raw AS
SELECT row_number() OVER (ORDER BY p.persona_id, gs)::int AS customer_id, p.persona_id,
       random() r_age, random() r_g, random() r_inc, random() r_reg, random() r_since, random() r_pre,
       random() r_dig, random() r_digd, random() r_lang, random() r_hh, random() r_seg, random() r_null
FROM gen.persona_param p, generate_series(1, round(400000 * p.share)::int) gs;

INSERT INTO cc.customer
SELECT c.customer_id, c.persona_id, rg.region_id, a.age,
       CASE WHEN a.age < 25 THEN '18-24' WHEN a.age < 35 THEN '25-34' WHEN a.age < 45 THEN '35-44'
            WHEN a.age < 55 THEN '45-54' WHEN a.age < 65 THEN '55-64' WHEN a.age < 75 THEN '65-74' ELSE '75+' END,
       CASE WHEN c.r_null BETWEEN .02 AND .04 THEN NULL
            WHEN c.r_g < .49 THEN 'Female' WHEN c.r_g < .96 THEN 'Male' WHEN c.r_g < .975 THEN 'Non-binary' ELSE 'Prefer not to say' END,
       CASE WHEN c.r_null < .02 THEN NULL
            ELSE (ARRAY['<$35K','$35-60K','$60-100K','$100-150K','$150-250K','$250K+'])[gen.pick(p.income_w, c.r_inc)] END,
       s.since,
       CASE WHEN c.persona_id = 3 THEN 'Small Business'
            WHEN c.persona_id = 8 THEN CASE WHEN c.r_seg < .4 THEN 'Private' ELSE 'Mass Affluent' END
            WHEN c.persona_id IN (4,5) AND c.r_seg < .35 THEN 'Mass Affluent'
            ELSE 'Mass' END,
       c.r_dig < p.digital_prob,
       CASE WHEN c.r_dig < p.digital_prob THEN greatest(s.since, date '2008-01-01') + floor(c.r_digd ^ 1.5 * (date '2026-10-31' - greatest(s.since, date '2008-01-01')))::int END,
       CASE WHEN c.r_lang < .915 THEN 'English' WHEN c.r_lang < .99 THEN 'Spanish' ELSE 'Other' END,
       p.hh_lo + floor((p.hh_hi - p.hh_lo + 1) * c.r_hh)::int
FROM gen.cust_raw c
JOIN gen.persona_param p USING (persona_id)
CROSS JOIN LATERAL (SELECT (p.age_lo + floor((p.age_hi - p.age_lo + 1) * c.r_age ^ p.age_skew))::smallint AS age) a
CROSS JOIN LATERAL (SELECT region_id FROM gen.region_cum WHERE cum_hi >= c.r_reg ORDER BY cum_hi LIMIT 1) rg
CROSS JOIN LATERAL (SELECT CASE WHEN c.r_pre < .88
       THEN date '2024-01-01' - (1 + floor(c.r_since ^ 1.3 * least(p.tenure_max_years, a.age - 17) * 365))::int
       ELSE date '2024-01-01' + floor(c.r_since * 1034)::int END AS since) s;

CREATE TABLE gen.persona_range AS
SELECT persona_id, min(customer_id) AS lo, count(*)::int AS cnt FROM cc.customer GROUP BY persona_id;

DROP TABLE gen.cust_raw;
