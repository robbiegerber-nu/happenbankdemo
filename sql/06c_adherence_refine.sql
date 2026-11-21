-- Adds realistic out-of-adherence time using only idle time inside Available segments, so no contact moves:
--   * late return from break / late login (before the segment's first contact)
--   * leaving early for the next break / early logout (after the segment's last contact)
--   * unplanned "Unavailable" aux inside the largest idle gap between contacts
-- Intensity scales with agent behaviour (chronic offenders), the summer-2025 crunch, new hires, the outsourced site, Mondays.
\set ON_ERROR_STOP on
SET client_min_messages = warning;
SET max_parallel_workers_per_gather = 0;
SET work_mem = '1GB';
SELECT setseed(0.49);

DROP TABLE IF EXISTS gen.r_seg, gen.r_ct, gen.r_gap, gen.r_new, gen.activity_new;

CREATE TABLE gen.r_seg AS
SELECT a.activity_id, a.agent_id, a.date_key, a.state, a.state_start_ts AS s, a.state_end_ts AS e,
       lag(a.activity_id) OVER w AS prev_id, lag(a.state_end_ts) OVER w AS prev_end,
       lead(a.activity_id) OVER w AS next_id, lead(a.state_start_ts) OVER w AS next_start
FROM cc.agent_activity a
WINDOW w AS (PARTITION BY a.agent_id, a.date_key ORDER BY a.state_start_ts);

-- contacts inside each Available segment
CREATE TABLE gen.r_ct AS
SELECT s.activity_id, c.answered_ts, c.wrap_end_ts,
       max(c.wrap_end_ts) OVER (PARTITION BY s.activity_id ORDER BY c.answered_ts, c.contact_id
                                ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prev_max_end
FROM gen.r_seg s
JOIN cc.contact c ON c.agent_id = s.agent_id AND c.answered_ts >= s.s AND c.answered_ts < s.e
                 AND c.answered AND c.wrap_end_ts <= s.e
WHERE s.state = 'Available';

CREATE TABLE gen.r_gap AS
SELECT activity_id, min(answered_ts) AS first_ans, max(wrap_end_ts) AS last_end,
       (array_agg(prev_max_end ORDER BY answered_ts - prev_max_end DESC) FILTER (WHERE prev_max_end < answered_ts))[1] AS gap_start,
       max(extract(epoch FROM answered_ts - prev_max_end)) FILTER (WHERE prev_max_end < answered_ts) AS gap_sec
FROM gen.r_ct GROUP BY activity_id;

CREATE TABLE gen.r_new AS
SELECT x.*,
       x.s + x.late_sec * interval '1 sec' AS new_s,
       x.e - x.early_sec * interval '1 sec' AS new_e,
       CASE WHEN x.aux_sec >= 120 THEN x.gap_start + interval '30 sec' END AS aux_s,
       CASE WHEN x.aux_sec >= 120 THEN x.gap_start + interval '30 sec' + x.aux_sec * interval '1 sec' END AS aux_e
FROM (
  SELECT s.activity_id, s.agent_id, s.date_key, s.s, s.e, s.prev_id, s.next_id, g.gap_start,
         -- late start: limited to the idle time before the first contact (or 30% of an empty segment)
         CASE WHEN r.r1 < .7 THEN least(-ln(1 - r.r2) * 180 * m.m,
                   greatest(0, coalesce(extract(epoch FROM g.first_ans - s.s) - 1, extract(epoch FROM s.e - s.s) * .3))) ELSE 0 END AS late_sec,
         CASE WHEN r.r3 < .5 THEN least(-ln(1 - r.r4) * 90 * m.m,
                   greatest(0, coalesce(extract(epoch FROM s.e - g.last_end) - 1, extract(epoch FROM s.e - s.s) * .3))) ELSE 0 END AS early_sec,
         CASE WHEN r.r5 < least(.95, .75 * m.m) AND g.gap_sec > 200
              THEN least(g.gap_sec - 60, 240 + -ln(1 - r.r6) * 600 * m.m) ELSE 0 END AS aux_sec
  FROM gen.r_seg s
  JOIN gen.agent_day ad ON ad.agent_id = s.agent_id AND ad.date_key = s.date_key
  LEFT JOIN gen.r_gap g ON g.activity_id = s.activity_id
  CROSS JOIN LATERAL (SELECT random() r1, random() r2, random() r3, random() r4, random() r5, random() r6) r
  CROSS JOIN LATERAL (SELECT (CASE WHEN ad.offender THEN 2.5 ELSE 1 END) * (CASE WHEN ad.crunch THEN 1.4 ELSE 1 END)
                           * (CASE WHEN ad.tenure_days < 90 THEN 1.3 ELSE 1 END) * (CASE WHEN ad.site_id = 3 THEN 1.3 ELSE 1 END)
                           * (CASE WHEN ad.dow = 1 OR ad.post_holiday THEN 1.2 ELSE 1 END) AS m) m
  WHERE s.state = 'Available'
) x;

-- Rebuild the activity table
CREATE TABLE gen.activity_new AS
-- non-Available rows: stretch to absorb late returns / early departures of neighbouring Available segments
SELECT s.agent_id, s.date_key, s.state,
       coalesce(pv.new_e, s.s) AS st,          -- previous Available segment ended early -> this state starts earlier
       coalesce(nx.new_s, s.e) AS en           -- next Available segment starts late -> this state runs longer
FROM gen.r_seg s
LEFT JOIN gen.r_new pv ON pv.activity_id = s.prev_id AND s.prev_end = pv.e
LEFT JOIN gen.r_new nx ON nx.activity_id = s.next_id AND s.next_start = nx.s
WHERE s.state <> 'Available'
UNION ALL
SELECT n.agent_id, n.date_key, 'Available', n.new_s, coalesce(n.aux_s, n.new_e) FROM gen.r_new n
UNION ALL
SELECT n.agent_id, n.date_key, 'Unavailable', n.aux_s, n.aux_e FROM gen.r_new n WHERE n.aux_s IS NOT NULL
UNION ALL
SELECT n.agent_id, n.date_key, 'Available', n.aux_e, n.new_e FROM gen.r_new n WHERE n.aux_s IS NOT NULL;

TRUNCATE cc.agent_activity;
INSERT INTO cc.agent_activity (activity_id, agent_id, date_key, state, state_start_ts, state_end_ts, duration_sec)
SELECT row_number() OVER (ORDER BY agent_id, st), agent_id, date_key, state, st, en, round(extract(epoch FROM en - st))::int
FROM gen.activity_new WHERE en > st + interval '1 sec';

DROP TABLE gen.r_seg, gen.r_ct, gen.r_gap, gen.r_new, gen.activity_new;
VACUUM ANALYZE cc.agent_activity;
