-- IVR sessions, surveys, complaints, customer tenure fix, customer products.
\set ON_ERROR_STOP on
SET client_min_messages = warning;
SET max_parallel_workers_per_gather = 0;
SET work_mem = '1GB';
SELECT setseed(0.47);
TRUNCATE cc.ivr_session, cc.survey_response, cc.complaint, cc.customer_product;

-- ================= IVR =================
-- (a) every phone contact first passed through the IVR and opted out to an agent
CREATE TABLE gen.ivr_stage AS
SELECT c.customer_id, c.offered_ts - (25 + random() * 85) * interval '1 sec' AS start_ts, c.offered_ts AS end_ts,
       'Main > ' || r.reason_group || ' > Speak to an agent' AS menu_path, NULL::text AS self_service_task,
       false AS contained, true AS opt_out_to_agent, c.contact_id
FROM cc.contact c JOIN cc.dim_contact_reason r USING (reason_id)
WHERE c.channel_id = 1;

-- (b) contained self-service sessions; containment rises from ~30% to ~42% over the period (dips during the outage)
CREATE TABLE gen.ph AS
SELECT c.contact_id, c.date_key, c.offered_ts, cu.persona_id,
       row_number() OVER (PARTITION BY c.date_key ORDER BY c.contact_id) AS rn
FROM cc.contact c LEFT JOIN cc.customer cu USING (customer_id)
WHERE c.channel_id = 1;
CREATE INDEX ON gen.ph (date_key, rn);

CREATE TABLE gen.ivr_c AS
SELECT pd.date_key, d.full_date, pd.n, random() AS r1, random() AS r2, random() AS r3, random() AS r4, random() AS r5, random() AS r6
FROM (SELECT date_key, count(*) AS n FROM gen.ph GROUP BY 1) pd
JOIN cc.dim_date d USING (date_key)
CROSS JOIN LATERAL (SELECT 0.30 + 0.12 * (d.full_date - date '2024-01-01') / 1034.0
                         - CASE WHEN d.full_date BETWEEN date '2026-04-07' AND date '2026-04-08' THEN .08 ELSE 0 END AS c) cr
CROSS JOIN LATERAL generate_series(1, round(pd.n * cr.c / (1 - cr.c))::int) g(i);

INSERT INTO gen.ivr_stage
SELECT CASE WHEN t.persona_id IS NULL THEN NULL ELSE pr.lo + floor(x.r3 * pr.cnt)::int END,
       st.start_ts, st.start_ts + (40 + x.r4 * 200) * interval '1 sec',
       'Main > ' || tk.cat || ' > ' || tk.task, tk.task, true, false, NULL
FROM gen.ivr_c x
JOIN gen.ph t ON t.date_key = x.date_key AND t.rn = 1 + floor(x.r1 * x.n)::int
LEFT JOIN gen.persona_range pr ON pr.persona_id = t.persona_id
CROSS JOIN LATERAL (SELECT CASE WHEN x.r2 < .9 THEN t.offered_ts - x.r5 * interval '600 sec'
                                ELSE x.full_date::timestamptz + x.r5 * interval '86399 sec' END AS start_ts) st
CROSS JOIN LATERAL (SELECT (ARRAY['Balance Inquiry','Recent Transactions','Card Activation','Payment Due Date','Make a Loan Payment',
                                  'Confirm Fraud Alert','Report Lost Card','Reset PIN','Branch Hours & Locations'])[k] AS task,
                           (ARRAY['Accounts','Accounts','Cards','Loans','Loans','Fraud','Cards','Cards','General'])[k] AS cat
                    FROM (SELECT gen.pick(ARRAY[30,18,12,8,8,8,4,6,6]::numeric[], x.r6) AS k) kk) tk;

INSERT INTO cc.ivr_session
SELECT row_number() OVER (ORDER BY start_ts), customer_id, start_ts, end_ts, round(extract(epoch FROM end_ts - start_ts))::int,
       gen.dk(start_ts), menu_path, self_service_task, contained, opt_out_to_agent, contact_id
FROM gen.ivr_stage WHERE start_ts >= timestamptz '2024-01-01 00:00';
DROP TABLE gen.ivr_stage, gen.ph, gen.ivr_c;

-- ================= Surveys =================
CREATE TABLE gen.srv AS
SELECT c.contact_id, c.agent_id, c.customer_id, c.channel_id, c.queue_id, c.reason_id, c.launch_id, c.first_contact_resolved AS fcr,
       c.transferred, c.queue_wait_sec, q.sl_threshold_sec,
       least(c.wrap_end_ts + (-ln(1 - random()) * CASE WHEN c.channel_id IN (3, 5) THEN 10800 ELSE 1800 END) * interval '1 sec',
             timestamptz '2026-10-31 23:59:00') AS survey_ts,
       4.25 + 0.9 * c.sentiment_score + 0.12 * t.skill_z - CASE WHEN c.first_contact_resolved THEN 0 ELSE .45 END
            - CASE WHEN c.transferred THEN .2 ELSE 0 END + pp.csat_adj - CASE WHEN ro.site_id = 3 THEN .1 ELSE 0 END
            + random_normal(0, .55) AS latent,
       random_normal(0, 1.2) AS n_nps, random_normal(0, .8) AS n_ces, random() AS r_th
FROM cc.contact c
JOIN cc.customer cu ON cu.customer_id = c.customer_id
JOIN gen.persona_param pp ON pp.persona_id = cu.persona_id
JOIN gen.agent_trait t ON t.agent_id = c.agent_id
JOIN gen.roster ro ON ro.agent_id = c.agent_id
JOIN cc.dim_queue q ON q.queue_id = c.queue_id
WHERE c.answered
  AND random() < (CASE c.channel_id WHEN 1 THEN .065 WHEN 4 THEN .06 WHEN 2 THEN .13 ELSE .05 END) * pp.survey_mult
                 * CASE WHEN c.sentiment_score < -0.4 THEN 1.3 ELSE 1 END;

INSERT INTO cc.survey_response
SELECT row_number() OVER (ORDER BY s.survey_ts), s.contact_id, s.agent_id, s.customer_id, s.survey_ts, gen.dk(s.survey_ts),
       v.csat, least(10, greatest(0, round(2.3 * s.latent - 1.1 + s.n_nps)))::smallint,
       least(7, greatest(1, round(5.6 + .8 * (s.latent - 4.25) - CASE WHEN s.transferred THEN .6 ELSE 0 END
                                  - CASE WHEN s.queue_wait_sec > s.sl_threshold_sec THEN .5 ELSE 0 END
                                  - CASE WHEN s.fcr THEN 0 ELSE .7 END + s.n_ces)))::smallint,
       CASE WHEN v.csat >= 4 THEN (ARRAY['Friendly, knowledgeable agent','Quick resolution','Easy process','Helpful follow-up'])[1 + floor(s.r_th * 4)::int]
            WHEN v.csat = 3 THEN CASE WHEN s.r_th < .5 THEN 'Okay experience' ELSE 'Took longer than expected' END
            WHEN s.launch_id = 7 THEN 'Unhappy with fees'
            WHEN s.queue_wait_sec > s.sl_threshold_sec * 2 THEN 'Long wait time'
            WHEN s.transferred THEN 'Too many transfers'
            WHEN NOT s.fcr THEN 'Issue not resolved'
            WHEN r.reason_group = 'Digital Access' THEN 'App / online banking problems'
            ELSE 'Agent could not help' END
FROM gen.srv s
JOIN cc.dim_contact_reason r USING (reason_id)
CROSS JOIN LATERAL (SELECT least(5, greatest(1, round(s.latent)))::smallint AS csat) v;
DROP TABLE gen.srv;

-- ================= Complaints =================
CREATE TABLE gen.cmp AS
-- complaint-reason contacts, escalations, and very unhappy survey responses
SELECT c.customer_id, c.contact_id, c.answered_ts AS opened_ts, ch.channel_name AS channel_received, c.reason_id, c.launch_id,
       c.queue_wait_sec > q.sl_threshold_sec AS long_wait
FROM cc.contact c JOIN cc.dim_contact_reason r USING (reason_id) JOIN cc.dim_channel ch USING (channel_id) JOIN cc.dim_queue q USING (queue_id)
WHERE c.answered AND c.customer_id IS NOT NULL AND (r.reason_group = 'Complaint' OR (c.escalated AND random() < .35))
UNION ALL
SELECT s.customer_id, s.contact_id, s.survey_ts, 'Survey Follow-up', c.reason_id, c.launch_id, c.queue_wait_sec > q.sl_threshold_sec
FROM cc.survey_response s JOIN cc.contact c USING (contact_id) JOIN cc.dim_queue q ON q.queue_id = c.queue_id
WHERE s.csat = 1 AND random() < .15;

-- complaints raised outside the contact center (branch, web, social, regulator)
INSERT INTO gen.cmp
SELECT CASE WHEN x.r1 < .3 THEN pr7.lo + floor(x.r2 * pr7.cnt)::int ELSE 1 + floor(x.r2 * 400000)::int END,
       NULL, o.opened_ts,
       (ARRAY['Branch','Web Form','Social Media','Regulator Referral'])[gen.pick(ARRAY[45,35,15,5]::numeric[], x.r3)],
       (ARRAY[36,37,38,7,18,23,29])[1 + floor(x.r4 * 7)::int],
       CASE WHEN o.opened_ts::date BETWEEN date '2025-03-10' AND date '2025-07-10' AND x.r5 < .4 THEN 7 END,
       false
FROM (SELECT random() r1, random() r2, random() r3, random() r4, random() r5, random() r6
      FROM generate_series(1, (SELECT (count(*) * 0.12)::int FROM gen.cmp))) x
CROSS JOIN (SELECT lo, cnt FROM gen.persona_range WHERE persona_id = 7) pr7
CROSS JOIN LATERAL (SELECT timestamptz '2024-01-01 08:00' + x.r6 * (timestamptz '2026-10-31 17:00' - timestamptz '2024-01-01 08:00') AS opened_ts) o;

INSERT INTO cc.complaint
SELECT row_number() OVER (ORDER BY z.opened_ts), z.customer_id, z.contact_id, z.opened_ts,
       CASE WHEN z.opened_ts + z.days * interval '1 day' <= timestamptz '2026-10-31 23:59' THEN z.opened_ts + z.days * interval '1 day' END,
       gen.dk(z.opened_ts),
       CASE WHEN z.opened_ts + z.days * interval '1 day' <= timestamptz '2026-10-31 23:59' THEN round(z.days::numeric, 1) END,
       z.channel_received, z.category, z.severity, z.regulatory_flag, z.root_cause, z.launch_id,
       CASE WHEN z.opened_ts + z.days * interval '1 day' <= timestamptz '2026-10-31 23:59' THEN 'Closed' ELSE 'Open' END
FROM (
  SELECT y.*, exp(ln(4) + 0.8 * random_normal()) * CASE y.severity WHEN 'High' THEN 2.2 WHEN 'Medium' THEN 1.3 ELSE 0.8 END AS days
  FROM (
    SELECT k.*, cat.category,
           CASE WHEN k.r1 < .10 + CASE WHEN cat.category = 'Fraud & Disputes' THEN .10 ELSE 0 END THEN 'High'
                WHEN k.r1 < .45 THEN 'Medium' ELSE 'Low' END AS severity,
           k.r2 < .04 + CASE cat.category WHEN 'Fraud & Disputes' THEN .06 WHEN 'Fees & Charges' THEN .03 ELSE 0 END AS regulatory_flag,
           CASE cat.category
             WHEN 'Fees & Charges'   THEN (ARRAY['Fee policy','Communication unclear'])[gen.pick(ARRAY[70,30]::numeric[], k.r3)]
             WHEN 'Digital Banking'  THEN (ARRAY['App / online defect','Communication unclear','Process error'])[gen.pick(ARRAY[65,20,15]::numeric[], k.r3)]
             WHEN 'Service Quality'  THEN CASE WHEN k.long_wait THEN 'Long wait / hard to reach'
                                               ELSE (ARRAY['Agent knowledge','Process error','Long wait / hard to reach'])[gen.pick(ARRAY[45,35,20]::numeric[], k.r3)] END
             WHEN 'Fraud & Disputes' THEN (ARRAY['Fraud handling','Policy limitation','Process error'])[gen.pick(ARRAY[50,30,20]::numeric[], k.r3)]
             ELSE (ARRAY['Process error','Policy limitation','Agent knowledge'])[gen.pick(ARRAY[40,30,30]::numeric[], k.r3)] END AS root_cause
    FROM (SELECT g.*, random() r1, random() r2, random() r3 FROM gen.cmp g) k
    JOIN cc.dim_contact_reason r ON r.reason_id = k.reason_id
    CROSS JOIN LATERAL (SELECT CASE
        WHEN k.reason_id IN (7, 36) OR k.launch_id = 7 THEN 'Fees & Charges'
        WHEN r.reason_group = 'Digital Access' OR k.reason_id = 38 THEN 'Digital Banking'
        WHEN r.reason_group = 'Card' THEN 'Cards & Payments'
        WHEN r.reason_group = 'Fraud/Dispute' THEN 'Fraud & Disputes'
        WHEN r.reason_group = 'Lending' THEN 'Lending'
        WHEN r.reason_group = 'Account Servicing' THEN 'Account Servicing'
        WHEN r.reason_group = 'Product Inquiry' THEN 'Account Opening'
        ELSE 'Service Quality' END AS category) cat
  ) y
) z;
DROP TABLE gen.cmp;

-- ================= Customer tenure consistency =================
UPDATE cc.customer cu SET customer_since = f.first_dt - (1 + floor(random() * 120))::int
FROM (SELECT customer_id, min(dt) AS first_dt FROM (
        SELECT customer_id, min(offered_ts)::date AS dt FROM cc.contact WHERE customer_id IS NOT NULL GROUP BY 1
        UNION ALL SELECT customer_id, min(start_ts)::date FROM cc.ivr_session WHERE customer_id IS NOT NULL GROUP BY 1
        UNION ALL SELECT customer_id, min(opened_ts)::date FROM cc.complaint GROUP BY 1) u GROUP BY 1) f
WHERE f.customer_id = cu.customer_id AND cu.customer_since >= f.first_dt;
UPDATE cc.customer SET digital_enrolled_date = customer_since WHERE digital_enrolled_date < customer_since;

-- ================= Customer products =================
CREATE TABLE gen.prod_prob AS
SELECT * FROM (VALUES
 (1, ARRAY[.92,.95,.70,.85,.85,.90,.92,.55]),(2, ARRAY[.02,.08,.10,.18,.15,.08,.00,.50]),(3, ARRAY[.45,.65,.40,.60,.65,.60,.40,.40]),
 (4, ARRAY[.05,.08,.10,.22,.30,.15,.03,.40]),(5, ARRAY[.02,.05,.15,.15,.25,.20,.01,.45]),(6, ARRAY[.01,.03,.05,.08,.25,.35,.01,.30]),
 (7, ARRAY[.00,.00,.02,.03,.10,.12,.00,.12]),(8, ARRAY[.00,.35,.05,.12,.03,.01,.03,.08]),(9, ARRAY[.90,.92,.65,.82,.80,.70,.90,.50]),
 (10,ARRAY[.25,.40,.30,.45,.35,.25,.10,.45]),(11,ARRAY[.15,.20,.08,.18,.06,.03,.04,.15]),(12,ARRAY[.05,.02,.01,.01,.01,.01,.45,.00]),
 (13,ARRAY[.00,.00,.15,.00,.00,.00,.00,.01]),(14,ARRAY[.10,.15,.08,.12,.08,.04,.20,.03]),(15,ARRAY[.12,.30,.15,.25,.15,.06,.15,.10]),
 (16,ARRAY[.00,.05,.08,.12,.15,.06,.00,.12]),(17,ARRAY[.02,.30,.25,.38,.30,.12,.02,.35]),(18,ARRAY[.00,.04,.04,.06,.05,.02,.00,.08]),
 (19,ARRAY[1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0]),(20,ARRAY[.95,.92,.75,.85,.60,.30,.85,.70]),(21,ARRAY[.55,.60,.50,.45,.30,.10,.45,.30]),
 (22,ARRAY[.55,.45,.15,.25,.10,.03,.35,.10]),(23,ARRAY[.70,.55,.45,.55,.40,.15,.50,.50]),(24,ARRAY[.00,.00,.95,.00,.00,.00,.00,.05]),
 (25,ARRAY[.00,.00,.40,.00,.00,.00,.00,.02]),(26,ARRAY[.00,.00,.25,.00,.00,.00,.00,.00]),(27,ARRAY[.00,.00,.30,.00,.00,.00,.00,.00]),
 (28,ARRAY[.30,.35,.10,.20,.15,.10,.45,.05])
) v(product_id, p);

CREATE TABLE gen.cp AS
SELECT cu.customer_id, cu.persona_id, cu.customer_since, cu.digital_enrolled_date, pr.product_id, pr.category, lp.launch_date,
       pr.is_new_in_period, r.r2, r.r3, r.r4, r.r5
FROM cc.customer cu
CROSS JOIN gen.prod_prob pp
JOIN cc.dim_product pr ON pr.product_id = pp.product_id
LEFT JOIN gen.launch_param lp ON lp.launch_id = pr.launch_id AND pr.is_new_in_period
CROSS JOIN LATERAL (SELECT random() r1, random() r2, random() r3, random() r4, random() r5) r
WHERE r.r1 < pp.p[cu.persona_id]
  AND (pp.product_id NOT IN (19, 20, 21, 22) OR cu.digital_enrolled);

INSERT INTO cc.customer_product
SELECT row_number() OVER (ORDER BY customer_id, product_id), customer_id, product_id, open_date, close_date,
       CASE WHEN close_date IS NOT NULL THEN 'Closed' WHEN r5 < .03 THEN 'Dormant' ELSE 'Active' END,
       CASE WHEN launch_id IS NOT NULL AND open_date BETWEEN launch_date2 AND launch_date2 + 90 THEN launch_id END
FROM (
  SELECT x.*,
    CASE
      -- fee change (10 Mar 2025) drives checking / overdraft closures among fee-sensitive personas
      WHEN x.product_id IN (1, 28) AND x.persona_id IN (1, 2, 7) AND x.open_date < date '2025-03-10' AND x.r4 < .12
        THEN least(date '2026-10-31', date '2025-03-10' + floor(-ln(1 - x.r3) * 45)::int)
      WHEN x.r4 > .93   -- ordinary attrition (~7%)
        THEN x.open_date + floor(x.r3 * (date '2026-10-31' - x.open_date))::int
    END AS close_date
  FROM (
    SELECT c.*,
      CASE WHEN c.product_id = 19 THEN c.digital_enrolled_date
           WHEN c.is_new_in_period THEN greatest(c.customer_since, c.launch_date + floor(-ln(1 - c.r2) * 120)::int)
           WHEN c.product_id = 2 AND c.persona_id IN (4, 8) AND c.r2 < .18
                THEN greatest(c.customer_since, date '2025-09-08' + floor(-ln(1 - c.r3) * 90)::int)
           ELSE c.customer_since + floor(c.r2 ^ 3 * (date '2026-10-31' - c.customer_since))::int END AS open_date,
      CASE WHEN c.is_new_in_period THEN (SELECT launch_id FROM cc.dim_product WHERE product_id = c.product_id)
           WHEN c.product_id = 2 THEN 10 END AS launch_id,
      CASE WHEN c.product_id = 2 THEN date '2025-09-08' ELSE c.launch_date END AS launch_date2
    FROM gen.cp c
  ) x
  WHERE x.open_date <= date '2026-10-31'
) y;
DROP TABLE gen.cp;
