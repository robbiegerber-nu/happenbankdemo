-- Daily load setup (v3.1): calendar rows for new business days, staging for held rows, and replay preparation.
-- Safe to re-run.
\set ON_ERROR_STOP on
SET client_min_messages = warning;
CREATE SCHEMA IF NOT EXISTS pipeline;

-- Adds the calendar row for a business day (the calendar grows one day at a time with the loads).
-- Same rules as the original calendar: Sundays and closed holidays are closed; paydays are the 1st and 15th,
-- moved back to the previous weekday; days 1-3 are the month-start window.
CREATE OR REPLACE FUNCTION pipeline.ensure_date(d date) RETURNS void LANGUAGE sql AS $$
  INSERT INTO cc.dim_date (date_key, full_date, day_name, day_of_week, is_weekend, is_holiday, holiday_name, is_center_closed,
                           week_start, month_num, month_name, quarter_num, year_num, year_month, fiscal_period,
                           is_month_start_window, is_payday)
  SELECT to_char(d, 'YYYYMMDD')::int, d, to_char(d, 'FMDay'), extract(isodow FROM d), extract(isodow FROM d) >= 6,
         h.name IS NOT NULL, h.name, extract(isodow FROM d) = 7 OR coalesce(h.closed, false),
         date_trunc('week', d)::date, extract(month FROM d), to_char(d, 'FMMonth'), extract(quarter FROM d), extract(year FROM d),
         to_char(d, 'YYYY-MM'), 'FY' || to_char(d, 'YYYY') || '-P' || to_char(d, 'MM'),
         extract(day FROM d) <= 3,
         d IN (SELECT p - CASE extract(isodow FROM p) WHEN 6 THEN 1 WHEN 7 THEN 2 ELSE 0 END
               FROM unnest(ARRAY[date_trunc('month', d)::date, date_trunc('month', d)::date + 14,
                                 (date_trunc('month', d) + interval '1 month')::date]) p)
  FROM (SELECT NULL) x
  LEFT JOIN (VALUES (date '2026-11-11', 'Veterans Day', false), (date '2026-11-26', 'Thanksgiving Day', true),
                    (date '2026-12-25', 'Christmas Day', true)) h(day, name, closed) ON h.day = d
  ON CONFLICT (date_key) DO NOTHING
$$;

-- Rows waiting for the contact they refer to (e.g. a survey whose contact file hasn't arrived yet)
CREATE TABLE IF NOT EXISTS pipeline.held_ivr_session      (LIKE cc.ivr_session);
CREATE TABLE IF NOT EXISTS pipeline.held_survey_response  (LIKE cc.survey_response);
CREATE TABLE IF NOT EXISTS pipeline.held_complaint        (LIKE cc.complaint);

-- Key columns of a cc table (used to replace or delete rows)
CREATE OR REPLACE FUNCTION pipeline.key_cols(p_feed text) RETURNS text[] LANGUAGE sql STABLE AS $$
  SELECT array_agg(a.attname::text ORDER BY array_position(i.indkey, a.attnum))
  FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
  WHERE i.indrelid = format('cc.%I', p_feed)::regclass AND i.indisprimary
$$;

-- Prepares pipeline.stage to receive one file (all columns, or just the key for a delete file)
CREATE OR REPLACE FUNCTION pipeline.prepare_stage(p_feed text, p_action text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  DROP TABLE IF EXISTS pipeline.stage;
  IF p_action = 'delete' THEN
    EXECUTE format('CREATE TABLE pipeline.stage AS SELECT %s FROM cc.%I LIMIT 0',
                   (SELECT string_agg(quote_ident(k), ', ') FROM unnest(pipeline.key_cols(p_feed)) k), p_feed);
  ELSE
    EXECUTE format('CREATE TABLE pipeline.stage (LIKE cc.%I)', p_feed);
  END IF;
END $$;

-- Moves held rows whose contact has now arrived into cc; returns how many were released
CREATE OR REPLACE FUNCTION pipeline.release_held() RETURNS int LANGUAGE plpgsql AS $$
DECLARE f text; n int; total int := 0;
BEGIN
  FOREACH f IN ARRAY ARRAY['ivr_session', 'survey_response', 'complaint'] LOOP
    EXECUTE format('WITH r AS (DELETE FROM pipeline.%I h WHERE EXISTS (SELECT 1 FROM cc.contact c WHERE c.contact_id = h.contact_id) RETURNING h.*)
                    INSERT INTO cc.%I SELECT * FROM r', 'held_' || f, f);
    GET DIAGNOSTICS n = ROW_COUNT; total := total + n;
  END LOOP;
  RETURN total;
END $$;

-- Merges pipeline.stage into cc.<feed> and records the load. Returns the load_id.
CREATE OR REPLACE FUNCTION pipeline.apply_stage(p_arrived date, p_business date, p_feed text, p_file text, p_kind text, p_action text,
                                                p_expected int, p_fixes date, p_reason text, p_fix text) RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  keys text[] := pipeline.key_cols(p_feed);
  kjoin text; cols text; sets text;
  received int; inserted int := 0; replaced int := 0; deleted int := 0; held int := 0; released int := 0; id int;
BEGIN
  SELECT count(*) INTO received FROM pipeline.stage;
  kjoin := (SELECT string_agg(format('t.%1$I = s.%1$I', k), ' AND ') FROM unnest(keys) k);

  -- rows that refer to a contact that hasn't arrived wait in pipeline.held_<feed>
  IF p_action <> 'delete' AND p_feed IN ('ivr_session', 'survey_response', 'complaint') THEN
    EXECUTE format('WITH h AS (DELETE FROM pipeline.stage s WHERE s.contact_id IS NOT NULL
                      AND NOT EXISTS (SELECT 1 FROM cc.contact c WHERE c.contact_id = s.contact_id) RETURNING s.*)
                    INSERT INTO pipeline.%I SELECT * FROM h', 'held_' || p_feed);
    GET DIAGNOSTICS held = ROW_COUNT;
  END IF;

  IF p_action = 'insert' THEN
    EXECUTE format('INSERT INTO cc.%I SELECT * FROM pipeline.stage', p_feed);
    GET DIAGNOSTICS inserted = ROW_COUNT;
  ELSIF p_action = 'upsert' THEN
    EXECUTE format('SELECT count(*) FROM pipeline.stage s WHERE EXISTS (SELECT 1 FROM cc.%I t WHERE %s)', p_feed, kjoin) INTO replaced;
    SELECT string_agg(format('%1$I = EXCLUDED.%1$I', attname), ', ') INTO sets
    FROM pg_attribute WHERE attrelid = format('cc.%I', p_feed)::regclass AND attnum > 0 AND NOT attisdropped AND attname <> ALL (keys);
    EXECUTE format('INSERT INTO cc.%I SELECT * FROM pipeline.stage ON CONFLICT (%s) DO UPDATE SET %s',
                   p_feed, (SELECT string_agg(quote_ident(k), ', ') FROM unnest(keys) k), sets);
    GET DIAGNOSTICS inserted = ROW_COUNT;
    inserted := inserted - replaced;
  ELSE
    EXECUTE format('DELETE FROM cc.%I t USING pipeline.stage s WHERE %s', p_feed, kjoin);
    GET DIAGNOSTICS deleted = ROW_COUNT;
  END IF;

  IF p_feed = 'contact' THEN released := pipeline.release_held(); END IF;

  INSERT INTO discovery.dq_load (arrived_on, business_date, feed, file_name, load_kind, action, status, expected_rows,
                                 rows_received, rows_inserted, rows_replaced, rows_deleted, rows_held, rows_released, fixes_date, reason, fix)
  VALUES (p_arrived, p_business, p_feed, p_file, p_kind, p_action,
          CASE WHEN p_expected IS NOT NULL AND p_expected <> received THEN 'Count mismatch' ELSE 'Loaded' END,
          p_expected, received, inserted, replaced, deleted, held, released, p_fixes, p_reason, p_fix)
  RETURNING load_id INTO id;
  RETURN id;
END $$;

-- A file listed in the manifest that never arrived
CREATE OR REPLACE FUNCTION pipeline.record_missing(p_arrived date, p_business date, p_feed text, p_file text, p_kind text, p_action text,
                                                   p_expected int, p_fixes date, p_reason text, p_fix text) RETURNS int LANGUAGE sql AS $$
  INSERT INTO discovery.dq_load (arrived_on, business_date, feed, file_name, load_kind, action, status, expected_rows, fixes_date, reason, fix)
  VALUES (p_arrived, p_business, p_feed, p_file, p_kind, p_action, 'Missing', p_expected, p_fixes, p_reason, p_fix)
  RETURNING load_id
$$;

-- Replay preparation: November replays the same weekdays four weeks earlier (4-18 Oct). Two agents who left in
-- October worked on those days, so they stay on the roster four weeks longer; otherwise every replayed day would
-- (wrongly) show contacts handled by agents who had left. Recorded here so it is visible and reversible.
UPDATE cc.dim_agent SET term_date = term_date + 28
WHERE agent_id IN (340, 345) AND term_date IN (date '2026-10-06', date '2026-10-27');
