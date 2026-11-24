-- Validation queries: Self-service & channel shift
-- The page defaults to October 2026, compared with October 2025.
-- Run one query at a time (select it, then run). Every query only reads data.
-- Filters: 'All' means no filter. Separate several values with ' | ', for example 'Phone | Chat'.
-- Names must match exactly, including capitals. See README.md in this folder.

-- ====================================================================================================
-- 8.1  Containment, requests without an agent, digital share, phone contacts
-- On the page: the first four tiles
-- Expected with the values below (checked Nov 24, 2026): containment 41.9, without an agent 23.2, digital share 57.0, phone contacts 79,335
-- ====================================================================================================
WITH settings AS (
  SELECT   -- <<< CHANGE THESE VALUES >>>
    DATE '2026-10-01'              AS start_date,              -- first day
    DATE '2026-10-31'              AS end_date,                -- last day (included)
    'All'::text                    AS persona                  -- e.g. Credit Builder, Retiree Traditionalist
),
ivr AS (
  SELECT count(*) AS sessions, count(*) FILTER (WHERE i.contained) AS contained
  FROM cc.ivr_session i JOIN cc.dim_date d ON d.date_key = i.date_key LEFT JOIN cc.customer cu ON cu.customer_id = i.customer_id LEFT JOIN cc.dim_persona p ON p.persona_id = cu.persona_id CROSS JOIN settings s WHERE d.full_date BETWEEN s.start_date AND s.end_date
    AND (s.persona = 'All' OR p.persona_name = ANY (string_to_array(s.persona, ' | ')))
),
ct AS (
  SELECT count(*) AS contacts, count(*) FILTER (WHERE c.channel_id IN (2, 3, 5)) AS digital, count(*) FILTER (WHERE c.channel_id = 1) AS phone
  FROM cc.contact c JOIN cc.dim_date d ON d.date_key = c.date_key LEFT JOIN cc.customer cu ON cu.customer_id = c.customer_id LEFT JOIN cc.dim_persona p ON p.persona_id = cu.persona_id CROSS JOIN settings s WHERE d.full_date BETWEEN s.start_date AND s.end_date
    AND (s.persona = 'All' OR p.persona_name = ANY (string_to_array(s.persona, ' | ')))
)
SELECT sessions, contained, round(100.0 * contained / nullif(sessions, 0), 1) AS containment_pct,
       round(100.0 * contained / nullif(contained + contacts, 0), 1) AS without_agent_pct,
       round(100.0 * digital / nullif(contacts, 0), 1) AS digital_share_pct, phone AS phone_contacts
FROM ivr, ct;


-- ====================================================================================================
-- 8.2  How requests are handled
-- On the page: the "How it was handled" table
-- Expected with the values below (checked Nov 24, 2026): menu 57,106 (23.2%), Phone 79,335 (32.3%), Chat 89,202 (36.3%), Email 13,665, Secure Message 4,616, Callback 1,773
-- ====================================================================================================
WITH settings AS (
  SELECT   -- <<< CHANGE THESE VALUES >>>
    DATE '2026-10-01'              AS start_date,              -- first day
    DATE '2026-10-31'              AS end_date,                -- last day (included)
    'All'::text                    AS persona                  -- e.g. Credit Builder, Retiree Traditionalist
),
x AS (
  SELECT 'Finished in the phone menu' AS handled, count(*) AS requests
  FROM cc.ivr_session i JOIN cc.dim_date d ON d.date_key = i.date_key LEFT JOIN cc.customer cu ON cu.customer_id = i.customer_id LEFT JOIN cc.dim_persona p ON p.persona_id = cu.persona_id CROSS JOIN settings s WHERE d.full_date BETWEEN s.start_date AND s.end_date AND i.contained
    AND (s.persona = 'All' OR p.persona_name = ANY (string_to_array(s.persona, ' | ')))
  UNION ALL
  SELECT ch.channel_name, count(*)
  FROM cc.contact c JOIN cc.dim_date d ON d.date_key = c.date_key JOIN cc.dim_channel ch ON ch.channel_id = c.channel_id LEFT JOIN cc.customer cu ON cu.customer_id = c.customer_id LEFT JOIN cc.dim_persona p ON p.persona_id = cu.persona_id CROSS JOIN settings s WHERE d.full_date BETWEEN s.start_date AND s.end_date
    AND (s.persona = 'All' OR p.persona_name = ANY (string_to_array(s.persona, ' | ')))
  GROUP BY 1
)
SELECT handled, requests, round(100.0 * requests / sum(requests) OVER (), 1) AS share_pct, sum(requests) OVER () AS all_requests
FROM x
ORDER BY requests DESC;


-- ====================================================================================================
-- 8.3  A channel's share of contacts by reason, now and before
-- On the page: the "Where phone's share moved" table
-- Expected with the values below (checked Nov 24, 2026): total row: 46.5 before, 42.1 now. Balance & Transaction Inquiry: 16,978 contacts, 45.5 before, 40.6 now
-- ====================================================================================================
WITH settings AS (
  SELECT   -- <<< CHANGE THESE VALUES >>>
    DATE '2026-10-01'              AS start_date,              -- first day
    DATE '2026-10-31'              AS end_date,                -- last day (included)
    DATE '2025-10-01'              AS compare_start,           -- first day of the comparison period
    DATE '2025-10-31'              AS compare_end,             -- last day of it
    'Phone'::text                  AS channel,                 -- Phone, Chat, Email, Callback, Secure Message
    'All'::text                    AS reason,                  -- e.g. Card Activation
    'All'::text                    AS persona                  -- e.g. Credit Builder, Retiree Traditionalist
)
SELECT coalesce(r.reason, '** Total **') AS reason, count(*) FILTER (WHERE d.full_date BETWEEN s.start_date AND s.end_date) AS contacts_now,
       round(100.0 * count(*) FILTER (WHERE d.full_date BETWEEN s.compare_start AND s.compare_end AND ch.channel_name = s.channel)
             / nullif(count(*) FILTER (WHERE d.full_date BETWEEN s.compare_start AND s.compare_end), 0), 1) AS channel_share_before_pct,
       round(100.0 * count(*) FILTER (WHERE d.full_date BETWEEN s.start_date AND s.end_date AND ch.channel_name = s.channel) / nullif(count(*) FILTER (WHERE d.full_date BETWEEN s.start_date AND s.end_date), 0), 1) AS channel_share_now_pct
FROM cc.contact c JOIN cc.dim_date d ON d.date_key = c.date_key JOIN cc.dim_channel ch ON ch.channel_id = c.channel_id JOIN cc.dim_contact_reason r ON r.reason_id = c.reason_id
LEFT JOIN cc.customer cu ON cu.customer_id = c.customer_id LEFT JOIN cc.dim_persona p ON p.persona_id = cu.persona_id CROSS JOIN settings s
WHERE (d.full_date BETWEEN s.start_date AND s.end_date OR d.full_date BETWEEN s.compare_start AND s.compare_end)
    AND (s.reason = 'All' OR r.reason = ANY (string_to_array(s.reason, ' | ')))
    AND (s.persona = 'All' OR p.persona_name = ANY (string_to_array(s.persona, ' | ')))
GROUP BY ROLLUP (r.reason)
ORDER BY GROUPING(r.reason) DESC, 2 DESC;


-- ====================================================================================================
-- 8.4  Menu tasks, and agent hours avoided
-- On the page: the menu task table and the "Agent hours avoided" tile (last column)
-- Expected with the values below (checked Nov 24, 2026): Balance & Transaction Inquiry: 27,380 finished, 6,885 phone contacts, 79.9. Agent hours avoided about 5.32K
-- ====================================================================================================
WITH settings AS (
  SELECT   -- <<< CHANGE THESE VALUES >>>
    DATE '2026-10-01'              AS start_date,              -- first day
    DATE '2026-10-31'              AS end_date,                -- last day (included)
    'All'::text                    AS persona                  -- e.g. Credit Builder, Retiree Traditionalist
),
map AS (   -- menu task -> the contact reason an agent would record for the same need (the page's own mapping)
  SELECT * FROM (VALUES ('Balance Inquiry', 'Balance & Transaction Inquiry'), ('Recent Transactions', 'Balance & Transaction Inquiry'),
    ('Card Activation', 'Card Activation'), ('Confirm Fraud Alert', 'Fraud Alert Verification'), ('Payment Due Date', 'Loan Payment Question'),
    ('Make a Loan Payment', 'Loan Payment Question'), ('Report Lost Card', 'Lost or Stolen Card')) m(task, reason)
),
done AS (
  SELECT coalesce(m.reason, i.self_service_task) AS need, bool_or(m.reason IS NOT NULL) AS matched, string_agg(DISTINCT i.self_service_task, ' + ') AS tasks, count(*) AS finished
  FROM cc.ivr_session i JOIN cc.dim_date d ON d.date_key = i.date_key LEFT JOIN map m ON m.task = i.self_service_task LEFT JOIN cc.customer cu ON cu.customer_id = i.customer_id LEFT JOIN cc.dim_persona p ON p.persona_id = cu.persona_id CROSS JOIN settings s
  WHERE d.full_date BETWEEN s.start_date AND s.end_date AND i.contained
    AND (s.persona = 'All' OR p.persona_name = ANY (string_to_array(s.persona, ' | ')))
  GROUP BY 1
),
ph AS (
  SELECT r.reason, count(*) AS phone, sum(c.handle_sec) FILTER (WHERE c.answered)::numeric / nullif(count(*) FILTER (WHERE c.answered), 0) AS aht
  FROM cc.contact c JOIN cc.dim_date d ON d.date_key = c.date_key JOIN cc.dim_contact_reason r ON r.reason_id = c.reason_id LEFT JOIN cc.customer cu ON cu.customer_id = c.customer_id LEFT JOIN cc.dim_persona p ON p.persona_id = cu.persona_id CROSS JOIN settings s
  WHERE d.full_date BETWEEN s.start_date AND s.end_date AND c.channel_id = 1
    AND (s.persona = 'All' OR p.persona_name = ANY (string_to_array(s.persona, ' | ')))
  GROUP BY 1
)
SELECT tasks, CASE WHEN matched THEN need END AS contact_reason, finished, CASE WHEN matched THEN phone END AS phone_contacts_same_need,
       CASE WHEN matched THEN round(100.0 * finished / nullif(finished + phone, 0), 1) END AS finished_in_menu_pct,
       CASE WHEN matched THEN round(finished * aht / 3600, 0) END AS hours_avoided,
       round(sum(CASE WHEN matched THEN finished * aht / 3600 END) OVER (), 0) AS total_hours_avoided
FROM done LEFT JOIN ph ON ph.reason = done.need
ORDER BY finished DESC;


-- ====================================================================================================
-- 8.5  Menu users who contacted afterwards
-- On the page: the "Menu users who contacted within 7 days" tile and the last columns of the task table
-- Expected with the values below (checked Nov 24, 2026): all: 9.1 within 7 days, 9.0 in the 7 days before. Card Activation: 1.4 within 1 day, 9.8 within 7 days, 8.9 before
-- ====================================================================================================
WITH settings AS (
  SELECT   -- <<< CHANGE THESE VALUES >>>
    DATE '2026-10-01'              AS start_date,              -- first day
    DATE '2026-10-31'              AS end_date,                -- last day (included)
    'All'::text                    AS task,                    -- e.g. Card Activation, Balance Inquiry
    'All'::text                    AS persona                  -- e.g. Credit Builder, Retiree Traditionalist
),
last_day AS (SELECT max(d.full_date) AS d FROM cc.contact c JOIN cc.dim_date d ON d.date_key = c.date_key),
ses AS (   -- finished menu sessions of identified customers, without the last 7 days of data
  SELECT i.session_id, i.self_service_task, i.customer_id, i.end_ts
  FROM cc.ivr_session i JOIN cc.dim_date d ON d.date_key = i.date_key LEFT JOIN cc.customer cu ON cu.customer_id = i.customer_id LEFT JOIN cc.dim_persona p ON p.persona_id = cu.persona_id CROSS JOIN settings s CROSS JOIN last_day
  WHERE d.full_date BETWEEN s.start_date AND s.end_date AND i.contained AND i.customer_id IS NOT NULL
    AND i.end_ts < (last_day.d + 1 - 7)::timestamp AT TIME ZONE 'America/Chicago'
    AND i.end_ts >= TIMESTAMP '2024-01-08' AT TIME ZONE 'America/Chicago'
    AND (s.task = 'All' OR i.self_service_task = ANY (string_to_array(s.task, ' | ')))
    AND (s.persona = 'All' OR p.persona_name = ANY (string_to_array(s.persona, ' | ')))
),
x AS (
  SELECT ses.session_id, ses.self_service_task,
         bool_or(c.offered_ts < ses.end_ts) AS before7,
         bool_or(c.offered_ts >= ses.end_ts AND c.offered_ts <= ses.end_ts + interval '1 day') AS after1,
         bool_or(c.offered_ts >= ses.end_ts) AS after7
  FROM ses LEFT JOIN cc.contact c ON c.customer_id = ses.customer_id AND c.offered_ts BETWEEN ses.end_ts - interval '7 days' AND ses.end_ts + interval '7 days'
  GROUP BY 1, 2
)
SELECT coalesce(self_service_task, '** All shown **') AS task, count(*) AS sessions_of_identified_customers,
       round(100.0 * count(*) FILTER (WHERE after1) / count(*), 1) AS contacted_within_1_day_pct,
       round(100.0 * count(*) FILTER (WHERE after7) / count(*), 1) AS contacted_within_7_days_pct,
       round(100.0 * count(*) FILTER (WHERE before7) / count(*), 1) AS contacted_7_days_before_pct
FROM x
GROUP BY ROLLUP (self_service_task)
ORDER BY GROUPING(self_service_task) DESC, 2 DESC;
