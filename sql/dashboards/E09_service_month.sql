-- One month of 15-minute intervals as column arrays (psql -v m=YYYY-MM).
-- d day of month, i interval id (0 = midnight), q queue, o offered, a answered, w answered within threshold, b abandoned,
-- s short abandoned, z total wait of answered contacts (seconds), f forecast contacts, h scheduled FTE, r required FTE
WITH v AS (
  SELECT extract(day FROM d.full_date)::int AS d, v.interval_id::int AS i, v.queue_id::int AS q, v.offered AS o, v.answered AS a,
         v.answered_within_sl AS w, v.abandoned AS b, v.short_abandoned AS s, round(coalesce(v.asa_sec, 0) * v.answered, 1) AS z,
         v.forecast_contacts AS f, v.scheduled_fte AS h, v.required_fte AS r
  FROM cc.interval_volume v JOIN cc.dim_date d USING (date_key)
  WHERE d.full_date >= to_date(:'m', 'YYYY-MM') AND d.full_date < to_date(:'m', 'YYYY-MM') + interval '1 month'
)
SELECT json_build_object('m', :'m', 'cols', json_build_object(
  'd', json_agg(d ORDER BY d, q, i), 'i', json_agg(i ORDER BY d, q, i), 'q', json_agg(q ORDER BY d, q, i),
  'o', json_agg(o ORDER BY d, q, i), 'a', json_agg(a ORDER BY d, q, i), 'w', json_agg(w ORDER BY d, q, i),
  'b', json_agg(b ORDER BY d, q, i), 's', json_agg(s ORDER BY d, q, i), 'z', json_agg(z ORDER BY d, q, i),
  'f', json_agg(f ORDER BY d, q, i), 'h', json_agg(h ORDER BY d, q, i), 'r', json_agg(r ORDER BY d, q, i))) FROM v;
