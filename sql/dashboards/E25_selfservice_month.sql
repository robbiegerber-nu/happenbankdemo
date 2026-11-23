-- One month of dash.ss_contact as column arrays (psql -v m=YYYY-MM).
SELECT json_build_object('m', :'m', 'cols', json_build_object(
  'p', json_agg(p ORDER BY p, c, r), 'c', json_agg(c ORDER BY p, c, r), 'r', json_agg(r ORDER BY p, c, r),
  'o', json_agg(o ORDER BY p, c, r), 'a', json_agg(a ORDER BY p, c, r), 'h', json_agg(h ORDER BY p, c, r), 'f', json_agg(f ORDER BY p, c, r),
  'i', json_agg(i ORDER BY p, c, r), 'e', json_agg(e ORDER BY p, c, r), 'sv', json_agg(sv ORDER BY p, c, r), 'sat', json_agg(sat ORDER BY p, c, r)))
FROM dash.ss_contact WHERE mk = replace(:'m', '-', '')::int;
