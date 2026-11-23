-- Rule refinements (v3.2): every Warning or Failure should mean "something new needs recording".
-- Applied after D02_rules.sql (which keeps each rule's original definition) and D05/D06. Re-running is safe.
--
--   Status meaning   Fail = records are wrong or missing; numbers built on them would be wrong (incident + alert)
--                    Warn = unusual, possibly legitimate; a person records a decision (explained or accepted)
--                    Pass = nothing new to record
--
--   1. History anomalies (VOL-011..014, UNQ-012) count only findings nobody has explained or reviewed
--   2. Rate checks (CMP-005, CMP-017, VAL-006, VAL-007) measure the latest day, not three years at once
--   3. Minimum-row checks (VOL-001, 002, 004-007, 009, 010) become "the latest day's rows are normal"
--   4. Freshness checks (TML-001..008) count OPEN days with no data, so one missing day is caught
--   5. Low-importance detail checks warn on any finding and fail only at a meaningful volume
--   6. New CMP-019: fields that stopped being filled in on the latest day
--   7. New CON-018: scheduled staff in the 15-minute summary must match the agents' schedules (v3.4, after remediation R02)
\set ON_ERROR_STOP on
SET client_min_messages = warning;

-- ---------- Explanations: why a day's volume can be unusual and still be right ----------
-- Direction matters: a holiday explains LOWER volume on the day or the day before, and HIGHER volume (catch-up) in the
-- three days after; a product launch explains HIGHER volume for two weeks; a known event explains either. No explanation
-- covers a day that lost 60% or more of its records, or doubled: those look like missing or duplicated files.
CREATE OR REPLACE FUNCTION discovery.volume_explanation(p_day date, p_ratio numeric) RETURNS text LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN p_ratio IS NULL OR p_ratio < 0.4 OR p_ratio >= 2 THEN NULL ELSE coalesce(
    (SELECT CASE WHEN full_date = p_day THEN holiday_name ELSE 'Day before ' || holiday_name END
       FROM cc.dim_date WHERE is_holiday AND p_ratio < 1 AND full_date BETWEEN p_day AND p_day + 1 ORDER BY full_date LIMIT 1),
    (SELECT 'Catch-up after ' || holiday_name
       FROM cc.dim_date WHERE is_holiday AND p_ratio > 1 AND full_date BETWEEN p_day - 3 AND p_day - 1 ORDER BY full_date DESC LIMIT 1),
    (SELECT title FROM discovery.dq_event WHERE kind <> 'Data' AND p_day BETWEEN start_date AND end_date ORDER BY start_date DESC LIMIT 1),
    (SELECT launch_name || ' launch' FROM cc.product_launch WHERE p_ratio > 1 AND p_day BETWEEN launch_date AND launch_date + 13
       ORDER BY launch_date DESC LIMIT 1)) END
$$;

-- ---------- Reviewed findings (accepted by a person, with the reason) ----------
INSERT INTO discovery.dq_reviewed_finding (rule_id, item_key, reason, reviewed_on) VALUES
 ('UNQ-012', '6554',       'Two contacts from the same customer in the same second on 2 Jan 2024. Reviewed in run #1: a coincidence, not a double load.', '2026-11-23'),
 ('VOL-014', '2025-03-05', 'Complaints rose in the run-up to the fee schedule change on 10 Mar 2025, after it was announced.', '2026-11-23'),
 ('VOL-014', '2025-04-09', 'Not a real drop: the March fee-change surge raised the four-week normal, so typical days look low.', '2026-11-23'),
 ('VOL-014', '2025-04-10', 'Not a real drop: the March fee-change surge raised the four-week normal, so typical days look low.', '2026-11-23'),
 ('VOL-014', '2025-04-11', 'Not a real drop: the March fee-change surge raised the four-week normal, so typical days look low.', '2026-11-23'),
 ('VOL-014', '2026-02-24', 'The tail of the mobile app re-platform (9 Feb 2026): complaints were still elevated.', '2026-11-23'),
 ('VOL-014', '2026-02-25', 'The tail of the mobile app re-platform (9 Feb 2026): complaints were still elevated.', '2026-11-23')
ON CONFLICT (rule_id, item_key) DO UPDATE SET reason = EXCLUDED.reason;

-- ---------- 1. History anomalies: only unexplained, unreviewed findings count ----------
UPDATE discovery.dq_rule r SET
  rule_name = v.name,
  description = v.what || ' Days explained by a holiday, known event or product launch, or reviewed by a person, are listed but don''t count.',
  check_sql = format($q$SELECT count(*) FROM discovery.dq_daily_volume v WHERE v.run_id = {run_id} AND v.table_name = %L AND v.is_outlier
    AND discovery.volume_explanation(v.day, v.ratio) IS NULL
    AND NOT EXISTS (SELECT 1 FROM discovery.dq_reviewed_finding f WHERE f.rule_id = %L AND f.item_key = v.day::text)$q$, v.tbl, v.id),
  evidence_sql = format($q$SELECT jsonb_agg(jsonb_build_object('item', to_char(day, 'Dy Mon DD, YYYY'), 'records', row_count,
      'detail', CASE WHEN ratio >= 1 THEN round((ratio - 1) * 100) || '%% above normal' ELSE round((1 - ratio) * 100) || '%% below normal' END
                || ' (' || to_char(row_count, 'FM999,999') || ' %s vs about ' || to_char(round(baseline), 'FM999,999') || ')'
                || coalesce(' · explained: ' || why, ' · reviewed: ' || reviewed, ' · not explained'),
      'explained', coalesce(why, reviewed)) ORDER BY day DESC)
    FROM (SELECT v.*, discovery.volume_explanation(v.day, v.ratio) AS why,
                 (SELECT f.reason FROM discovery.dq_reviewed_finding f WHERE f.rule_id = %L AND f.item_key = v.day::text) AS reviewed
          FROM discovery.dq_daily_volume v WHERE v.run_id = {run_id} AND v.table_name = %L AND v.is_outlier) x$q$, v.what_n, v.id, v.tbl),
  evidence_always = true, warn_above = 0, fail_above = 5,
  expected_note = 'Refined in v3.2: counts only unusual days with no explanation or review, so a warning always means a new day to look at.'
FROM (VALUES
  ('VOL-011', 'contact',          'contacts',   'Unexplained unusual contact volume days',   'Open days whose contact count is more than 35% above or below the same weekday''s recent median.'),
  ('VOL-012', 'ivr_session',      'calls',      'Unexplained unusual IVR volume days',       'Open days whose phone-menu (IVR) call count is more than 35% above or below the same weekday''s recent median.'),
  ('VOL-013', 'agents_logged_in', 'agents',     'Unexplained unusual number of agents logged in', 'Open days where the number of agents who logged in is more than 35% above or below the same weekday''s recent median.'),
  ('VOL-014', 'complaint',        'complaints', 'Unexplained unusual complaint volume days', 'Open days whose complaint count is more than 35% above or below the same weekday''s recent median.')
) v(id, tbl, what_n, name, what)
WHERE r.rule_id = v.id;

UPDATE discovery.dq_rule SET
  rule_name = 'No unreviewed duplicate contact events',
  description = 'Same customer, channel and second offered twice: a sign of double-loaded records. Pairs reviewed and accepted by a person don''t count.',
  check_sql = $q$SELECT count(*) FROM (SELECT max(contact_id) AS copy_id FROM cc.contact WHERE customer_id IS NOT NULL
      GROUP BY customer_id, channel_id, date_trunc('second', offered_ts) HAVING count(*) > 1) g
    WHERE NOT EXISTS (SELECT 1 FROM discovery.dq_reviewed_finding f WHERE f.rule_id = 'UNQ-012' AND f.item_key = g.copy_id::text)$q$,
  evidence_sql = $q$SELECT jsonb_agg(jsonb_build_object('item', to_char(day, 'Dy Mon DD, YYYY'), 'records', n,
      'detail', to_char(n, 'FM999,999') || CASE WHEN n = 1 THEN ' contact' ELSE ' contacts' END
                || ' recorded twice (same customer, channel and second), e.g. ' || array_to_string(ids, ', ')
                || CASE WHEN reviewed IS NOT NULL THEN ' · reviewed: ' || reviewed ELSE '' END,
      'explained', reviewed) ORDER BY day DESC)
    FROM (SELECT g.day, count(*) AS n, (array_agg(g.copy_id ORDER BY g.copy_id DESC))[1:3] AS ids, max(f.reason) AS reviewed
          FROM (SELECT min(offered_ts)::date AS day, max(contact_id) AS copy_id FROM cc.contact WHERE customer_id IS NOT NULL
                GROUP BY customer_id, channel_id, date_trunc('second', offered_ts) HAVING count(*) > 1) g
          LEFT JOIN discovery.dq_reviewed_finding f ON f.rule_id = 'UNQ-012' AND f.item_key = g.copy_id::text
          GROUP BY g.day ORDER BY g.day DESC LIMIT 25) x$q$,
  evidence_always = true,
  expected_note = 'Refined in v3.2: the 2 Jan 2024 pair was reviewed in run #1 and accepted, so it no longer warns.'
WHERE rule_id = 'UNQ-012';

-- ---------- 2. Rate checks: the latest day with records, not three years at once ----------
-- (Over the full history one bad day moves a rate by about 0.1 point, so these could never see it.)
UPDATE discovery.dq_rule r SET
  rule_name = v.name,
  check_sql = format($q$WITH d AS (SELECT max(%2$s)::date AS day FROM cc.%1$I WHERE %3$s AND %2$s < (SELECT discovery.period_end()) + 1)
    SELECT coalesce(100.0 * avg((%4$s)::int), 0) FROM cc.%1$I t, d WHERE %3$s AND t.%2$s >= d.day AND t.%2$s < d.day + 1$q$,
    v.tbl, v.ts, v.scope, v.cond),
  evidence_sql = format($q$WITH d AS (SELECT max(%2$s)::date AS day FROM cc.%1$I WHERE %3$s AND %2$s < (SELECT discovery.period_end()) + 1),
         today AS (SELECT d.day, count(*) FILTER (WHERE %4$s) AS n, count(*) AS total FROM cc.%1$I t, d WHERE %3$s AND t.%2$s >= d.day AND t.%2$s < d.day + 1 GROUP BY d.day),
         usual AS (SELECT 100.0 * avg((%4$s)::int) AS pct FROM cc.%1$I t, d WHERE %3$s AND t.%2$s >= d.day - 28 AND t.%2$s < d.day)
    SELECT jsonb_build_array(jsonb_build_object('item', to_char(today.day, 'Dy Mon DD, YYYY'), 'records', today.n,
      'detail', to_char(today.n, 'FM999,999') || ' of ' || to_char(today.total, 'FM999,999') || ' %5$s (' || round(100.0 * today.n / nullif(today.total, 0), 2)
                || '%%); usually about ' || round(usual.pct, 2) || '%%'))
    FROM today, usual$q$, v.tbl, v.ts, v.scope, v.cond, v.noun),
  expected_note = 'Refined in v3.2: measures the latest day loaded. Over three years of history a whole bad day moved this by only about 0.1 point.'
FROM (VALUES
  ('CMP-005', 'contact',     'offered_ts', 'channel_id IN (1, 2)', 'customer_id IS NULL',  'phone and chat contacts', 'Anonymous phone and chat contacts on the latest day'),
  ('CMP-017', 'ivr_session', 'start_ts',   'true',                 'customer_id IS NULL',  'IVR calls',               'Unidentified IVR callers on the latest day'),
  ('VAL-006', 'contact',     'offered_ts', 'answered',             'talk_sec > 7200',      'answered contacts',       'Implausibly long contacts on the latest day'),
  ('VAL-007', 'contact',     'offered_ts', 'answered AND channel_id IN (1, 2)', 'queue_wait_sec > 1200', 'answered phone and chat contacts', 'Very long phone and chat waits on the latest day')
) v(id, tbl, ts, scope, cond, noun, name)
WHERE r.rule_id = v.id;

-- ---------- 3. Volume: the latest day's rows for each feed, compared with that weekday's normal ----------
-- Measured as % away from normal; 0 on closed days and on explained days. A missing file (-100%) or a doubled file (+100%) fails.
UPDATE discovery.dq_rule r SET
  rule_name = v.name,
  description = 'How far the latest day''s ' || v.noun || ' are from normal for that weekday (median of the previous four). Closed days and days explained by a holiday, event or launch count as normal.',
  unit = '%', warn_above = 35, fail_above = 60,
  check_sql = format($q$SELECT coalesce((SELECT CASE WHEN v.is_center_closed OR coalesce(v.baseline, 0) = 0 THEN 0
        WHEN discovery.volume_explanation(v.day, v.ratio) IS NOT NULL THEN 0
        ELSE round(abs(v.row_count / v.baseline - 1) * 100, 1) END
      FROM discovery.dq_daily_volume v WHERE v.run_id = {run_id} AND v.table_name = %L AND v.day = discovery.period_end()), 0)$q$, v.tbl),
  evidence_sql = format($q$SELECT jsonb_agg(jsonb_build_object('item', to_char(v.day, 'Dy Mon DD, YYYY'), 'records', v.row_count,
      'detail', to_char(v.row_count, 'FM999,999') || ' %s vs about ' || to_char(round(v.baseline), 'FM999,999') || ' on a normal ' || to_char(v.day, 'FMDay')
                || CASE WHEN v.row_count = 0 THEN ': nothing loaded' ELSE ' (' || CASE WHEN v.row_count >= v.baseline THEN '+' ELSE '' END
                        || round((v.row_count / v.baseline - 1) * 100) || '%%)' END))
    FROM discovery.dq_daily_volume v WHERE v.run_id = {run_id} AND v.table_name = %L AND v.day = discovery.period_end() AND v.baseline > 0$q$, v.noun, v.tbl),
  expected_note = 'Refined in v3.2: replaces a minimum of 100,000 rows in total, which a missing day could never trip.'
FROM (VALUES
  ('VOL-001', 'contact',         'contacts',         'Contact volume normal on the latest day'),
  ('VOL-002', 'ivr_session',     'IVR calls',        'IVR volume normal on the latest day'),
  ('VOL-004', 'agent_activity',  'agent states',     'Agent activity normal on the latest day'),
  ('VOL-005', 'interval_volume', '15-minute rows',   'Interval summary normal on the latest day'),
  ('VOL-006', 'agent_schedule',  'schedule blocks',  'Schedules normal on the latest day'),
  ('VOL-007', 'survey_response', 'surveys',          'Survey volume normal on the latest day'),
  ('VOL-009', 'complaint',       'complaints',       'Complaint volume normal on the latest day'),
  ('VOL-010', 'agent_daily',     'agent-day rows',   'Agent-day summary normal on the latest day')
) v(id, tbl, noun, name)
WHERE r.rule_id = v.id;

-- ---------- 4. Freshness: open days with no data, up to the latest day loaded ----------
UPDATE discovery.dq_rule r SET
  rule_name = v.name,
  description = 'Open days (not Sundays or closed holidays) since the latest ' || v.noun || ', up to the latest day loaded.',
  unit = 'days', warn_above = 0, fail_above = 1,
  check_sql = format($q$SELECT count(*) FROM cc.dim_date d WHERE NOT d.is_center_closed AND d.full_date <= discovery.period_end()
    AND d.full_date > coalesce((SELECT %s FROM cc.%I), date '1900-01-01')$q$, v.latest, v.tbl),
  evidence_sql = format($q$SELECT jsonb_build_array(jsonb_build_object('item', 'Latest %s', 'records', (SELECT count(*) FROM cc.dim_date d
        WHERE NOT d.is_center_closed AND d.full_date <= discovery.period_end() AND d.full_date > x.latest),
      'detail', 'the latest is from ' || coalesce(to_char(x.latest, 'Dy Mon DD, YYYY'), 'never') || '; missing for '
                || coalesce((SELECT string_agg(to_char(d.full_date, 'Dy Mon DD'), ', ' ORDER BY d.full_date) FROM cc.dim_date d
                    WHERE NOT d.is_center_closed AND d.full_date <= discovery.period_end() AND d.full_date > x.latest), 'no open days')))
    FROM (SELECT %s AS latest FROM cc.%I) x$q$, v.noun, v.latest, v.tbl),
  expected_note = 'Refined in v3.2: counts open days, so a single missing day is caught (before, one day behind still passed).'
FROM (VALUES
  ('TML-001', 'contact',         'max(offered_ts)::date',                         'contact',         'Contacts loaded for every open day'),
  ('TML-002', 'ivr_session',     'max(start_ts)::date',                           'IVR call',        'IVR calls loaded for every open day'),
  ('TML-003', 'survey_response', 'max(survey_ts)::date',                          'survey',          'Surveys loaded for every open day'),
  ('TML-004', 'complaint',       'max(opened_ts)::date',                          'complaint',       'Complaints loaded for every open day'),
  ('TML-005', 'interval_volume', 'max(interval_ts)::date',                        '15-minute row',   'Interval summary loaded for every open day'),
  ('TML-006', 'agent_schedule',  'max(scheduled_start_ts)::date',                 'schedule block',  'Schedules loaded for every open day'),
  ('TML-007', 'agent_activity',  'max(state_start_ts)::date',                     'agent state',     'Agent activity loaded for every open day'),
  ('TML-008', 'agent_daily',     'to_date(max(date_key)::text, ''YYYYMMDD'')',    'agent-day row',   'Agent-day summary loaded for every open day')
) v(id, tbl, latest, noun, name)
WHERE r.rule_id = v.id;

-- ---------- 5. Low-importance details: warn on any finding, fail only at a meaningful volume ----------
UPDATE discovery.dq_rule r SET warn_above = 0, fail_above = v.fail_at,
  expected_note = 'Refined in v3.2: a few records are worth a look (warning); a failure needs more than ' || v.fail_at || ' ' || r.unit || '.'
FROM (VALUES ('CMP-015', 100), ('CON-013', 100), ('CON-017', 5), ('UNQ-013', 100), ('VAL-020', 100), ('VAL-021', 100)) v(id, fail_at)
WHERE r.rule_id = v.id;

-- ---------- 6. New: fields that stopped being filled in on the latest day ----------
-- For every feed, each field's fill rate on the latest day vs. the LOWEST rate on the same weekday in the previous four weeks.
-- Flagged when it is more than 5 points lower and the field is normally at least 20% filled. Fields that fill in later
-- (complaint close date and days to close) are left out.
CREATE OR REPLACE FUNCTION discovery.fill_drops(p_day date)
RETURNS TABLE (table_name text, column_name text, day_rate numeric, usual_min numeric, day_rows bigint, missing bigint)
LANGUAGE plpgsql VOLATILE AS $$
DECLARE t text; cols text[]; q text; rec record; k text; days date[] := ARRAY[p_day, p_day - 7, p_day - 14, p_day - 21, p_day - 28];
BEGIN
  FOREACH t IN ARRAY ARRAY['contact', 'ivr_session', 'survey_response', 'complaint', 'agent_activity', 'agent_schedule', 'agent_daily', 'interval_volume'] LOOP
    SELECT array_agg(a.attname::text ORDER BY a.attnum) INTO cols FROM pg_attribute a
    WHERE a.attrelid = format('cc.%I', t)::regclass AND a.attnum > 0 AND NOT a.attisdropped
      -- fields that fill in later by nature (a complaint opened today isn't closed yet)
      AND NOT (t = 'complaint' AND a.attname IN ('closed_ts', 'days_to_close'));
    q := format('SELECT %s AS day, count(*) AS n, jsonb_build_object(%s) AS filled FROM cc.%I WHERE %s = ANY ($1) GROUP BY 1',
                discovery.date_expr(t), (SELECT string_agg(format('%L, count(%I)', c, c), ', ') FROM unnest(cols) c), t, discovery.date_expr(t));
    DROP TABLE IF EXISTS fd_days;
    EXECUTE 'CREATE TEMP TABLE fd_days AS ' || q USING days;
    FOR rec IN SELECT * FROM fd_days WHERE day = p_day AND n > 0 LOOP
      FOREACH k IN ARRAY cols LOOP
        table_name := t; column_name := k; day_rows := rec.n;
        day_rate := round(100.0 * (rec.filled->>k)::numeric / rec.n, 1);
        SELECT round(min(100.0 * (f.filled->>k)::numeric / f.n), 1) INTO usual_min FROM fd_days f WHERE f.day <> p_day AND f.n > 0;
        missing := round(rec.n * (usual_min - day_rate) / 100.0);
        IF usual_min IS NOT NULL AND usual_min >= 20 AND day_rate < usual_min - 5 THEN RETURN NEXT; END IF;
      END LOOP;
    END LOOP;
  END LOOP;
  DROP TABLE IF EXISTS fd_days;
END $$;

INSERT INTO discovery.dq_rule (rule_id, table_name, column_name, dimension, rule_name, description, check_sql, unit, warn_above, fail_above, severity, expected_note, evidence_sql, problem_plain)
VALUES ('CMP-019', 'cc (all tables)', NULL, 'Completeness', 'No fields that stopped being filled in',
  'Fields in the daily feeds whose fill rate on the latest day is more than 5 points below the lowest of the same weekday in the previous four weeks.',
  $q$SELECT count(*) FROM discovery.fill_drops(discovery.period_end())$q$, 'columns', 0, 2, 'High',
  'Added in v3.2: the field checks above look at all history, so a field that stops arriving today can''t trip them.',
  $q$SELECT jsonb_agg(jsonb_build_object('item', to_char(discovery.period_end(), 'Dy Mon DD, YYYY'), 'records', missing,
      't', table_name, 'c', column_name,
      'detail', table_name || '.' || column_name || ' filled on ' || day_rate || '% of ' || to_char(day_rows, 'FM999,999') || ' records (usually at least ' || usual_min || '%)')
      ORDER BY usual_min - day_rate DESC)
    FROM discovery.fill_drops(discovery.period_end())$q$,
  'data fields that stopped being filled in')
ON CONFLICT (rule_id) DO NOTHING;

-- ---------- 7. New: 15-minute scheduled staff vs. the agents' schedules ----------
-- One row per channel group and 15 minutes where the summary's scheduled staff differ from the open-shift minutes in the
-- schedule by more than 0.1 FTE (each queue's share is rounded to 0.01). Slots with no forecast have no share to compare.
-- Phone agents also cover callbacks; the third group covers email and secure message.
CREATE OR REPLACE FUNCTION discovery.staffing_mismatches()
RETURNS TABLE (day date, interval_id int, grp text, summary_fte numeric, schedule_fte numeric) LANGUAGE sql STABLE AS $$
  WITH sched AS (
    SELECT to_char(it, 'YYYYMMDD')::int AS date_key, (extract(hour FROM it) * 4 + floor(extract(minute FROM it) / 15))::int AS iv,
           a.primary_channel_id AS g,
           sum(extract(epoch FROM least(s.scheduled_end_ts, it + interval '15 min') - greatest(s.scheduled_start_ts, it))) / 900.0 AS fte
    FROM cc.agent_schedule s JOIN cc.dim_agent a USING (agent_id)
    CROSS JOIN LATERAL generate_series(date_bin('15 min', s.scheduled_start_ts, timestamptz '2024-01-01 00:00'),
                                       s.scheduled_end_ts - interval '1 ms', interval '15 min') it
    WHERE s.activity = 'Open Shift'
    GROUP BY 1, 2, 3
  ),
  summ AS (
    SELECT v.date_key, v.interval_id::int AS iv, CASE WHEN q.channel_id IN (1, 4) THEN 1 WHEN q.channel_id = 2 THEN 2 ELSE 3 END AS g,
           sum(v.scheduled_fte) AS fte
    FROM cc.interval_volume v JOIN cc.dim_queue q USING (queue_id)
    GROUP BY 1, 2, 3 HAVING sum(v.forecast_contacts) > 0
  )
  SELECT to_date(u.date_key::text, 'YYYYMMDD'), u.iv, (ARRAY['Phone and callback', 'Chat', 'Email and secure message'])[u.g],
         u.fte, round(coalesce(s.fte, 0)::numeric, 2)
  FROM summ u LEFT JOIN sched s USING (date_key, iv, g)
  WHERE abs(u.fte - coalesce(s.fte, 0)) > 0.1
$$;

INSERT INTO discovery.dq_rule (rule_id, table_name, column_name, dimension, rule_name, description, check_sql, unit, warn_above, fail_above, severity, expected_note, evidence_sql, problem_plain)
VALUES ('CON-018', 'interval_volume', 'scheduled_fte', 'Consistency', 'Interval scheduled staff matches agent schedules',
  'Scheduled staff in the 15-minute summary that differ from the agents'' scheduled open-shift time by more than 0.1 full-time equivalents, per channel group and 15 minutes.',
  $q$SELECT count(*) FROM discovery.staffing_mismatches()$q$, 'rows', 0, 0, 'High',
  'Added after remediation R02: scheduled staff were counted in the wrong 15 minutes and no check compared the two.',
  $q$SELECT jsonb_agg(jsonb_build_object('item', to_char(day, 'Dy Mon DD, YYYY'), 'records', n,
      'detail', to_char(n, 'FM999,999') || ' 15-minute ' || CASE WHEN n = 1 THEN 'slot differs' ELSE 'slots differ' END || ', by up to '
                || worst || ' staff; e.g. ' || eg) ORDER BY day DESC)
    FROM (SELECT day, count(*) AS n, max(abs(summary_fte - schedule_fte)) AS worst,
                 (array_agg(grp || ' at ' || to_char(time '00:00' + interval_id * interval '15 min', 'HH24:MI') || ': summary ' || summary_fte || ', schedule ' || schedule_fte
                            ORDER BY abs(summary_fte - schedule_fte) DESC))[1] AS eg
          FROM discovery.staffing_mismatches() GROUP BY 1 ORDER BY 1 DESC LIMIT 25) x$q$,
  'scheduled staff that do not match the agents'' schedules')
ON CONFLICT (rule_id) DO NOTHING;

-- Every active rule must have evidence
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM discovery.dq_rule WHERE is_active AND evidence_sql IS NULL) THEN
    RAISE EXCEPTION 'rules without evidence: %', (SELECT string_agg(rule_id, ', ') FROM discovery.dq_rule WHERE is_active AND evidence_sql IS NULL);
  END IF;
END $$;
