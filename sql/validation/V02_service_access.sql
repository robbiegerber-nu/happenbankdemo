-- Validation queries: Service & access operations
-- The page defaults to Phone and the 30 days ending on the last day of data (Oct 17 - Nov 15, 2026).
-- The page shows one channel at a time.
-- Run one query at a time (select it, then run). Every query only reads data.
-- Filters: 'All' means no filter. Separate several values with ' | ', for example 'Phone | Chat'.
-- Names must match exactly, including capitals. See README.md in this folder.

-- ====================================================================================================
-- 2.1  The six KPI tiles
-- On the page: tiles at the top
-- Expected with the values below (checked Nov 24, 2026): service level 83.6, ASA 15 s, abandon 3.2, offered about 71.6K, forecast error -4.0, staffing +14.9
-- ====================================================================================================
WITH settings AS (
  SELECT   -- <<< CHANGE THESE VALUES >>>
    DATE '2026-10-17'              AS start_date,              -- first day
    DATE '2026-11-15'              AS end_date,                -- last day (included)
    'Phone'::text                  AS channel,                 -- Phone, Chat, Email, Callback, Secure Message
    'All'::text                    AS queue,                   -- e.g. Phone - Fraud & Disputes
    'All'::text                    AS weekday                  -- Monday, Tuesday, ...
)
SELECT round(100.0 * sum(v.answered_within_sl) / nullif(sum(v.answered + v.abandoned - v.short_abandoned), 0), 1) AS service_level_pct,
       round(sum(coalesce(v.asa_sec, 0) * v.answered) / nullif(sum(v.answered), 0), 0) AS asa_sec,
       round(100.0 * sum(v.abandoned) / nullif(sum(v.offered), 0), 1) AS abandon_pct,
       sum(v.offered) AS offered,
       round(100.0 * (sum(v.offered) - sum(v.forecast_contacts)) / nullif(sum(v.forecast_contacts), 0), 1) AS forecast_error_pct,
       round(100.0 * (sum(v.scheduled_fte) - sum(v.required_fte)) / nullif(sum(v.required_fte), 0), 1) AS staffing_vs_required_pct
FROM cc.interval_volume v
JOIN cc.dim_date d ON d.date_key = v.date_key
JOIN cc.dim_queue q ON q.queue_id = v.queue_id
JOIN cc.dim_channel ch ON ch.channel_id = q.channel_id
CROSS JOIN settings s
WHERE d.full_date BETWEEN s.start_date AND s.end_date
    AND (s.channel = 'All' OR ch.channel_name = ANY (string_to_array(s.channel, ' | ')))
    AND (s.queue = 'All' OR q.queue_name = ANY (string_to_array(s.queue, ' | ')))
    AND (s.weekday = 'All' OR d.day_name = ANY (string_to_array(s.weekday, ' | ')));


-- ====================================================================================================
-- 2.2  Queue table, with days below target
-- On the page: the queue table
-- Expected with the values below (checked Nov 24, 2026): Phone - General Servicing: 83.9, 15 s, 3.2, 33,336 offered, staffing +31.0, 7 of 25 days below target
-- ====================================================================================================
WITH settings AS (
  SELECT   -- <<< CHANGE THESE VALUES >>>
    DATE '2026-10-17'              AS start_date,              -- first day
    DATE '2026-11-15'              AS end_date,                -- last day (included)
    'Phone'::text                  AS channel,                 -- Phone, Chat, Email, Callback, Secure Message
    'All'::text                    AS queue,                   -- e.g. Phone - Fraud & Disputes
    'All'::text                    AS weekday,                 -- Monday, Tuesday, ...
    80.0                           AS target_pct,              -- 80 phone and callback, 85 chat, 90 email and secure message
    50                             AS min_contacts             -- days with fewer rated contacts are not counted
),
daily AS (
  SELECT v.queue_id, d.full_date, 100.0 * sum(v.answered_within_sl) / nullif(sum(v.answered + v.abandoned - v.short_abandoned), 0) AS sl, sum(v.answered + v.abandoned - v.short_abandoned) AS eligible
  FROM cc.interval_volume v JOIN cc.dim_date d ON d.date_key = v.date_key CROSS JOIN settings s
  WHERE d.full_date BETWEEN s.start_date AND s.end_date
    AND (s.weekday = 'All' OR d.day_name = ANY (string_to_array(s.weekday, ' | ')))
  GROUP BY 1, 2
),
days AS (
  SELECT queue_id, count(*) FILTER (WHERE round(sl, 1) < s.target_pct) AS days_below_target, count(*) AS days_rated
  FROM daily CROSS JOIN settings s WHERE eligible >= s.min_contacts GROUP BY 1
)
SELECT q.queue_name, q.sl_threshold_sec, round(100.0 * sum(v.answered_within_sl) / nullif(sum(v.answered + v.abandoned - v.short_abandoned), 0), 1) AS service_level_pct,
       max(days.days_below_target) AS days_below_target, max(days.days_rated) AS days_rated,
       round(sum(coalesce(v.asa_sec, 0) * v.answered) / nullif(sum(v.answered), 0), 0) AS asa_sec,
       round(100.0 * sum(v.abandoned) / nullif(sum(v.offered), 0), 1) AS abandon_pct,
       sum(v.offered) AS offered,
       round(100.0 * (sum(v.offered) - sum(v.forecast_contacts)) / nullif(sum(v.forecast_contacts), 0), 1) AS forecast_error_pct,
       round(100.0 * (sum(v.scheduled_fte) - sum(v.required_fte)) / nullif(sum(v.required_fte), 0), 1) AS staffing_vs_required_pct
FROM cc.interval_volume v
JOIN cc.dim_date d ON d.date_key = v.date_key
JOIN cc.dim_queue q ON q.queue_id = v.queue_id
JOIN cc.dim_channel ch ON ch.channel_id = q.channel_id
CROSS JOIN settings s
LEFT JOIN days ON days.queue_id = q.queue_id
WHERE d.full_date BETWEEN s.start_date AND s.end_date
    AND (s.channel = 'All' OR ch.channel_name = ANY (string_to_array(s.channel, ' | ')))
    AND (s.queue = 'All' OR q.queue_name = ANY (string_to_array(s.queue, ' | ')))
    AND (s.weekday = 'All' OR d.day_name = ANY (string_to_array(s.weekday, ' | ')))
GROUP BY q.queue_name, q.sl_threshold_sec
ORDER BY offered DESC;


-- ====================================================================================================
-- 2.3  Worst day-and-time slots
-- On the page: the worst slots table
-- Expected with the values below (checked Nov 24, 2026): first row Tuesday 11:30: 171 past threshold, 1.5% share, service level 63.7, 26 s, abandon 6.7
-- ====================================================================================================
WITH settings AS (
  SELECT   -- <<< CHANGE THESE VALUES >>>
    DATE '2026-10-17'              AS start_date,              -- first day
    DATE '2026-11-15'              AS end_date,                -- last day (included)
    'Phone'::text                  AS channel,                 -- Phone, Chat, Email, Callback, Secure Message
    'All'::text                    AS queue,                   -- e.g. Phone - Fraud & Disputes
    'All'::text                    AS weekday                  -- Monday, Tuesday, ...
)
SELECT d.day_name AS weekday, ti.interval_start AS starts_at, sum(v.answered + v.abandoned - v.short_abandoned - v.answered_within_sl) AS past_threshold,
       round(100.0 * sum(v.answered + v.abandoned - v.short_abandoned - v.answered_within_sl) / nullif(sum(sum(v.answered + v.abandoned - v.short_abandoned - v.answered_within_sl)) OVER (), 0), 1) AS share_of_all_pct,
       round(100.0 * sum(v.answered_within_sl) / nullif(sum(v.answered + v.abandoned - v.short_abandoned), 0), 1) AS service_level_pct,
       round(sum(coalesce(v.asa_sec, 0) * v.answered) / nullif(sum(v.answered), 0), 0) AS asa_sec,
       round(100.0 * sum(v.abandoned) / nullif(sum(v.offered), 0), 1) AS abandon_pct,
       sum(v.offered) AS offered,
       round(100.0 * (sum(v.offered) - sum(v.forecast_contacts)) / nullif(sum(v.forecast_contacts), 0), 1) AS forecast_error_pct,
       round(100.0 * (sum(v.scheduled_fte) - sum(v.required_fte)) / nullif(sum(v.required_fte), 0), 1) AS staffing_vs_required_pct
FROM cc.interval_volume v
JOIN cc.dim_date d ON d.date_key = v.date_key
JOIN cc.dim_queue q ON q.queue_id = v.queue_id
JOIN cc.dim_channel ch ON ch.channel_id = q.channel_id
CROSS JOIN settings s
JOIN cc.dim_time_interval ti ON ti.interval_id = v.interval_id
WHERE d.full_date BETWEEN s.start_date AND s.end_date
    AND (s.channel = 'All' OR ch.channel_name = ANY (string_to_array(s.channel, ' | ')))
    AND (s.queue = 'All' OR q.queue_name = ANY (string_to_array(s.queue, ' | ')))
    AND (s.weekday = 'All' OR d.day_name = ANY (string_to_array(s.weekday, ' | ')))
GROUP BY 1, 2
ORDER BY past_threshold DESC
LIMIT 20;


-- ====================================================================================================
-- 2.4  Day by day
-- On the page: the daily chart, and the "days within 10%" line on the Forecast error tile
-- Expected with the values below (checked Nov 24, 2026): 25 open days, 23 of them within 10% of forecast (last column)
-- ====================================================================================================
WITH settings AS (
  SELECT   -- <<< CHANGE THESE VALUES >>>
    DATE '2026-10-17'              AS start_date,              -- first day
    DATE '2026-11-15'              AS end_date,                -- last day (included)
    'Phone'::text                  AS channel,                 -- Phone, Chat, Email, Callback, Secure Message
    'All'::text                    AS queue,                   -- e.g. Phone - Fraud & Disputes
    'All'::text                    AS weekday                  -- Monday, Tuesday, ...
)
SELECT d.full_date, d.day_name, round(100.0 * sum(v.answered_within_sl) / nullif(sum(v.answered + v.abandoned - v.short_abandoned), 0), 1) AS service_level_pct,
       round(sum(coalesce(v.asa_sec, 0) * v.answered) / nullif(sum(v.answered), 0), 0) AS asa_sec,
       round(100.0 * sum(v.abandoned) / nullif(sum(v.offered), 0), 1) AS abandon_pct,
       sum(v.offered) AS offered,
       round(100.0 * (sum(v.offered) - sum(v.forecast_contacts)) / nullif(sum(v.forecast_contacts), 0), 1) AS forecast_error_pct,
       round(100.0 * (sum(v.scheduled_fte) - sum(v.required_fte)) / nullif(sum(v.required_fte), 0), 1) AS staffing_vs_required_pct,
       sum((abs(round(100.0 * (sum(v.offered) - sum(v.forecast_contacts)) / nullif(sum(v.forecast_contacts), 0), 1)) <= 10)::int) OVER () AS days_within_10_pct_of_forecast
FROM cc.interval_volume v
JOIN cc.dim_date d ON d.date_key = v.date_key
JOIN cc.dim_queue q ON q.queue_id = v.queue_id
JOIN cc.dim_channel ch ON ch.channel_id = q.channel_id
CROSS JOIN settings s
WHERE d.full_date BETWEEN s.start_date AND s.end_date
    AND (s.channel = 'All' OR ch.channel_name = ANY (string_to_array(s.channel, ' | ')))
    AND (s.queue = 'All' OR q.queue_name = ANY (string_to_array(s.queue, ' | ')))
    AND (s.weekday = 'All' OR d.day_name = ANY (string_to_array(s.weekday, ' | ')))
GROUP BY 1, 2
ORDER BY 1;


-- ====================================================================================================
-- 2.5  Independent check: the same counts from individual contacts
-- On the page: not shown; the difference columns should be 0
-- Expected with the values below (checked Nov 24, 2026): every count difference 0; ASA difference 0 to within rounding (0.05 s)
-- ====================================================================================================
WITH settings AS (
  SELECT   -- <<< CHANGE THESE VALUES >>>
    DATE '2026-10-17'              AS start_date,              -- first day
    DATE '2026-11-15'              AS end_date,                -- last day (included)
    'Phone'::text                  AS channel,                 -- Phone, Chat, Email, Callback, Secure Message
    'All'::text                    AS queue,                   -- e.g. Phone - Fraud & Disputes
    'All'::text                    AS weekday                  -- Monday, Tuesday, ...
),
iv AS (
  SELECT q.queue_name, sum(v.offered) AS offered, sum(v.answered) AS answered, sum(v.abandoned) AS abandoned, sum(v.answered_within_sl) AS within_sl,
         sum(coalesce(v.asa_sec, 0) * v.answered) AS wait_sec
  FROM cc.interval_volume v
JOIN cc.dim_date d ON d.date_key = v.date_key
JOIN cc.dim_queue q ON q.queue_id = v.queue_id
JOIN cc.dim_channel ch ON ch.channel_id = q.channel_id
CROSS JOIN settings s
  WHERE d.full_date BETWEEN s.start_date AND s.end_date
    AND (s.channel = 'All' OR ch.channel_name = ANY (string_to_array(s.channel, ' | ')))
    AND (s.queue = 'All' OR q.queue_name = ANY (string_to_array(s.queue, ' | ')))
    AND (s.weekday = 'All' OR d.day_name = ANY (string_to_array(s.weekday, ' | ')))
  GROUP BY 1
),
ct AS (
  SELECT q.queue_name, count(*) AS offered, count(*) FILTER (WHERE c.answered) AS answered, count(*) FILTER (WHERE c.abandoned) AS abandoned,
         count(*) FILTER (WHERE c.met_service_level) AS within_sl, sum(c.queue_wait_sec) FILTER (WHERE c.answered) AS wait_sec
  FROM cc.contact c JOIN cc.dim_date d ON d.date_key = c.date_key
  JOIN cc.dim_queue q ON q.queue_id = c.queue_id JOIN cc.dim_channel ch ON ch.channel_id = q.channel_id CROSS JOIN settings s
  WHERE d.full_date BETWEEN s.start_date AND s.end_date
    AND (s.channel = 'All' OR ch.channel_name = ANY (string_to_array(s.channel, ' | ')))
    AND (s.queue = 'All' OR q.queue_name = ANY (string_to_array(s.queue, ' | ')))
    AND (s.weekday = 'All' OR d.day_name = ANY (string_to_array(s.weekday, ' | ')))
  GROUP BY 1
)
SELECT queue_name, ct.offered AS contacts, iv.offered - ct.offered AS offered_difference, iv.answered - ct.answered AS answered_difference,
       iv.abandoned - ct.abandoned AS abandoned_difference, iv.within_sl - ct.within_sl AS within_threshold_difference,
       round(iv.wait_sec / nullif(iv.answered, 0) - ct.wait_sec::numeric / nullif(ct.answered, 0), 2) AS asa_difference_sec
FROM iv FULL JOIN ct USING (queue_name)
ORDER BY 1;
