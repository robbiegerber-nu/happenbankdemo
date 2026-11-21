-- Demand model: staffing per interval, expected demand, occupancy pressure (rho), reason and persona mixes.
\set ON_ERROR_STOP on
SET client_min_messages = warning;
SET max_parallel_workers_per_gather = 0;
SET work_mem = '512MB';
SELECT setseed(0.44);

-- Baseline handle seconds used for capacity math (per lane for chat)
CREATE TABLE gen.grp_param AS SELECT * FROM (VALUES (1, 480.0), (2, 760.0), (3, 520.0)) v(grp, h_sec);

-- Logged-in "Available" segments: the only time contacts can be handled.
-- Clipped to opening hours: agents who log in early or out late cannot take contacts offered while the phones
-- are closed (fix for discovery runs 1-2 finding VAL-005).
CREATE TABLE gen.seg AS
SELECT a.activity_id AS seg_id, a.agent_id, a.date_key, d.full_date AS work_date, r.grp, r.site_id, r.hire_date,
       greatest(a.state_start_ts, (d.full_date + CASE WHEN d.day_of_week = 6 THEN time '08:00' ELSE time '07:00' END)::timestamptz) AS s,
       least(a.state_end_ts, (d.full_date + CASE WHEN d.day_of_week = 6 THEN time '17:00' ELSE time '21:00' END)::timestamptz) AS e,
       CASE WHEN r.grp = 2 THEN CASE WHEN d.full_date - r.hire_date < 90 THEN 2 ELSE sh.lanes_max END ELSE 1 END AS lanes
FROM cc.agent_activity a
JOIN gen.roster r USING (agent_id)
JOIN gen.agent_shift sh USING (agent_id)
JOIN cc.dim_date d USING (date_key)
WHERE a.state = 'Available'
  AND least(a.state_end_ts, (d.full_date + CASE WHEN d.day_of_week = 6 THEN time '17:00' ELSE time '21:00' END)::timestamptz)
    > greatest(a.state_start_ts, (d.full_date + CASE WHEN d.day_of_week = 6 THEN time '08:00' ELSE time '07:00' END)::timestamptz) + interval '1 min';

-- Actual staffing per 15-minute interval
CREATE TABLE gen.seg_iv AS
SELECT s.seg_id, s.date_key, s.grp, s.lanes, gen.iv(it) AS interval_id,
       extract(epoch FROM least(s.e, it + interval '15 min') - greatest(s.s, it)) AS ov
FROM gen.seg s
CROSS JOIN LATERAL generate_series(date_trunc('hour', s.s) + floor(extract(minute FROM s.s) / 15) * interval '15 min',
                                   s.e - interval '1 ms', interval '15 min') it;

CREATE TABLE gen.staff AS
SELECT date_key, interval_id, grp, sum(ov) / 900.0 AS fte, sum(ov * lanes) / 900.0 AS lane_fte
FROM gen.seg_iv GROUP BY 1, 2, 3;

-- Headcount on roster vs. plan
CREATE TABLE gen.hc_day AS
SELECT d.date_key, d.full_date, d.day_of_week AS dow, g.grp, t.target,
       (SELECT count(*) FROM gen.roster r WHERE r.grp = g.grp AND r.hire_date <= d.full_date
          AND (r.term_date IS NULL OR r.term_date > d.full_date)) AS hc
FROM cc.dim_date d CROSS JOIN generate_series(1, 3) g(grp)
JOIN gen.target_hc t ON t.d = d.full_date AND t.grp = g.grp
WHERE NOT d.is_center_closed;

-- 2024 capacity per rostered agent by weekday x interval (the "planned" staffing shape)
CREATE TABLE gen.cap_base AS
SELECT h.grp, h.dow, i.interval_id, avg(coalesce(s.lane_fte, 0) * 900 / gp.h_sec / h.hc) AS cap_per_hc
FROM gen.hc_day h
JOIN cc.dim_date dd ON dd.date_key = h.date_key
JOIN gen.grp_param gp ON gp.grp = h.grp
CROSS JOIN cc.dim_time_interval i
LEFT JOIN gen.staff s ON s.date_key = h.date_key AND s.grp = h.grp AND s.interval_id = i.interval_id
WHERE h.full_date < date '2025-01-01' AND NOT dd.is_holiday
GROUP BY 1, 2, 3;

-- Launch lift curves: small pre-announcement bump, gamma-shaped peak, then a persistent tail
CREATE TABLE gen.launch_lift AS
SELECT l.launch_id, d.date_key,
       CASE WHEN tt.t < 0 THEN 0.08
            WHEN tt.t < l.tp THEN xx.x * exp(1 - xx.x)
            ELSE greatest(xx.x * exp(1 - xx.x), l.persist) END AS lift
FROM gen.launch_param l CROSS JOIN cc.dim_date d
CROSS JOIN LATERAL (SELECT d.full_date - l.launch_date AS t) tt
CROSS JOIN LATERAL (SELECT (tt.t + 1)::numeric / l.tp AS x) xx
WHERE tt.t >= -7;

-- Daily multiplier per reason: seasonality x incident x (1 + launch lifts)
CREATE TABLE gen.reason_day AS
WITH ll AS (
  SELECT ll.date_key, i.reason_id, ll.launch_id, ll.lift * i.peak_lift AS v
  FROM gen.launch_lift ll JOIN cc.launch_reason_impact i USING (launch_id)
), agg AS (
  SELECT date_key, reason_id, sum(v) AS tot, (array_agg(launch_id ORDER BY v DESC))[1] AS top_launch, max(v) AS top_v
  FROM ll GROUP BY 1, 2
)
SELECT d.date_key, r.reason_id, r.reason_group,
  ( CASE WHEN r.reason_group = 'Fraud/Dispute' THEN CASE d.month_num WHEN 11 THEN 1.3 WHEN 12 THEN 1.5 WHEN 1 THEN 1.15 ELSE 1 END ELSE 1 END
  * CASE WHEN r.reason_id = 3 THEN CASE d.month_num WHEN 1 THEN 1.3 WHEN 2 THEN 1.8 WHEN 3 THEN 1.6 WHEN 4 THEN 1.4 ELSE 1 END ELSE 1 END
  * CASE WHEN r.reason_id = 12 THEN CASE d.month_num WHEN 11 THEN 1.15 WHEN 12 THEN 1.3 ELSE 1 END ELSE 1 END
  * CASE WHEN r.reason_id = 11 AND d.month_num IN (7, 12) THEN 1.2 ELSE 1 END
  * CASE WHEN r.reason_id = 29 THEN CASE d.month_num WHEN 1 THEN 1.4 WHEN 2 THEN 1.2 ELSE 1 END ELSE 1 END
  * CASE WHEN r.reason_id = 8 AND d.month_num = 1 THEN 1.2 ELSE 1 END
  -- Online banking outage, 7-8 April 2026
  * CASE d.full_date
      WHEN date '2026-04-07' THEN CASE WHEN r.reason_group = 'Digital Access' THEN 4.0 WHEN r.reason_id = 38 THEN 3.0 ELSE 1 END
      WHEN date '2026-04-08' THEN CASE WHEN r.reason_group = 'Digital Access' THEN 2.5 WHEN r.reason_id = 38 THEN 2.0 ELSE 1 END
      WHEN date '2026-04-09' THEN CASE WHEN r.reason_group = 'Digital Access' OR r.reason_id = 38 THEN 1.3 ELSE 1 END
      ELSE 1 END
  * (1 + coalesce(a.tot, 0)) )::float8 AS rm,
  a.top_launch, coalesce(a.top_v / (1 + a.tot), 0)::float8 AS launch_share
FROM cc.dim_date d CROSS JOIN cc.dim_contact_reason r
LEFT JOIN agg a ON a.date_key = d.date_key AND a.reason_id = r.reason_id;

-- Reason mix per day x channel (cumulative weights for sampling)
CREATE TABLE gen.reason_mix AS
SELECT rd.date_key, c.ch, rd.reason_id, rd.reason_group, rd.top_launch, rd.launch_share,
       (sum(ww.w) OVER (PARTITION BY rd.date_key, c.ch ORDER BY rd.reason_id)
        / sum(ww.w) OVER (PARTITION BY rd.date_key, c.ch))::float8 AS cum_hi
FROM gen.reason_day rd
JOIN gen.reason_param rp USING (reason_id)
CROSS JOIN generate_series(1, 5) c(ch)
CROSS JOIN LATERAL (SELECT rd.rm * (CASE c.ch WHEN 2 THEN rp.w_chat WHEN 3 THEN rp.w_email WHEN 5 THEN rp.w_email ELSE rp.w_phone END)::float8 AS w) ww;
CREATE INDEX ON gen.reason_mix (date_key, ch, cum_hi);

CREATE TABLE gen.day_rm AS
SELECT rd.date_key, g.grp, sum(rd.rm * ww.w) / sum(ww.w) AS rm
FROM gen.reason_day rd JOIN gen.reason_param rp USING (reason_id) CROSS JOIN generate_series(1, 3) g(grp)
CROSS JOIN LATERAL (SELECT (CASE g.grp WHEN 1 THEN rp.w_phone WHEN 2 THEN rp.w_chat ELSE rp.w_email END)::float8 AS w) ww
GROUP BY 1, 2;
-- Staffing plans absorb the "new normal": demand pressure is measured against the trailing 91-day average mix,
-- so launch spikes and incidents stand out while long-run persistent volume is planned for.
ALTER TABLE gen.day_rm ADD COLUMN rm_norm float8;
UPDATE gen.day_rm d SET rm_norm = d.rm / coalesce(x.trail, d.rm)
FROM (SELECT date_key, grp, avg(rm) OVER (PARTITION BY grp ORDER BY date_key ROWS BETWEEN 91 PRECEDING AND 1 PRECEDING) AS trail
      FROM gen.day_rm) x
WHERE x.date_key = d.date_key AND x.grp = d.grp;

CREATE TABLE gen.day_noise AS
SELECT date_key, grp, 1 + random_normal(0, 0.03) AS noise FROM gen.hc_day;

-- Expected demand vs. actual capacity per interval -> rho (load / capacity)
CREATE TABLE gen.demand AS
SELECT h.date_key, cb.interval_id, h.grp, x.e_base, x.e_base * rm.rm_norm * dn.noise * (1 + random_normal(0, 0.06)) AS e_demand,
       coalesce(s.lane_fte, 0) * 900 / gp.h_sec AS cap_actual
FROM gen.hc_day h
JOIN cc.dim_date d ON d.date_key = h.date_key
JOIN gen.grp_param gp ON gp.grp = h.grp
JOIN gen.cap_base cb ON cb.grp = h.grp AND cb.dow = h.dow AND cb.cap_per_hc > 0
JOIN gen.day_rm rm ON rm.date_key = h.date_key AND rm.grp = h.grp
JOIN gen.day_noise dn ON dn.date_key = h.date_key AND dn.grp = h.grp
LEFT JOIN gen.staff s ON s.date_key = h.date_key AND s.grp = h.grp AND s.interval_id = cb.interval_id
CROSS JOIN LATERAL (SELECT cb.cap_per_hc * h.target * 0.80
   * (ARRAY[1.05,1.05,1.08,1.06,.97,.95,.93,.97,1.0,1.0,1.03,1.05])[d.month_num]
   * CASE h.dow WHEN 1 THEN 1.12 WHEN 6 THEN 0.95 ELSE 1 END
   * CASE WHEN EXISTS (SELECT 1 FROM cc.dim_date z WHERE z.is_holiday AND z.is_center_closed
                       AND z.full_date BETWEEN d.full_date - 3 AND d.full_date - 1) THEN 1.20 ELSE 1 END
   * CASE WHEN to_char(d.full_date, 'MM-DD') = '12-24' THEN 0.6 WHEN to_char(d.full_date, 'MM-DD') = '12-31' THEN 0.8 ELSE 1 END
   * CASE WHEN EXISTS (SELECT 1 FROM cc.dim_date z WHERE z.holiday_name = 'Thanksgiving Day' AND z.full_date = d.full_date - 1) THEN 0.85 ELSE 1 END
   * CASE WHEN d.is_holiday AND NOT d.is_center_closed THEN 0.85 ELSE 1 END
   * CASE WHEN d.is_month_start_window THEN 1.05 ELSE 1 END
   * CASE WHEN d.is_payday THEN 1.04 ELSE 1 END
   * CASE h.grp
       WHEN 1 THEN CASE WHEN cb.interval_id BETWEEN 28 AND 31 THEN 0.85 WHEN cb.interval_id BETWEEN 46 AND 53 THEN 1.12
                        WHEN cb.interval_id BETWEEN 68 AND 73 THEN 1.08 WHEN cb.interval_id BETWEEN 80 AND 83 THEN 0.80 ELSE 1 END
       WHEN 2 THEN CASE WHEN cb.interval_id BETWEEN 68 AND 83 THEN 1.15 ELSE 1 END
       ELSE 1 END AS e_base) x;

ALTER TABLE gen.demand ADD COLUMN rho float8;
UPDATE gen.demand SET rho = CASE WHEN cap_actual > 0.05 THEN e_demand / cap_actual END;
-- Calibrate: average 2024 load = 82% of capacity per channel group
UPDATE gen.demand dm SET e_demand = dm.e_demand * k.k, e_base = dm.e_base * k.k, rho = dm.rho * k.k
FROM (SELECT grp, 0.82 / avg(rho) AS k FROM gen.demand WHERE date_key < 20250101 AND rho IS NOT NULL GROUP BY grp) k
WHERE k.grp = dm.grp;
CREATE INDEX ON gen.demand (date_key, grp, interval_id);

-- Persona mix per channel x reason group x launch (targets weighted 3x on launch-tagged contacts)
CREATE TABLE gen.persona_mix AS
SELECT c.ch, g.reason_group, l.launch_id, p.persona_id,
       (sum(ww.w) OVER (PARTITION BY c.ch, g.reason_group, l.launch_id ORDER BY p.persona_id)
        / sum(ww.w) OVER (PARTITION BY c.ch, g.reason_group, l.launch_id))::float8 AS cum_hi
FROM generate_series(1, 5) c(ch)
CROSS JOIN gen.group_param g
CROSS JOIN (SELECT 0 AS launch_id, ARRAY[]::int[] AS targets UNION ALL SELECT launch_id, targets FROM gen.launch_param) l
CROSS JOIN gen.persona_param p
JOIN gen.persona_group_aff a ON a.persona_id = p.persona_id AND a.reason_group = g.reason_group
CROSS JOIN LATERAL (SELECT (p.share * p.contact_rate * a.m
   * CASE c.ch WHEN 2 THEN p.aff_chat WHEN 3 THEN p.aff_email WHEN 5 THEN p.aff_email ELSE p.aff_phone END
   * CASE WHEN p.persona_id = ANY (l.targets) THEN 3 ELSE 1 END)::float8 AS w) ww;
CREATE INDEX ON gen.persona_mix (ch, reason_group, launch_id, cum_hi);

-- Segment-level pressure -> target occupancy for idle-gap sizing
CREATE TABLE gen.seg_occ AS
SELECT si.seg_id, sum(si.ov * coalesce(dm.rho, 0.6)) / nullif(sum(si.ov), 0) AS rho_seg
FROM gen.seg_iv si
LEFT JOIN gen.demand dm ON dm.date_key = si.date_key AND dm.grp = si.grp AND dm.interval_id = si.interval_id
GROUP BY si.seg_id;
ALTER TABLE gen.seg_occ ADD COLUMN occ float8;
UPDATE gen.seg_occ SET occ = least(0.95, greatest(0.30, coalesce(rho_seg, 0.6) * (0.97 + 0.06 * random())));
