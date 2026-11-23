-- Evidence for every check (v3.1): the specific records behind a result, so an alert can say WHICH day and WHICH records.
-- Runs after D02_rules.sql (which rebuilds dq_rule). Evidence format: JSON list of {item, records, detail}, newest day first.
--   * Common rule shapes get evidence generated from the rule's own SQL by discovery.auto_evidence_sql()
--   * Reconciliation and overlap checks get hand-written evidence below
--   * CMP-018, VAL-005, VAL-024, VAL-025 and VOL-011..014 keep the evidence written in D02_rules.sql
\set ON_ERROR_STOP on
SET client_min_messages = warning;

-- What each table's records are called, which date groups them, and which ID to show as an example
CREATE OR REPLACE FUNCTION discovery.evidence_shape(p_table text, OUT day_expr text, OUT key_expr text, OUT one text, OUT many text)
LANGUAGE sql IMMUTABLE AS $$
  SELECT v.d, v.k, v.o, v.m FROM (VALUES
    ('contact',          'offered_ts::date',                       'contact_id',          'contact',         'contacts'),
    ('ivr_session',      'start_ts::date',                         'session_id',          'IVR call',        'IVR calls'),
    ('survey_response',  'survey_ts::date',                        'survey_id',           'survey',          'surveys'),
    ('complaint',        'opened_ts::date',                        'complaint_id',        'complaint',       'complaints'),
    ('agent_activity',   'state_start_ts::date',                   'activity_id',         'agent state',     'agent states'),
    ('agent_schedule',   'scheduled_start_ts::date',               'schedule_id',         'schedule block',  'schedule blocks'),
    ('agent_daily',      'to_date(date_key::text, ''YYYYMMDD'')',  'agent_id',            'agent-day',       'agent-days'),
    ('interval_volume',  'interval_ts::date',                      'queue_id',            '15-minute row',   '15-minute rows'),
    ('customer',         'customer_since',                         'customer_id',         'customer',        'customers'),
    ('customer_product', 'open_date',                              'customer_product_id', 'product holding', 'product holdings'),
    ('dim_date',         'full_date',                              'full_date',           'day',             'days'),
    ('dim_agent',        'NULL::date',                             'agent_id',            'agent',           'agents')
  ) v(t, d, k, o, m) WHERE v.t = p_table
$$;

CREATE OR REPLACE FUNCTION discovery.auto_evidence_sql(p_sql text) RETURNS text LANGUAGE plpgsql IMMUTABLE AS $f$
DECLARE
  s text := regexp_replace(btrim(p_sql), '\s+', ' ', 'g');
  m text[]; sh record;
  item text := $$CASE WHEN day IS NULL THEN 'All records' ELSE to_char(day, 'Dy Mon DD, YYYY') END$$;
BEGIN
  -- 1. SELECT count(*) FROM cc.<table> ... WHERE <problem>   -> problem records per day, with example IDs
  m := regexp_match(s, '^SELECT count\(\*\) FROM (cc\.(\w+)\M.*)$', 'i');
  IF m IS NOT NULL THEN
    SELECT * INTO sh FROM discovery.evidence_shape(m[2]);
    IF sh.day_expr IS NULL THEN RETURN NULL; END IF;
    RETURN format($q$SELECT jsonb_agg(jsonb_build_object('item', %s, 'records', n,
        'detail', to_char(n, 'FM999,999,999') || ' ' || CASE WHEN n = 1 THEN %L ELSE %L END || ', e.g. ' || array_to_string(ids, ', '))
        ORDER BY day DESC NULLS LAST)
      FROM (SELECT %s AS day, count(*) AS n, (array_agg((%s)::text ORDER BY %s DESC))[1:3] AS ids
            FROM %s GROUP BY 1 ORDER BY 1 DESC NULLS LAST LIMIT 25) x$q$,
      item, sh.one, sh.many, sh.day_expr, sh.key_expr, sh.key_expr, m[1]);
  END IF;

  -- 2. SELECT count(*) - count(DISTINCT <key>) FROM cc.<table>   -> extra copies per day (day the copy arrived)
  m := regexp_match(s, '^SELECT count\(\*\) - count\(DISTINCT (.+)\) FROM cc\.(\w+)$', 'i');
  IF m IS NOT NULL THEN
    SELECT * INTO sh FROM discovery.evidence_shape(m[2]);
    IF sh.day_expr IS NULL THEN RETURN NULL; END IF;
    RETURN format($q$SELECT jsonb_agg(jsonb_build_object('item', %s, 'records', n,
        'detail', to_char(n, 'FM999,999,999') || ' extra ' || CASE WHEN n = 1 THEN %L ELSE %L END || ' with a repeated ' || %L || ', e.g. ' || array_to_string(ids, ', '))
        ORDER BY day DESC NULLS LAST)
      FROM (SELECT day, sum(c - 1) AS n, (array_agg(k ORDER BY k DESC))[1:3] AS ids
            FROM (SELECT (%s)::text AS k, max(%s) AS day, count(*) AS c FROM cc.%I GROUP BY %s HAVING count(*) > 1) d
            GROUP BY 1 ORDER BY 1 DESC NULLS LAST LIMIT 25) x$q$,
      item, sh.one, sh.many, m[1], m[1], sh.day_expr, m[2], m[1]);
  END IF;

  -- 3. SELECT 100.0 * avg((<condition>)::int) FROM cc.<table> [WHERE <scope>]   -> matching records per day and their share
  m := regexp_match(s, '^SELECT 100\.0 \* avg\(\((.+)\)::int\) FROM cc\.(\w+)(?: WHERE (.+))?$', 'i');
  IF m IS NOT NULL THEN
    SELECT * INTO sh FROM discovery.evidence_shape(m[2]);
    IF sh.day_expr IS NULL THEN RETURN NULL; END IF;
    RETURN format($q$SELECT jsonb_agg(jsonb_build_object('item', %s, 'records', n,
        'detail', to_char(n, 'FM999,999,999') || ' of ' || to_char(total, 'FM999,999,999') || ' ' || %L || ' (' || round(100.0 * n / total, 1) || '%%)')
        ORDER BY day DESC NULLS LAST)
      FROM (SELECT %s AS day, count(*) FILTER (WHERE %s) AS n, count(*) AS total FROM cc.%I %s
            GROUP BY 1 HAVING count(*) FILTER (WHERE %s) > 0 ORDER BY 1 DESC NULLS LAST LIMIT 10) x$q$,
      item, sh.many, sh.day_expr, m[1], m[2], CASE WHEN m[3] IS NULL THEN '' ELSE 'WHERE ' || m[3] END, m[1]);
  END IF;

  -- 4. SELECT greatest(0, <minimum> - count(*)) FROM cc.<table>   -> total rows vs the minimum
  m := regexp_match(s, '^SELECT greatest\(0, (\d+) - count\(\*\)\) FROM cc\.(\w+)$', 'i');
  IF m IS NOT NULL THEN
    RETURN format($q$SELECT jsonb_build_array(jsonb_build_object('item', 'All records', 'records', count(*),
        'detail', to_char(count(*), 'FM999,999,999') || ' records; at least ' || to_char(%s, 'FM999,999,999') || ' expected')) FROM cc.%I$q$, m[1], m[2]);
  END IF;

  -- 5. SELECT discovery.period_end() - <latest date> FROM cc.<table>   -> the latest record vs the period end
  m := regexp_match(s, '^SELECT discovery\.(period_end|snapshot_date)\(\) - (.+) FROM cc\.(\w+)$', 'i');
  IF m IS NOT NULL THEN
    SELECT * INTO sh FROM discovery.evidence_shape(m[3]);
    RETURN format($q$SELECT jsonb_build_array(jsonb_build_object('item', 'Latest ' || %L, 'records', 0,
        'detail', 'the latest is from ' || coalesce(to_char(%s, 'Dy Mon DD, YYYY'), 'never') || '; ' ||
                  %L || ' ' || to_char(discovery.%s(), 'Dy Mon DD, YYYY'))) FROM cc.%I$q$,
      coalesce(sh.one, m[3]), m[2],
      CASE m[1] WHEN 'period_end' THEN 'data is loaded up to' ELSE 'the monthly snapshot is dated' END, m[1], m[3]);
  END IF;
  RETURN NULL;
END $f$;

-- Hand-written evidence keeps its own SQL; everything else is generated
UPDATE discovery.dq_rule SET evidence_sql = discovery.auto_evidence_sql(check_sql)
WHERE rule_id NOT IN ('CMP-018', 'VAL-005', 'VAL-024', 'VAL-025', 'VOL-011', 'VOL-012', 'VOL-013', 'VOL-014');

-- ---------- Reconciliations: show the days where summary and detail disagree ----------
UPDATE discovery.dq_rule SET evidence_sql = $$
  SELECT jsonb_agg(jsonb_build_object('item', to_char(day, 'Dy Mon DD, YYYY'), 'records', abs(s - d),
           'detail', to_char(s, 'FM999,999') || ' offered in the 15-minute summary vs ' || to_char(d, 'FM999,999') || ' contacts in the detail') ORDER BY day DESC)
  FROM (SELECT to_date(date_key::text, 'YYYYMMDD') AS day, sum(s) AS s, sum(d) AS d
        FROM (SELECT date_key, sum(offered) AS s, 0 AS d FROM cc.interval_volume GROUP BY 1
              UNION ALL SELECT date_key, 0, count(*) FROM cc.contact GROUP BY 1) u
        GROUP BY 1 HAVING sum(s) <> sum(d) ORDER BY 1 DESC LIMIT 25) x$$
WHERE rule_id = 'CON-001';

UPDATE discovery.dq_rule SET evidence_sql = $$
  SELECT jsonb_agg(jsonb_build_object('item', to_char(day, 'Dy Mon DD, YYYY'), 'records', abs(s - d),
           'detail', to_char(s, 'FM999,999') || ' answered in the 15-minute summary vs ' || to_char(d, 'FM999,999') || ' answered contacts in the detail') ORDER BY day DESC)
  FROM (SELECT to_date(date_key::text, 'YYYYMMDD') AS day, sum(s) AS s, sum(d) AS d
        FROM (SELECT date_key, sum(answered) AS s, 0 AS d FROM cc.interval_volume GROUP BY 1
              UNION ALL SELECT date_key, 0, count(*) FROM cc.contact WHERE answered GROUP BY 1) u
        GROUP BY 1 HAVING sum(s) <> sum(d) ORDER BY 1 DESC LIMIT 25) x$$
WHERE rule_id = 'CON-002';

UPDATE discovery.dq_rule SET evidence_sql = $$
  SELECT jsonb_agg(jsonb_build_object('item', to_char(day, 'Dy Mon DD, YYYY'), 'records', abs(s - d),
           'detail', to_char(s, 'FM999,999') || ' handled in the agent-day summary vs ' || to_char(d, 'FM999,999') || ' contacts answered that day') ORDER BY day DESC)
  FROM (SELECT day, sum(s) AS s, sum(d) AS d
        FROM (SELECT to_date(date_key::text, 'YYYYMMDD') AS day, sum(contacts_handled) AS s, 0 AS d FROM cc.agent_daily GROUP BY 1
              UNION ALL SELECT answered_ts::date, 0, count(*) FROM cc.contact WHERE answered GROUP BY 1) u
        WHERE day <= discovery.period_end()
        GROUP BY 1 HAVING sum(s) <> sum(d) ORDER BY 1 DESC LIMIT 25) x$$
WHERE rule_id = 'CON-003';

-- ---------- Overlaps: the later of two overlapping records, per day ----------
UPDATE discovery.dq_rule SET evidence_sql = $$
  SELECT jsonb_agg(jsonb_build_object('item', to_char(day, 'Dy Mon DD, YYYY'), 'records', n,
           'detail', to_char(n, 'FM999,999') || ' contacts answered before the agent finished the previous one, e.g. ' || array_to_string(ids, ', ')) ORDER BY day DESC)
  FROM (SELECT answered_ts::date AS day, count(*) AS n, (array_agg(contact_id ORDER BY contact_id DESC))[1:3] AS ids
        FROM (SELECT contact_id, answered_ts, lag(wrap_end_ts) OVER (PARTITION BY agent_id ORDER BY answered_ts) AS prev_end
              FROM cc.contact WHERE answered AND channel_id <> 2) x
        WHERE answered_ts < prev_end GROUP BY 1 ORDER BY 1 DESC LIMIT 25) y$$
WHERE rule_id = 'CON-008';

UPDATE discovery.dq_rule SET evidence_sql = $$
  SELECT jsonb_agg(jsonb_build_object('item', to_char(day, 'Dy Mon DD, YYYY'), 'records', n,
           'detail', to_char(n, 'FM999,999') || ' agent states starting before the previous one ended, e.g. ' || array_to_string(ids, ', ')) ORDER BY day DESC)
  FROM (SELECT state_start_ts::date AS day, count(*) AS n, (array_agg(activity_id ORDER BY activity_id DESC))[1:3] AS ids
        FROM (SELECT activity_id, state_start_ts, lag(state_end_ts) OVER (PARTITION BY agent_id ORDER BY state_start_ts) AS prev_end
              FROM cc.agent_activity) x
        WHERE state_start_ts < prev_end - interval '1 ms' GROUP BY 1 ORDER BY 1 DESC LIMIT 25) y$$
WHERE rule_id = 'CON-010';

UPDATE discovery.dq_rule SET evidence_sql = $$
  SELECT jsonb_agg(jsonb_build_object('item', to_char(day, 'Dy Mon DD, YYYY'), 'records', n,
           'detail', to_char(n, 'FM999,999') || ' schedule blocks starting before the previous one ended, e.g. ' || array_to_string(ids, ', ')) ORDER BY day DESC)
  FROM (SELECT scheduled_start_ts::date AS day, count(*) AS n, (array_agg(schedule_id ORDER BY schedule_id DESC))[1:3] AS ids
        FROM (SELECT schedule_id, scheduled_start_ts, lag(scheduled_end_ts) OVER (PARTITION BY agent_id ORDER BY scheduled_start_ts) AS prev_end
              FROM cc.agent_schedule) x
        WHERE scheduled_start_ts < prev_end GROUP BY 1 ORDER BY 1 DESC LIMIT 25) y$$
WHERE rule_id = 'CON-011';

-- Contacts handled while unavailable: grouped by the day they were answered (that day's agent activity is the comparison)
UPDATE discovery.dq_rule SET evidence_sql = $$
  SELECT jsonb_agg(jsonb_build_object('item', to_char(day, 'Dy Mon DD, YYYY'), 'records', n,
           'detail', to_char(n, 'FM999,999') || CASE WHEN n = 1 THEN ' contact' ELSE ' contacts' END
                     || ' answered with no matching Available time for the agent, e.g. ' || array_to_string(ids, ', ')) ORDER BY day DESC)
  FROM (SELECT c.answered_ts::date AS day, count(*) AS n, (array_agg(c.contact_id ORDER BY c.contact_id DESC))[1:3] AS ids
        FROM cc.contact c WHERE c.answered AND c.answered_ts::date <= (SELECT discovery.period_end()) AND NOT EXISTS (SELECT 1 FROM cc.agent_activity a
          WHERE a.agent_id = c.agent_id AND a.date_key = to_char(c.answered_ts, 'YYYYMMDD')::int
            AND a.state = 'Available' AND c.answered_ts >= a.state_start_ts AND c.wrap_end_ts <= a.state_end_ts)
        GROUP BY 1 ORDER BY 1 DESC LIMIT 25) x$$
WHERE rule_id = 'CON-009';

-- ---------- Duplicates found by matching values rather than IDs ----------
UPDATE discovery.dq_rule SET evidence_sql = $$
  SELECT jsonb_agg(jsonb_build_object('item', to_char(day, 'Dy Mon DD, YYYY'), 'records', n,
           'detail', to_char(n, 'FM999,999') || CASE WHEN n = 1 THEN ' contact' ELSE ' contacts' END
                     || ' recorded twice (same customer, channel and second), e.g. ' || array_to_string(ids, ', ')) ORDER BY day DESC)
  FROM (SELECT day, count(*) AS n, (array_agg(copy_id ORDER BY copy_id DESC))[1:3] AS ids
        FROM (SELECT min(offered_ts)::date AS day, max(contact_id) AS copy_id FROM cc.contact WHERE customer_id IS NOT NULL
              GROUP BY customer_id, channel_id, date_trunc('second', offered_ts) HAVING count(*) > 1) g
        GROUP BY 1 ORDER BY 1 DESC LIMIT 25) x$$
WHERE rule_id = 'UNQ-012';

UPDATE discovery.dq_rule SET evidence_sql = $$
  SELECT jsonb_agg(jsonb_build_object('item', to_char(day, 'Dy Mon DD, YYYY'), 'records', n,
           'detail', to_char(n, 'FM999,999') || ' customers holding the same product twice, e.g. ' || array_to_string(ids, ', ')) ORDER BY day DESC)
  FROM (SELECT day, count(*) AS n, (array_agg(id ORDER BY id DESC))[1:3] AS ids
        FROM (SELECT max(open_date) AS day, max(customer_product_id) AS id FROM cc.customer_product
              GROUP BY customer_id, product_id HAVING count(*) > 1) g
        GROUP BY 1 ORDER BY 1 DESC LIMIT 25) x$$
WHERE rule_id = 'UNQ-013';

UPDATE discovery.dq_rule SET evidence_sql = $$
  SELECT jsonb_build_array(jsonb_build_object('item', 'Calendar', 'records', (max(full_date) - min(full_date) + 1) - count(*),
           'detail', 'runs ' || to_char(min(full_date), 'Mon DD, YYYY') || ' to ' || to_char(max(full_date), 'Mon DD, YYYY') || ' with '
                     || to_char(count(*), 'FM999,999') || ' of ' || to_char(max(full_date) - min(full_date) + 1, 'FM999,999') || ' days'))
  FROM cc.dim_date$$
WHERE rule_id = 'CMP-016';

-- Plain-language problem wording for the checks the daily feeds can trip (D02 covers the others)
UPDATE discovery.dq_rule r SET problem_plain = v.p FROM (VALUES
 ('CMP-002', 'answered contacts with no agent recorded'),
 ('CMP-006', 'emails, messages and callbacks with no customer recorded'),
 ('CMP-014', 'agent-days with no time logged in'),
 ('CON-001', '15-minute summary totals that don''t match the contacts'),
 ('CON-002', 'answered totals in the 15-minute summary that don''t match the contacts'),
 ('CON-003', 'agent-day totals that don''t match the contacts answered'),
 ('CON-004', 'surveys credited to a different agent than the contact'),
 ('CON-005', 'surveys from a different customer than the contact'),
 ('CON-007', 'phone contacts with no phone-menu call'),
 ('CON-008', 'agents answering a contact before finishing the previous one'),
 ('CON-009', 'contacts handled while the agent wasn''t available'),
 ('CON-012', 'complaints from a different customer than the contact'),
 ('CON-014', 'service-level flags that don''t match the wait time'),
 ('CON-015', 'contacts filed under the wrong date'),
 ('UNQ-011', 'the same survey recorded twice'),
 ('VAL-001', 'negative wait or handling times'),
 ('VAL-002', 'contact times out of order'),
 ('VAL-004', 'contacts dated outside the reporting period'),
 ('VAL-014', 'complaints closed before they were opened'),
 ('VAL-017', 'contacts handled by agents who had left')
) v(id, p) WHERE r.rule_id = v.id AND r.problem_plain IS NULL;

-- (The "every rule has evidence" check runs at the end of D07_refinements.sql, after the refined rules get theirs.)
