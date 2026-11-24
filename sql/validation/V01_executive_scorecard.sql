-- Validation queries: Executive scorecard
-- The page defaults to the latest full month, October 2026.
-- Run one query at a time (select it, then run). Every query only reads data.
-- Filters: 'All' means no filter. Separate several values with ' | ', for example 'Phone | Chat'.
-- Names must match exactly, including capitals. See README.md in this folder.

-- ====================================================================================================
-- 1.1  Service level by channel group and queue
-- On the page: the four service level cards, and the queue bars when a card is selected
-- Expected with the values below (checked Nov 24, 2026): Phone 81.9, Chat 87.6, Email & secure message 95.6, Callback 89.5. The last column counts individual contacts and should agree.
-- ====================================================================================================
WITH settings AS (
  SELECT   -- <<< CHANGE THESE VALUES >>>
    DATE '2026-10-01'              AS start_date,              -- first day
    DATE '2026-10-31'              AS end_date,                -- last day (included)
    'All'::text                    AS channel,                 -- Phone, Chat, Email, Callback, Secure Message
    'All'::text                    AS queue                    -- e.g. Phone - Fraud & Disputes
),
iv AS (   -- what the page uses: the 15-minute summary
  SELECT v.queue_id, sum(v.answered_within_sl) AS within_sl, sum(v.answered + v.abandoned - v.short_abandoned) AS eligible
  FROM cc.interval_volume v JOIN cc.dim_date d ON d.date_key = v.date_key CROSS JOIN settings s
  WHERE d.full_date BETWEEN s.start_date AND s.end_date GROUP BY 1
),
ct AS (   -- independent count from individual contacts
  SELECT c.queue_id, count(*) FILTER (WHERE c.met_service_level) AS within_sl,
         count(*) FILTER (WHERE c.answered OR (c.abandoned AND NOT c.short_abandon)) AS eligible
  FROM cc.contact c JOIN cc.dim_date d ON d.date_key = c.date_key CROSS JOIN settings s
  WHERE d.full_date BETWEEN s.start_date AND s.end_date GROUP BY 1
),
x AS (
  SELECT CASE WHEN ch.channel_name IN ('Email', 'Secure Message') THEN 'Email & secure message' ELSE ch.channel_name END AS channel_group,
         q.queue_name, iv.eligible, iv.within_sl, ct.eligible AS eligible2, ct.within_sl AS within_sl2
  FROM iv JOIN cc.dim_queue q USING (queue_id) JOIN cc.dim_channel ch ON ch.channel_id = q.channel_id
  LEFT JOIN ct USING (queue_id) CROSS JOIN settings s
  WHERE true
    AND (s.channel = 'All' OR ch.channel_name = ANY (string_to_array(s.channel, ' | ')))
    AND (s.queue = 'All' OR q.queue_name = ANY (string_to_array(s.queue, ' | ')))
)
SELECT channel_group, coalesce(queue_name, '** Total **') AS queue, sum(eligible) AS eligible_contacts, sum(within_sl) AS within_threshold,
       round(100.0 * sum(within_sl) / nullif(sum(eligible), 0), 1) AS service_level_pct,
       round(100.0 * sum(within_sl2) / nullif(sum(eligible2), 0), 1) AS service_level_pct_from_contacts
FROM x
GROUP BY GROUPING SETS ((channel_group), (channel_group, queue_name))
ORDER BY channel_group, GROUPING(queue_name) DESC, queue;


-- ====================================================================================================
-- 1.2  Demand and speed KPIs
-- On the page: ASA, abandon rate, AHT, contacts offered, digital share and staffing cards
-- Expected with the values below (checked Nov 24, 2026): ASA 16 s, abandon 3.9, AHT 463 s (7m 43s), contacts offered about 189K, digital share 57.0, staffing +19.4
-- ====================================================================================================
WITH settings AS (
  SELECT   -- <<< CHANGE THESE VALUES >>>
    DATE '2026-10-01'              AS start_date,              -- first day
    DATE '2026-10-31'              AS end_date                 -- last day (included)
),
iv AS (
  SELECT v.*, q.channel_id   -- 1 Phone, 2 Chat, 3 Email, 4 Callback, 5 Secure Message
  FROM cc.interval_volume v JOIN cc.dim_date d ON d.date_key = v.date_key JOIN cc.dim_queue q ON q.queue_id = v.queue_id CROSS JOIN settings s
  WHERE d.full_date BETWEEN s.start_date AND s.end_date
)
SELECT round(sum(coalesce(asa_sec, 0) * answered) FILTER (WHERE channel_id = 1) / nullif(sum(answered) FILTER (WHERE channel_id = 1), 0), 0) AS asa_phone_sec,
       round(100.0 * sum(abandoned) FILTER (WHERE channel_id IN (1, 2)) / nullif(sum(offered) FILTER (WHERE channel_id IN (1, 2)), 0), 1) AS abandon_phone_chat_pct,
       round(sum(coalesce(actual_aht_sec, 0) * answered) FILTER (WHERE channel_id = 1) / nullif(sum(answered) FILTER (WHERE channel_id = 1), 0), 0) AS aht_phone_sec,
       sum(offered) AS contacts_offered,
       round(100.0 * sum(offered) FILTER (WHERE channel_id IN (2, 3, 5)) / nullif(sum(offered), 0), 1) AS digital_share_pct,
       round(100.0 * (sum(scheduled_fte) FILTER (WHERE channel_id IN (1, 2)) - sum(required_fte) FILTER (WHERE channel_id IN (1, 2)))
             / nullif(sum(required_fte) FILTER (WHERE channel_id IN (1, 2)), 0), 1) AS staffing_vs_required_pct
FROM iv;


-- ====================================================================================================
-- 1.3  First contact resolution, satisfaction and NPS by reason group
-- On the page: FCR, CSAT and NPS cards, and their contact reason bars
-- Expected with the values below (checked Nov 24, 2026): All shown: FCR 77.1, CSAT 83.4, NPS +36
-- ====================================================================================================
WITH settings AS (
  SELECT   -- <<< CHANGE THESE VALUES >>>
    DATE '2026-10-01'              AS start_date,              -- first day
    DATE '2026-10-31'              AS end_date,                -- last day (included)
    'All'::text                    AS reason_group             -- Account Servicing, Card, Fraud/Dispute, Digital Access, Lending, Product Inquiry, Complaint
),
ct AS (   -- contacts, by the day they were offered
  SELECT r.reason_group, count(*) FILTER (WHERE c.answered) AS answered,
         count(*) FILTER (WHERE c.answered AND c.first_contact_resolved) AS resolved
  FROM cc.contact c JOIN cc.dim_date d ON d.date_key = c.date_key JOIN cc.dim_contact_reason r ON r.reason_id = c.reason_id CROSS JOIN settings s
  WHERE d.full_date BETWEEN s.start_date AND s.end_date GROUP BY 1
),
sv AS (   -- surveys, by the day they were answered
  SELECT r.reason_group, count(*) AS surveys, count(*) FILTER (WHERE v.csat >= 4) AS satisfied,
         count(*) FILTER (WHERE v.nps >= 9) AS promoters, count(*) FILTER (WHERE v.nps <= 6) AS detractors
  FROM cc.survey_response v JOIN cc.dim_date d ON d.date_key = v.date_key JOIN cc.contact c ON c.contact_id = v.contact_id
  JOIN cc.dim_contact_reason r ON r.reason_id = c.reason_id CROSS JOIN settings s
  WHERE d.full_date BETWEEN s.start_date AND s.end_date GROUP BY 1
)
SELECT coalesce(ct.reason_group, '** All shown **') AS reason_group, sum(ct.answered) AS answered_contacts,
       round(100.0 * sum(resolved) / nullif(sum(ct.answered), 0), 1) AS fcr_pct, sum(surveys) AS surveys,
       round(100.0 * sum(satisfied) / nullif(sum(surveys), 0), 1) AS csat_pct,
       round(100.0 * (sum(promoters) - sum(detractors)) / nullif(sum(surveys), 0), 0) AS nps
FROM ct LEFT JOIN sv USING (reason_group) CROSS JOIN settings s
WHERE true
    AND (s.reason_group = 'All' OR ct.reason_group = ANY (string_to_array(s.reason_group, ' | ')))
GROUP BY ROLLUP (ct.reason_group)
ORDER BY GROUPING(ct.reason_group) DESC, 2 DESC;


-- ====================================================================================================
-- 1.4  Schedule adherence and occupancy by site
-- On the page: Schedule adherence and Occupancy cards, and their site bars
-- Expected with the values below (checked Nov 24, 2026): All shown: adherence 91.5, occupancy 70.9. Occupancy: Central Campus 69.5, Partner Site 71.5, Lakeside Center 72.3
-- ====================================================================================================
WITH settings AS (
  SELECT   -- <<< CHANGE THESE VALUES >>>
    DATE '2026-10-01'              AS start_date,              -- first day
    DATE '2026-10-31'              AS end_date,                -- last day (included)
    'All'::text                    AS site                     -- Central Campus, Lakeside Center, Partner Site (Outsourced)
)
SELECT coalesce(si.site_name, '** All shown **') AS site, count(*) AS agent_days,
       round(100.0 * sum(ad.in_adherence_min) / nullif(sum(ad.scheduled_min), 0), 1) AS adherence_pct,
       round(sum(ad.occupancy_pct * ad.available_min) / nullif(sum(ad.available_min), 0), 1) AS occupancy_pct
FROM cc.agent_daily ad
JOIN cc.dim_date d ON d.date_key = ad.date_key
JOIN cc.dim_agent a ON a.agent_id = ad.agent_id
JOIN cc.dim_team t ON t.team_id = a.team_id
JOIN cc.dim_site si ON si.site_id = t.site_id
CROSS JOIN settings s
WHERE d.full_date BETWEEN s.start_date AND s.end_date
    AND NOT ad.is_pto AND NOT ad.is_absent AND ad.scheduled_min > 0   -- days worked only
    AND (s.site = 'All' OR si.site_name = ANY (string_to_array(s.site, ' | ')))
GROUP BY ROLLUP (si.site_name)
ORDER BY GROUPING(si.site_name) DESC, 1;


-- ====================================================================================================
-- 1.5  Complaints per 1,000 contacts, and IVR containment
-- On the page: Complaints card with its category bars; IVR containment card (last column)
-- Expected with the values below (checked Nov 24, 2026): All shown: 47.6 per 1,000. IVR containment 41.9 (the same on every row)
-- ====================================================================================================
WITH settings AS (
  SELECT   -- <<< CHANGE THESE VALUES >>>
    DATE '2026-10-01'              AS start_date,              -- first day
    DATE '2026-10-31'              AS end_date,                -- last day (included)
    'All'::text                    AS category                 -- leave All to see every category name
),
ivr AS (
  SELECT round(100.0 * count(*) FILTER (WHERE i.contained) / nullif(count(*), 0), 1) AS ivr_containment_pct
  FROM cc.ivr_session i JOIN cc.dim_date d ON d.date_key = i.date_key CROSS JOIN settings s WHERE d.full_date BETWEEN s.start_date AND s.end_date
),
offered AS (
  SELECT sum(v.offered) AS n FROM cc.interval_volume v JOIN cc.dim_date d ON d.date_key = v.date_key CROSS JOIN settings s WHERE d.full_date BETWEEN s.start_date AND s.end_date
)
SELECT coalesce(cp.category, '** All shown **') AS category, count(*) AS complaints, max(o.n) AS contacts_offered,
       round(1000.0 * count(*) / nullif(max(o.n), 0), 1) AS complaints_per_1000, max(ivr.ivr_containment_pct) AS ivr_containment_pct
FROM cc.complaint cp JOIN cc.dim_date d ON d.date_key = cp.date_key CROSS JOIN settings s CROSS JOIN offered o CROSS JOIN ivr
WHERE d.full_date BETWEEN s.start_date AND s.end_date
    AND (s.category = 'All' OR cp.category = ANY (string_to_array(s.category, ' | ')))
GROUP BY ROLLUP (cp.category)
ORDER BY GROUPING(cp.category) DESC, 2 DESC;
