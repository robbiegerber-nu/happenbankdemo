-- One metric of the stability cube as JSON (run once per metric with: psql -v m=<metric id> -f this file).
-- Every member gets aligned daily arrays from the first to the last day of data; days with no data are null.
-- Shape: { metric, start, end, dims: { <dim>: { <member>: { x: [...], n: [...], k?: [...] } } } }
WITH span AS (SELECT min(d) AS d0, max(d) AS d1 FROM dash.stability),
days AS (SELECT generate_series(d0, d1, interval '1 day')::date AS d FROM span),
mem AS (SELECT DISTINCT dim, member FROM dash.stability WHERE metric = :'m'),
series AS (
  SELECT mem.dim, mem.member,
         -- k (sample count) is only sent when it differs from n: agent-day metrics, where n is minutes
         jsonb_build_object(
           'x', jsonb_agg(CASE WHEN s.x = trunc(s.x) THEN trunc(s.x) ELSE round(s.x, 2) END ORDER BY days.d),
           'n', jsonb_agg(CASE WHEN s.n = trunc(s.n) THEN trunc(s.n) ELSE round(s.n, 2) END ORDER BY days.d),
           'k', jsonb_agg(s.k ORDER BY days.d))
         - CASE WHEN :'m' IN ('adherence', 'occupancy') THEN '' ELSE 'k' END AS arr
  FROM mem CROSS JOIN days
  LEFT JOIN dash.stability s ON s.metric = :'m' AND s.dim = mem.dim AND s.member = mem.member AND s.d = days.d
  GROUP BY mem.dim, mem.member
)
SELECT json_build_object(
  'metric', :'m',
  'start', (SELECT d0 FROM span), 'end', (SELECT d1 FROM span),
  'dims', (SELECT jsonb_object_agg(dim, members) FROM (
             SELECT dim, jsonb_object_agg(member, arr) AS members FROM series GROUP BY dim) x)
);
