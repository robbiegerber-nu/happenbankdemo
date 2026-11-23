-- One month of dash.pi_month as column arrays (psql -v m=YYYY-MM). Response parts of contacts are left out when all zero.
WITH x AS (SELECT * FROM dash.pi_month WHERE mk = replace(:'m', '-', '')::int)
SELECT json_build_object('m', :'m', 'cols', json_build_object(
  'x', json_agg(cell ORDER BY cell, c, r), 'c', json_agg(c ORDER BY cell, c, r), 'r', json_agg(r ORDER BY cell, c, r),
  'o', json_agg(o ORDER BY cell, c, r), 'a', json_agg(a ORDER BY cell, c, r), 'f', json_agg(f ORDER BY cell, c, r), 'e', json_agg(e ORDER BY cell, c, r),
  'sv', json_agg(sv ORDER BY cell, c, r), 'sat', json_agg(sat ORDER BY cell, c, r), 'net', json_agg(net ORDER BY cell, c, r), 'nn', json_agg(nn ORDER BY cell, c, r), 'cp', json_agg(cp ORDER BY cell, c, r)))
FROM x;
