-- Discovery engine: catalog, column profiling, daily volume, rule execution, scorecard.
-- All functions take a run_id and append their results for that run.
\set ON_ERROR_STOP on
SET client_min_messages = warning;

-- Which date column describes each table's time coverage
CREATE OR REPLACE FUNCTION discovery.date_expr(p_table text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_table
    WHEN 'contact'          THEN 'offered_ts::date'
    WHEN 'ivr_session'      THEN 'start_ts::date'
    WHEN 'survey_response'  THEN 'survey_ts::date'
    WHEN 'complaint'        THEN 'opened_ts::date'
    WHEN 'interval_volume'  THEN 'interval_ts::date'
    WHEN 'agent_schedule'   THEN 'scheduled_start_ts::date'
    WHEN 'agent_activity'   THEN 'state_start_ts::date'
    WHEN 'agent_daily'      THEN 'to_date(date_key::text, ''YYYYMMDD'')'
    WHEN 'customer'         THEN 'customer_since'
    WHEN 'customer_product' THEN 'open_date'
    WHEN 'dim_date'         THEN 'full_date'
  END;
$$;

CREATE OR REPLACE FUNCTION discovery.table_type(p_table text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_table = 'dataset_info' THEN 'Metadata'
    WHEN p_table LIKE 'dim\_%' OR p_table IN ('product_launch', 'launch_reason_impact') THEN 'Lookup'
    WHEN p_table = 'customer' THEN 'Customer'
    WHEN p_table IN ('interval_volume', 'agent_daily') THEN 'Summary'
    ELSE 'Fact' END;
$$;

-- ---------- 1. Table catalog ----------
CREATE OR REPLACE FUNCTION discovery.build_catalog(p_run int) RETURNS void LANGUAGE plpgsql AS $$
DECLARE t record; n bigint; dmin date; dmax date; dexpr text;
BEGIN
  FOR t IN SELECT c.oid, c.relname FROM pg_class c WHERE c.relnamespace = 'cc'::regnamespace AND c.relkind = 'r' ORDER BY c.relname LOOP
    EXECUTE format('SELECT count(*) FROM cc.%I', t.relname) INTO n;
    dexpr := discovery.date_expr(t.relname);
    dmin := NULL; dmax := NULL;
    IF dexpr IS NOT NULL THEN
      EXECUTE format('SELECT min(%s), max(%s) FROM cc.%I', dexpr, dexpr, t.relname) INTO dmin, dmax;
    END IF;
    INSERT INTO discovery.dq_table_catalog
    SELECT p_run, t.relname, discovery.table_type(t.relname), obj_description(t.oid, 'pg_class'), n,
           pg_total_relation_size(t.oid),
           (SELECT count(*) FROM pg_attribute a WHERE a.attrelid = t.oid AND a.attnum > 0 AND NOT a.attisdropped),
           (SELECT string_agg(a.attname, ', ' ORDER BY a.attnum) FROM pg_constraint k JOIN pg_attribute a
              ON a.attrelid = k.conrelid AND a.attnum = ANY (k.conkey) WHERE k.conrelid = t.oid AND k.contype = 'p'),
           (SELECT count(*) FROM pg_constraint k WHERE k.conrelid = t.oid AND k.contype = 'f'),
           split_part(dexpr, '::', 1), dmin, dmax;
  END LOOP;
END $$;

-- ---------- 2. Column profile + top values ----------
CREATE OR REPLACE FUNCTION discovery.profile_table(p_run int, p_table text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE c record; fam text; r record; q text; n_rows bigint;
BEGIN
  EXECUTE format('SELECT count(*) FROM cc.%I', p_table) INTO n_rows;
  FOR c IN SELECT a.attnum, a.attname, format_type(a.atttypid, a.atttypmod) AS dtype, t.typcategory
           FROM pg_attribute a JOIN pg_type t ON t.oid = a.atttypid
           WHERE a.attrelid = format('cc.%I', p_table)::regclass AND a.attnum > 0 AND NOT a.attisdropped
           ORDER BY a.attnum LOOP
    fam := CASE c.typcategory WHEN 'N' THEN 'number' WHEN 'S' THEN 'text' WHEN 'B' THEN 'boolean'
                              WHEN 'D' THEN CASE WHEN c.dtype LIKE 'time %' OR c.dtype = 'time without time zone' THEN 'time' ELSE 'date' END
                              ELSE 'other' END;
    q := format($q$
      SELECT count(%1$I) AS nn, count(DISTINCT %1$I) AS nd,
             %2$s AS mn, %3$s AS mx, %4$s AS mean, %5$s AS sd, %6$s AS pct, %7$s AS zeros, %8$s AS negs, %9$s AS empties, %10$s AS truep
      FROM cc.%11$I$q$,
      c.attname,
      CASE WHEN fam = 'boolean' THEN 'NULL::text' ELSE format('min(%I)::text', c.attname) END,
      CASE WHEN fam = 'boolean' THEN 'NULL::text' ELSE format('max(%I)::text', c.attname) END,
      CASE WHEN fam = 'number' THEN format('avg(%I)::numeric', c.attname) ELSE 'NULL::numeric' END,
      CASE WHEN fam = 'number' THEN format('stddev_samp(%I)::numeric', c.attname) ELSE 'NULL::numeric' END,
      CASE WHEN fam = 'number' THEN format('percentile_cont(ARRAY[0.01,0.25,0.5,0.75,0.99]) WITHIN GROUP (ORDER BY %I)', c.attname) ELSE 'NULL::float8[]' END,
      CASE WHEN fam = 'number' THEN format('count(*) FILTER (WHERE %I = 0)', c.attname) ELSE 'NULL::bigint' END,
      CASE WHEN fam = 'number' THEN format('count(*) FILTER (WHERE %I < 0)', c.attname) ELSE 'NULL::bigint' END,
      CASE WHEN fam = 'text' THEN format('count(*) FILTER (WHERE btrim(%I::text) = '''')', c.attname) ELSE 'NULL::bigint' END,
      CASE WHEN fam = 'boolean' THEN format('100.0 * avg(%I::int)', c.attname) ELSE 'NULL::numeric' END,
      p_table);
    EXECUTE q INTO r;
    INSERT INTO discovery.dq_column_profile VALUES (
      p_run, p_table, c.attname, c.attnum, c.dtype, fam, n_rows, n_rows - r.nn,
      round(100.0 * (n_rows - r.nn) / greatest(n_rows, 1), 3), r.nd, round(100.0 * r.nd / greatest(n_rows, 1), 3),
      r.mn, r.mx, round(r.mean, 4), round(r.sd, 4),
      r.pct[1], r.pct[2], r.pct[3], r.pct[4], r.pct[5], r.zeros, r.negs, r.empties, round(r.truep, 3));

    -- top 10 values for categorical columns (text, boolean, or numbers with few distinct values that are not keys)
    IF fam IN ('text', 'boolean') OR (fam = 'number' AND r.nd <= 25 AND c.attname NOT LIKE '%\_id') THEN
      EXECUTE format($q$
        INSERT INTO discovery.dq_distribution
        SELECT %1$s, %2$L, %3$L, row_number() OVER (ORDER BY n DESC, v NULLS LAST), v, n, round(100.0 * n / %4$s, 3)
        FROM (SELECT %3$I::text AS v, count(*) AS n FROM cc.%2$I GROUP BY 1 ORDER BY 2 DESC LIMIT 10) x$q$,
        p_run, p_table, c.attname, greatest(n_rows, 1));
    END IF;
  END LOOP;
END $$;

-- ---------- 3. Daily volume with outlier flags ----------
-- Baseline = median of the same weekday over the previous 4 weeks. Outlier = open day with ratio > 1.35 or < 0.65.
CREATE OR REPLACE FUNCTION discovery.build_daily_volume(p_run int) RETURNS void LANGUAGE plpgsql AS $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['contact','ivr_session','survey_response','complaint','interval_volume','agent_schedule','agent_activity','agent_daily'] LOOP
    EXECUTE format($q$
      INSERT INTO discovery.dq_daily_volume (run_id, table_name, day, row_count, is_center_closed)
      SELECT %1$s, %2$L, d.full_date, coalesce(x.n, 0), d.is_center_closed
      FROM cc.dim_date d LEFT JOIN (SELECT %3$s AS day, count(*) AS n FROM cc.%2$I GROUP BY 1) x ON x.day = d.full_date$q$,
      p_run, t, discovery.date_expr(t));
  END LOOP;
  -- Derived series: distinct agents logged in per day (a steadier signal of a complete activity feed than record counts)
  INSERT INTO discovery.dq_daily_volume (run_id, table_name, day, row_count, is_center_closed)
  SELECT p_run, 'agents_logged_in', d.full_date, coalesce(x.n, 0), d.is_center_closed
  FROM cc.dim_date d
  LEFT JOIN (SELECT to_date(date_key::text, 'YYYYMMDD') AS day, count(DISTINCT agent_id) AS n FROM cc.agent_activity GROUP BY 1) x
         ON x.day = d.full_date;
  UPDATE discovery.dq_daily_volume v SET baseline = b.med, ratio = v.row_count / nullif(b.med, 0),
         is_outlier = coalesce(NOT v.is_center_closed AND b.med > 0 AND (v.row_count / b.med > 1.35 OR v.row_count / b.med < 0.65), false)
  FROM (SELECT v1.table_name, v1.day,
               (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY v2.row_count) FROM discovery.dq_daily_volume v2
                WHERE v2.run_id = v1.run_id AND v2.table_name = v1.table_name AND NOT v2.is_center_closed
                  AND v2.day IN (v1.day - 7, v1.day - 14, v1.day - 21, v1.day - 28)) AS med
        FROM discovery.dq_daily_volume v1 WHERE v1.run_id = p_run) b
  WHERE v.run_id = p_run AND v.table_name = b.table_name AND v.day = b.day;
END $$;

-- ---------- 4. Run every active rule ----------
CREATE OR REPLACE FUNCTION discovery.run_checks(p_run int) RETURNS void LANGUAGE plpgsql AS $$
DECLARE r record; val numeric; st text; err text; t0 timestamptz;
BEGIN
  FOR r IN SELECT * FROM discovery.dq_rule WHERE is_active ORDER BY rule_id LOOP
    t0 := clock_timestamp(); err := NULL;
    BEGIN
      EXECUTE replace(r.check_sql, '{run_id}', p_run::text) INTO val;
      st := CASE WHEN val IS NULL THEN 'Error' WHEN val > r.fail_above THEN 'Fail' WHEN val > r.warn_above THEN 'Warn' ELSE 'Pass' END;
    EXCEPTION WHEN OTHERS THEN
      val := NULL; st := 'Error'; err := SQLERRM;
    END;
    INSERT INTO discovery.dq_check_result
    VALUES (p_run, r.rule_id, r.table_name, r.column_name, r.dimension, r.rule_name, r.severity, round(val, 4), r.unit,
            r.warn_above, r.fail_above, st, r.description, r.expected_note, err,
            (extract(epoch FROM clock_timestamp() - t0) * 1000)::int, clock_timestamp());
  END LOOP;
END $$;

-- ---------- 5. Health scorecard ----------
CREATE OR REPLACE FUNCTION discovery.build_scorecard(p_run int) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO discovery.dq_scorecard
  SELECT p_run, coalesce(table_name, '(all tables)'), coalesce(dimension, '(all dimensions)'),
         count(*), count(*) FILTER (WHERE status = 'Pass'), count(*) FILTER (WHERE status = 'Warn'),
         count(*) FILTER (WHERE status IN ('Fail', 'Error')),
         round(100.0 * sum(w * CASE status WHEN 'Pass' THEN 1 WHEN 'Warn' THEN 0.5 ELSE 0 END) / sum(w), 1),
         CASE WHEN count(*) FILTER (WHERE status IN ('Fail', 'Error')) > 0 THEN 'Fail'
              WHEN count(*) FILTER (WHERE status = 'Warn') > 0 THEN 'Warn' ELSE 'Pass' END
  FROM (SELECT table_name, dimension, status,
               CASE severity WHEN 'Critical' THEN 4 WHEN 'High' THEN 3 WHEN 'Medium' THEN 2 ELSE 1 END AS w
        FROM discovery.dq_check_result WHERE run_id = p_run) x
  GROUP BY GROUPING SETS ((table_name, dimension), (table_name), (dimension), ());
END $$;
