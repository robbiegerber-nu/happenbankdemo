-- Customer product holdings (open / close dates, launch-driven openings, fee-change closures).
-- Self-contained: uses only cc tables, so it can be regenerated on its own.
-- Fixed after discovery run 3: random numbers were drawn in an uncorrelated LATERAL subquery, which PostgreSQL
-- evaluates ONCE, so every customer x product pair got the same "random" values (identical holdings per persona,
-- openings on a handful of dates, no closures). The draws now reference the outer row.
\set ON_ERROR_STOP on
SET client_min_messages = warning;
SET max_parallel_workers_per_gather = 0;
SET work_mem = '1GB';
SELECT setseed(0.471);
TRUNCATE cc.customer_product;

-- Probability that a customer of each persona (1..8) holds each product
CREATE TEMP TABLE prod_prob AS
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

CREATE TEMP TABLE cp AS
SELECT cu.customer_id, cu.persona_id, cu.customer_since, cu.digital_enrolled_date, pr.product_id, pr.is_new_in_period,
       pl.launch_id, pl.launch_date, r.r2, r.r3, r.r4, r.r5
FROM cc.customer cu
CROSS JOIN prod_prob pp
JOIN cc.dim_product pr ON pr.product_id = pp.product_id
LEFT JOIN cc.product_launch pl ON pl.launch_id = pr.launch_id AND pr.is_new_in_period
-- correlated (references the outer row), so the draws are fresh for every customer x product pair
CROSS JOIN LATERAL (SELECT random() r1, random() r2, random() r3, random() r4, random() r5
                    WHERE cu.customer_id IS NOT NULL AND pp.product_id IS NOT NULL) r
WHERE r.r1 < pp.p[cu.persona_id]
  AND (pp.product_id NOT IN (19, 20, 21, 22) OR cu.digital_enrolled);

INSERT INTO cc.customer_product
SELECT row_number() OVER (ORDER BY customer_id, product_id), customer_id, product_id, open_date, close_date,
       CASE WHEN close_date IS NOT NULL THEN 'Closed' WHEN r5 < .03 THEN 'Dormant' ELSE 'Active' END,
       CASE WHEN launch_id2 IS NOT NULL AND open_date BETWEEN launch_date2 AND launch_date2 + 90 THEN launch_id2 END
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
      CASE WHEN c.is_new_in_period THEN c.launch_id WHEN c.product_id = 2 THEN 10 END AS launch_id2,
      CASE WHEN c.product_id = 2 THEN date '2025-09-08' ELSE c.launch_date END AS launch_date2
    FROM cp c
  ) x
  WHERE x.open_date <= date '2026-10-31'
) y;
VACUUM ANALYZE cc.customer_product;
