-- Incident tracking (v3.1). After each daily run:
--   1. Every non-passing check's evidence is split into problem DAYS (evidence items are dated; a check that got worse
--      without dated evidence is pinned to the business day of the run). Only days from the start of daily loads count.
--   2. Open incidents are updated with the records still affected on their day, or resolved when none remain;
--      the late or correction file for that day supplies the cause and the fix.
--   3. Problem days with no incident open a new one (one incident per business day). Volume-only findings on a holiday
--      or known event are Accepted: recorded, explained, no alert.
\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE OR REPLACE FUNCTION discovery.pipeline_start() RETURNS date LANGUAGE sql IMMUTABLE AS $$ SELECT date '2026-11-01' $$;
CREATE OR REPLACE FUNCTION discovery.status_rank(s text) RETURNS int LANGUAGE sql IMMUTABLE AS
$$ SELECT CASE s WHEN 'Pass' THEN 0 WHEN 'Warn' THEN 1 WHEN 'Fail' THEN 2 WHEN 'Error' THEN 2 ELSE 0 END $$;
CREATE OR REPLACE FUNCTION discovery.fmt(n numeric) RETURNS text LANGUAGE sql IMMUTABLE AS
$$ SELECT to_char(n, 'FM999,999,999,990') $$;
CREATE OR REPLACE FUNCTION discovery.day_label(d date) RETURNS text LANGUAGE sql IMMUTABLE AS
$$ SELECT to_char(d, 'Dy FMDD Mon YYYY') $$;

-- Problem days in a run: (rule, day, records, detail)
CREATE OR REPLACE FUNCTION discovery.problem_days(p_run int)
RETURNS TABLE (rule_id text, day date, records numeric, detail text) LANGUAGE sql STABLE AS $$
  WITH r AS (SELECT business_date AS bd FROM discovery.dq_run WHERE run_id = p_run),
  c AS (SELECT c.rule_id, c.status, c.evidence, p.status AS ps
        FROM discovery.dq_check_result c
        LEFT JOIN discovery.dq_check_result p ON p.rule_id = c.rule_id
             AND p.run_id = (SELECT max(run_id) FROM discovery.dq_check_result WHERE run_id < p_run)
        WHERE c.run_id = p_run AND c.status <> 'Pass'),
  items AS (
    -- a check measured in days counts each flagged day once (its evidence "records" is that day's row count)
    SELECT c.rule_id, c.status, c.ps,
           CASE WHEN (SELECT unit FROM discovery.dq_rule q WHERE q.rule_id = c.rule_id) = 'days' THEN 1 ELSE (e->>'records')::numeric END AS records,
           e->>'detail' AS detail,
           CASE WHEN e->>'item' ~ '^[A-Z][a-z]{2} [A-Z][a-z]{2} \d{2}, \d{4}$' THEN to_date(e->>'item', 'Dy Mon DD, YYYY') END AS d
    FROM c LEFT JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(c.evidence) = 'array' THEN c.evidence ELSE '[]'::jsonb END) e ON true
    WHERE e IS NULL OR e->>'explained' IS NULL)   -- explained or reviewed findings never open an incident
  SELECT i.rule_id,
         least(coalesce(i.d, CASE WHEN discovery.status_rank(i.status) > discovery.status_rank(i.ps) THEN r.bd END), r.bd) AS day,
         coalesce(i.records, 0), i.detail
  FROM items i, r
  WHERE r.bd IS NOT NULL
    AND least(coalesce(i.d, CASE WHEN discovery.status_rank(i.status) > discovery.status_rank(i.ps) THEN r.bd END), r.bd) >= discovery.pipeline_start()
$$;

CREATE OR REPLACE FUNCTION discovery.unit_word(u text, n numeric) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE u WHEN 'rows' THEN CASE WHEN n = 1 THEN 'record' ELSE 'records' END
                WHEN 'days' THEN CASE WHEN n = 1 THEN 'day' ELSE 'days' END
                WHEN 'columns' THEN CASE WHEN n = 1 THEN 'data field' ELSE 'data fields' END
                ELSE u END
$$;
CREATE OR REPLACE FUNCTION discovery.problem_of(p_rule text) RETURNS text LANGUAGE sql STABLE AS $$
  SELECT coalesce(problem_plain, lower(left(rule_name, 1)) || substr(rule_name, 2)) FROM discovery.dq_rule WHERE rule_id = p_rule
$$;

CREATE OR REPLACE FUNCTION discovery.track_incidents(p_run int) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  bd date; inc record; ld record; acts jsonb := '[]'; snap jsonb; prev_snap jsonb; note text; changes text;
  d date; n int; prim record; chk jsonb; accepted boolean; why text; new_id int; ttl text;
BEGIN
  SELECT business_date INTO bd FROM discovery.dq_run WHERE run_id = p_run;
  IF bd IS NULL THEN RETURN acts; END IF;
  DROP TABLE IF EXISTS pd;
  CREATE TEMP TABLE pd AS SELECT * FROM discovery.problem_days(p_run);
  -- findings already explained (Accepted) stay explained in later runs
  DELETE FROM pd WHERE EXISTS (SELECT 1 FROM discovery.dq_incident i
                               WHERE i.status = 'Accepted' AND i.business_date = pd.day AND i.checks ? pd.rule_id);

  -- ---------- 1. open incidents: update or resolve ----------
  FOR inc IN SELECT * FROM discovery.dq_incident WHERE status = 'Open' ORDER BY incident_id LOOP
    -- a check that newly shows problems on this incident's day joins it
    UPDATE discovery.dq_incident i SET checks = i.checks || x.add
    FROM (SELECT jsonb_object_agg(pd.rule_id, jsonb_build_object('records', sum, 'unit', r.unit, 'status', c.status)) AS add
          FROM (SELECT pd.rule_id, sum(pd.records) FROM pd WHERE pd.day = inc.business_date GROUP BY 1) pd
          JOIN discovery.dq_rule r USING (rule_id)
          JOIN discovery.dq_check_result c ON c.run_id = p_run AND c.rule_id = pd.rule_id
          WHERE NOT inc.checks ? pd.rule_id) x
    WHERE i.incident_id = inc.incident_id AND x.add IS NOT NULL;
    SELECT * INTO inc FROM discovery.dq_incident WHERE incident_id = inc.incident_id;

    SELECT jsonb_agg(jsonb_build_object('rule_id', k, 'status', c.status, 'unit', inc.checks->k->>'unit',
             'records', coalesce((SELECT sum(records) FROM pd WHERE pd.rule_id = k AND pd.day = inc.business_date), 0)) ORDER BY k)
      INTO snap
    FROM jsonb_object_keys(inc.checks) k LEFT JOIN discovery.dq_check_result c ON c.run_id = p_run AND c.rule_id = k;

    SELECT * INTO ld FROM discovery.dq_load WHERE run_id = p_run AND fixes_date = inc.business_date
    ORDER BY (fix IS NOT NULL) DESC, load_id DESC LIMIT 1;

    IF NOT EXISTS (SELECT 1 FROM pd WHERE pd.day = inc.business_date) THEN
      UPDATE discovery.dq_incident SET status = 'Resolved', resolved_run_id = p_run, resolved_at = now(),
             cause = coalesce(ld.reason, cause), fix = coalesce(ld.fix, 'Cleared in run #' || p_run || ' without a correction file.'),
             fix_load_id = ld.load_id
      WHERE incident_id = inc.incident_id;
      note := 'Resolved: no affected records remain for ' || discovery.day_label(inc.business_date) || '.'
              || CASE WHEN ld.load_id IS NOT NULL THEN ' Fixed by ' || ld.file_name || ' (' || lower(ld.load_kind) || ' file).' ELSE '' END;
      UPDATE discovery.dq_event SET description = 'Data incident #' || inc.incident_id || ', resolved in run #' || p_run || '. '
             || coalesce(ld.reason, '') WHERE incident_id = inc.incident_id;
      acts := acts || jsonb_build_object('incident_id', inc.incident_id, 'action', 'resolved');
    ELSE
      SELECT u.checks INTO prev_snap FROM discovery.dq_incident_update u WHERE u.incident_id = inc.incident_id ORDER BY u.run_id DESC LIMIT 1;
      SELECT string_agg(s->>'rule_id' || ': ' || discovery.fmt(coalesce((p->>'records')::numeric, 0)) || ' → ' || discovery.fmt((s->>'records')::numeric)
                        || ' ' || discovery.unit_word(s->>'unit', (s->>'records')::numeric), '; ' ORDER BY s->>'rule_id')
        INTO changes
      FROM jsonb_array_elements(snap) s
      LEFT JOIN LATERAL (SELECT p FROM jsonb_array_elements(prev_snap) p WHERE p->>'rule_id' = s->>'rule_id') pp ON true
      WHERE coalesce((pp.p->>'records')::numeric, -1) <> (s->>'records')::numeric;
      note := CASE WHEN changes IS NULL THEN 'Still open: no change since the last run.' ELSE 'Still open. ' || changes || '.' END
              || CASE WHEN ld.load_id IS NOT NULL THEN ' Received ' || ld.file_name || ' (' || lower(ld.load_kind) || ' file)'
                      || CASE WHEN ld.reason IS NOT NULL THEN ': ' || ld.reason ELSE '.' END ELSE '' END;
      acts := acts || jsonb_build_object('incident_id', inc.incident_id, 'action', 'updated');
    END IF;
    INSERT INTO discovery.dq_incident_update (incident_id, run_id, status, checks, note)
    VALUES (inc.incident_id, p_run, (SELECT status FROM discovery.dq_incident WHERE incident_id = inc.incident_id), snap, note);
  END LOOP;

  -- ---------- 2. new problem days ----------
  FOR d IN SELECT DISTINCT pd.day FROM pd
           WHERE NOT EXISTS (SELECT 1 FROM discovery.dq_incident i WHERE i.status = 'Open' AND i.business_date = pd.day)
             AND NOT EXISTS (SELECT 1 FROM discovery.dq_incident i WHERE i.resolved_run_id = p_run AND i.business_date = pd.day)
           ORDER BY 1 LOOP
    -- the headline check describes the data itself (duplicate, missing, invalid) rather than a symptom
    -- (totals that no longer reconcile, unusual volume), then the most important, then the most records
    SELECT x.rule_id, x.records, r.unit, r.severity INTO prim
    FROM (SELECT pd.rule_id, sum(pd.records) AS records FROM pd WHERE pd.day = d GROUP BY 1) x JOIN discovery.dq_rule r USING (rule_id)
    -- (CMP-019, fields that stopped being filled in, is a derived signal: it ranks with the symptoms)
    ORDER BY CASE WHEN r.rule_id = 'CMP-019' THEN 2 WHEN r.dimension IN ('Uniqueness', 'Completeness', 'Validity') THEN 1
                  WHEN r.dimension = 'Consistency' THEN 2 ELSE 3 END,
             CASE r.severity WHEN 'Critical' THEN 4 WHEN 'High' THEN 3 WHEN 'Medium' THEN 2 ELSE 1 END DESC, x.records DESC LIMIT 1;
    SELECT jsonb_object_agg(x.rule_id, jsonb_build_object('records', x.records, 'unit', r.unit, 'status', c.status)), count(*)
      INTO chk, n
    FROM (SELECT pd.rule_id, sum(pd.records) AS records FROM pd WHERE pd.day = d GROUP BY 1) x
    JOIN discovery.dq_rule r USING (rule_id) JOIN discovery.dq_check_result c ON c.run_id = p_run AND c.rule_id = x.rule_id;

    -- volume-only findings on a holiday or known event are explained, not alerted
    SELECT coalesce((SELECT 'it was ' || holiday_name FROM cc.dim_date WHERE full_date = d AND is_holiday),
                    (SELECT 'of ' || title FROM discovery.dq_event WHERE kind <> 'Data' AND d BETWEEN start_date AND end_date LIMIT 1))
      INTO why;
    accepted := why IS NOT NULL AND NOT EXISTS (SELECT 1 FROM jsonb_object_keys(chk) k WHERE k NOT LIKE 'VOL-%');

    ttl := to_char(d, 'Dy FMDD Mon') || ': ' || upper(left(discovery.problem_of(prim.rule_id), 1)) || substr(discovery.problem_of(prim.rule_id), 2)
           || CASE WHEN n > 1 THEN ' (+' || (n - 1) || ' related check' || CASE WHEN n > 2 THEN 's' ELSE '' END || ')' ELSE '' END;
    INSERT INTO discovery.dq_incident (rule_id, checks, business_date, title, status, opened_run_id, resolved_run_id, resolved_at, impact, cause, fix)
    VALUES (prim.rule_id, chk, d, ttl, CASE WHEN accepted THEN 'Accepted' ELSE 'Open' END, p_run,
            CASE WHEN accepted THEN p_run END, CASE WHEN accepted THEN now() END,
            discovery.fmt(prim.records) || ' ' || discovery.unit_word(prim.unit, prim.records) || ': ' || discovery.problem_of(prim.rule_id),
            CASE WHEN accepted THEN 'Expected: volume was unusual because ' || why || '.' END,
            CASE WHEN accepted THEN 'No fix needed.' END)
    RETURNING incident_id INTO new_id;

    SELECT jsonb_agg(jsonb_build_object('rule_id', k, 'status', chk->k->>'status', 'unit', chk->k->>'unit', 'records', (chk->k->>'records')::numeric) ORDER BY k)
      INTO snap FROM jsonb_object_keys(chk) k;
    INSERT INTO discovery.dq_incident_update (incident_id, run_id, status, checks, note)
    VALUES (new_id, p_run, CASE WHEN accepted THEN 'Accepted' ELSE 'Open' END, snap,
            CASE WHEN accepted THEN 'Accepted: volume was unusual because ' || why || '. Recorded, no alert raised.'
                 ELSE 'Opened: ' || n || CASE WHEN n = 1 THEN ' check found' ELSE ' checks found' END || ' problems in the data for '
                      || discovery.day_label(d) || ' (' || (SELECT string_agg(k, ', ' ORDER BY k) FROM jsonb_object_keys(chk) k) || ').' END);
    IF NOT accepted THEN
      INSERT INTO discovery.dq_event (start_date, end_date, kind, title, description, incident_id)
      VALUES (d, d, 'Data', 'Data incident #' || new_id, ttl, new_id);
    END IF;
    acts := acts || jsonb_build_object('incident_id', new_id, 'action', CASE WHEN accepted THEN 'accepted' ELSE 'opened' END);
  END LOOP;
  RETURN acts;
END $$;

-- One-paragraph plain summary of a daily run, from its loads and incidents
CREATE OR REPLACE FUNCTION discovery.summarize_run(p_run int) RETURNS text LANGUAGE sql STABLE AS $$
  WITH r AS (SELECT business_date AS bd FROM discovery.dq_run WHERE run_id = p_run),
  l AS (SELECT * FROM discovery.dq_load WHERE run_id = p_run)
  SELECT concat_ws(' ',
    'Daily load for ' || discovery.day_label(r.bd) || ': ' || (SELECT count(*) FROM l WHERE load_kind = 'Daily' AND status <> 'Missing') || ' of '
      || (SELECT count(*) FROM l WHERE load_kind = 'Daily') || ' files arrived.',
    (SELECT string_agg(file_name || ' never arrived.', ' ') FROM l WHERE status = 'Missing'),
    (SELECT string_agg(file_name || ' had ' || discovery.fmt(rows_received) || ' rows; the sender declared ' || discovery.fmt(expected_rows) || '.', ' ')
       FROM l WHERE status = 'Count mismatch'),
    (SELECT 'Also received: ' || string_agg(lower(load_kind) || ' file ' || file_name || ' for ' || to_char(business_date, 'FMDD Mon'), ', ') || '.'
       FROM l WHERE load_kind <> 'Daily'),
    (SELECT 'Held ' || discovery.fmt(sum(rows_held)) || ' rows waiting for their contacts.' FROM l HAVING sum(rows_held) > 0),
    (SELECT 'Released ' || discovery.fmt(sum(rows_released)) || ' held rows.' FROM l HAVING sum(rows_released) > 0),
    (SELECT string_agg('New incident #' || incident_id || ': ' || title || '.', ' ') FROM discovery.dq_incident WHERE opened_run_id = p_run AND status <> 'Accepted'),
    (SELECT string_agg('Explained, no alert: ' || title || '. ' || cause, ' ') FROM discovery.dq_incident WHERE opened_run_id = p_run AND status = 'Accepted'),
    (SELECT string_agg('Resolved #' || incident_id || ': ' || title || '.', ' ') FROM discovery.dq_incident WHERE resolved_run_id = p_run AND status = 'Resolved'),
    (SELECT CASE WHEN count(*) = 0 THEN 'No incidents open.' ELSE count(*) || ' incident' || CASE WHEN count(*) > 1 THEN 's' ELSE '' END || ' still open.' END
       FROM discovery.dq_incident   -- open as of this run (summaries can be regenerated later)
       WHERE status <> 'Accepted' AND opened_run_id <= p_run AND (resolved_run_id IS NULL OR resolved_run_id > p_run)))
  FROM r
$$;

-- GitHub Issue text (Markdown) for an incident: 'open' = issue body, 'update' / 'resolve' = comment
CREATE OR REPLACE FUNCTION discovery.issue_text(p_incident int, p_kind text, p_run int) RETURNS text LANGUAGE sql STABLE AS $$
  SELECT CASE p_kind
    WHEN 'open' THEN
      '**Data quality alert** · data for ' || discovery.day_label(i.business_date) || ' · found by run #' || p_run || E'\n\n'
      || '**What''s wrong:** ' || i.impact || E'\n\n| Check | Result | Affected on this day |\n|---|---|---|\n'
      || (SELECT string_agg('| ' || k || ' · ' || upper(left(discovery.problem_of(k), 1)) || substr(discovery.problem_of(k), 2) || ' | ' || (i.checks->k->>'status') || ' | '
                 || discovery.fmt((i.checks->k->>'records')::numeric) || ' ' || discovery.unit_word(i.checks->k->>'unit', (i.checks->k->>'records')::numeric) || ' |', E'\n' ORDER BY k)
          FROM jsonb_object_keys(i.checks) k)
      || coalesce(E'\n\n**Example:** ' || (SELECT p.detail FROM discovery.problem_days(p_run) p WHERE p.rule_id = i.rule_id AND p.day = i.business_date LIMIT 1), '')
      || E'\n\nThis issue gets a comment after every daily run and closes automatically when a run confirms the fix.'
      || E'\n[Open run #' || p_run || ' in the Data Quality Dashboard](https://robbiegerber-nu.github.io/happenbankdemo/quality.html?run=' || p_run || '&tab=incidents)'
    WHEN 'update' THEN
      '**Run #' || p_run || ':** ' || (SELECT note FROM discovery.dq_incident_update WHERE incident_id = p_incident AND run_id = p_run)
    ELSE
      '**Resolved in run #' || p_run || '.**' || E'\n\n**Cause:** ' || coalesce(i.cause, 'not reported') || E'\n\n**Fix:** ' || coalesce(i.fix, '')
      || coalesce(E'\n\n**Fixing file:** `' || (SELECT file_name || '` (' || lower(load_kind) || ' file that arrived ' || discovery.day_label(arrived_on) || ')'
                                                 FROM discovery.dq_load WHERE load_id = i.fix_load_id), '')
      || E'\n\nEvery affected check is back to normal for ' || discovery.day_label(i.business_date) || '.'
    END
  FROM discovery.dq_incident i WHERE i.incident_id = p_incident
$$;
