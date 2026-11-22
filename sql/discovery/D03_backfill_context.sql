-- One-off: plain-language run summaries and evidence for runs recorded before evidence capture existed (runs 1-5).
-- From run 6 onward, run_checks() captures evidence automatically and run_discovery.ps1 -Summary sets the summary.
-- Evidence is rebuilt from what each run stored (column profiles, daily volume). Where a run's underlying data no longer
-- exists, the evidence is what was found during the investigation at the time, and says so.
\set ON_ERROR_STOP on
SET client_min_messages = warning;

-- ---------- Plain-language summaries ----------
UPDATE discovery.dq_run r SET summary = v.s FROM (VALUES
 (1, 'First full health check of the data. It found contacts recorded while the phones were closed, and a check that was raising false alarms about agent activity.'),
 (2, 'Removed 6,039 contacts recorded before opening time and fixed the cause. Two checks were made more precise; the sharper opening-hours check then found 8 contacts recorded just after closing.'),
 (3, 'Removed the 8 contacts recorded just after closing and fixed the cause, so contacts can no longer be recorded while the phones are closed.'),
 (4, 'Added three new checks after spotting a customer product field that was never filled in. They correctly flagged an error in how customer product records had been generated.'),
 (5, 'Rebuilt the customer product records to fix that error: products now open on realistic dates, and some close or go dormant. All three new checks now pass.')
) v(id, s) WHERE r.run_id = v.id;

-- ---------- Evidence rebuilt from each run's stored results ----------
-- Rules whose evidence reads only the discovery tables (column profile, daily volume) can be replayed for any run.
DO $$
DECLARE r record; ev jsonb;
BEGIN
  FOR r IN SELECT c.run_id, c.rule_id, q.evidence_sql
           FROM discovery.dq_check_result c JOIN discovery.dq_rule q USING (rule_id)
           WHERE c.run_id <= 5 AND coalesce(c.measured_value, 0) > 0
             AND c.rule_id IN ('CMP-018', 'VAL-024', 'VOL-011', 'VOL-012', 'VOL-014')
             AND q.evidence_sql IS NOT NULL LOOP
    EXECUTE replace(r.evidence_sql, '{run_id}', r.run_id::text) INTO ev;
    UPDATE discovery.dq_check_result SET evidence = ev WHERE run_id = r.run_id AND rule_id = r.rule_id;
  END LOOP;
  -- VOL-013 counted agents logged in from run 2 onward; run 1 counted activity records (the definition later refined)
  FOR r IN SELECT c.run_id, q.evidence_sql FROM discovery.dq_check_result c JOIN discovery.dq_rule q USING (rule_id)
           WHERE c.rule_id = 'VOL-013' AND c.run_id BETWEEN 2 AND 5 AND coalesce(c.measured_value, 0) > 0 LOOP
    EXECUTE replace(r.evidence_sql, '{run_id}', r.run_id::text) INTO ev;
    UPDATE discovery.dq_check_result SET evidence = ev WHERE run_id = r.run_id AND rule_id = 'VOL-013';
  END LOOP;
END $$;

UPDATE discovery.dq_check_result SET evidence = (
  SELECT jsonb_agg(jsonb_build_object('item', to_char(day, 'Dy Mon DD, YYYY'), 'records', row_count,
           'detail', CASE WHEN ratio >= 1 THEN round((ratio - 1) * 100) || '% above normal' ELSE round((1 - ratio) * 100) || '% below normal' END
                     || ' (' || to_char(row_count, 'FM999,999') || ' activity records vs about ' || to_char(round(baseline), 'FM999,999') || ')')
         ORDER BY abs(ratio - 1) DESC)
  FROM discovery.dq_daily_volume WHERE run_id = 1 AND table_name = 'agent_activity' AND is_outlier)
WHERE run_id = 1 AND rule_id = 'VOL-013';

-- The one duplicate contact event is an in-hours contact that no remediation touched, so it was present in every run
UPDATE discovery.dq_check_result SET evidence = (
  SELECT jsonb_agg(jsonb_build_object('item', 'Customer contacts on ' || to_char(x.ts, 'Mon DD, YYYY HH24:MI:SS'), 'records', x.n,
           'detail', x.n || ' records with the same customer, channel and second'))
  FROM (SELECT date_trunc('second', offered_ts) AS ts, count(*) AS n FROM cc.contact WHERE customer_id IS NOT NULL
        GROUP BY customer_id, channel_id, date_trunc('second', offered_ts) HAVING count(*) > 1) x)
WHERE rule_id = 'UNQ-012' AND run_id <= 5 AND measured_value = 1;

-- ---------- Evidence recorded during the investigation (underlying data later fixed or regenerated) ----------
UPDATE discovery.dq_check_result SET evidence = '[
  {"item": "Before opening time", "records": 5503, "detail": "5,503 contacts answered in the 2½ minutes before the phones opened (06:57–07:00 weekdays, 07:57–08:00 Saturdays)"},
  {"item": "Just after closing time", "records": 16, "detail": "16 contacts answered within 2 minutes after closing"},
  {"item": "Recorded during the investigation", "detail": "these contacts were later removed, so the list cannot be rebuilt"}]'::jsonb
WHERE run_id = 1 AND rule_id = 'VAL-005';

UPDATE discovery.dq_check_result SET evidence = '[
  {"item": "After closing time", "records": 8, "detail": "8 contacts recorded up to 1 min 41 s after closing, taken by agents who logged out late"},
  {"item": "Recorded during the investigation", "detail": "these contacts were later removed, so the list cannot be rebuilt"}]'::jsonb
WHERE run_id = 2 AND rule_id = 'VAL-005';

UPDATE discovery.dq_check_result SET evidence = '[
  {"item": "P2P Payments", "detail": "opened on only 4 different days"},
  {"item": "High-Yield Savings", "detail": "opened on only 35 different days"},
  {"item": "One more launch product", "detail": "not recorded at the time; the product records were later rebuilt"}]'::jsonb
WHERE run_id = 4 AND rule_id = 'VAL-025';

SELECT run_id, count(*) FILTER (WHERE evidence IS NOT NULL) AS checks_with_evidence, left(max(r.summary), 60) AS summary
FROM discovery.dq_check_result c JOIN discovery.dq_run r USING (run_id) GROUP BY 1 ORDER BY 1;
