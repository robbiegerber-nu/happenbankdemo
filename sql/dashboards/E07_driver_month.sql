-- One month of a driver cube as column arrays (psql -v m=YYYY-MM -v t=driver or driver_agent).
SELECT json_build_object('m', :'m', 'cols', json_object_agg(col, vals)) FROM (
  SELECT e.key AS col, json_agg(e.value ORDER BY b.n) AS vals
  FROM (SELECT row_number() OVER (ORDER BY x) AS n, to_jsonb(x) - 'm' AS j FROM dash.:t x WHERE m = :'m') b
  CROSS JOIN LATERAL jsonb_each(b.j) e
  GROUP BY e.key) c;
