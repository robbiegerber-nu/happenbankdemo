-- Names and complete months for the Performance Driver Explorer.
WITH t AS (SELECT max(d.full_date) AS thru FROM cc.interval_volume v JOIN cc.dim_date d USING (date_key))
SELECT json_build_object(
  'data_through', (SELECT thru FROM t),
  'generated_at', to_char(now() AT TIME ZONE 'America/Chicago', 'YYYY-MM-DD"T"HH24:MI:SS'),
  'months', (SELECT json_agg(m ORDER BY m) FROM (SELECT DISTINCT m FROM dash.driver) x
             WHERE (to_date(m, 'YYYY-MM') + interval '1 month - 1 day')::date <= (SELECT thru FROM t)),
  'names', (SELECT json_object_agg(k, v) FROM (
             SELECT k, json_agg(json_build_object('id', id, 'name', name, 'parent', parent, 'extra', extra) ORDER BY id) AS v
             FROM dash.driver_name GROUP BY k) y));
