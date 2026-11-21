-- Contacts: agent-driven packing inside "Available" time, so agents never overlap contacts and only
-- handle work while logged in. Queue wait comes from interval pressure (rho); abandons are added per interval.
\set ON_ERROR_STOP on
SET client_min_messages = warning;
SET max_parallel_workers_per_gather = 0;
SET work_mem = '1GB';
SELECT setseed(0.45);

-- 1. Candidate contact slots per Available segment (and per chat lane)
DROP TABLE IF EXISTS gen.cand, gen.cand2, gen.cand3, gen.ans, gen.ans2, gen.abd, gen.repeat_map;
CREATE TABLE gen.cand AS
SELECT s.seg_id, l.lane, k.k, s.agent_id, s.date_key, s.work_date, s.grp, s.site_id, s.hire_date, s.lanes, so.occ, so.rho_seg,
       random() AS r_ch, random() AS r_reason, random() AS r_launch, random() AS r_persona, random() AS r_cust, random() AS r_anon,
       random() AS r_tr, random() AS r_tr2, random() AS r_hold, random() AS r_hc, random() AS r_gap, random() AS r_off,
       random() AS r_fcr, random() AS r_esc,
       random_normal() AS n_talk, random_normal() AS n_hold, random_normal() AS n_wrap
FROM gen.seg s
JOIN gen.seg_occ so USING (seg_id)
JOIN gen.grp_param gp USING (grp)
CROSS JOIN LATERAL generate_series(1, s.lanes) l(lane)
CROSS JOIN LATERAL generate_series(1, (ceil(extract(epoch FROM s.e - s.s) * so.occ / gp.h_sec * 1.35) + 2)::int) k(k);

-- 2. Channel, reason, launch tag, persona
CREATE TABLE gen.cand2 AS
SELECT c.*, x.ch, rm.reason_id, rm.reason_group,
       CASE WHEN c.r_launch < rm.launch_share THEN rm.top_launch END AS launch_id,
       CASE WHEN x.ch IN (1, 2) AND c.r_anon < .08 THEN NULL ELSE pm.persona_id END AS persona_id
FROM gen.cand c
CROSS JOIN LATERAL (SELECT CASE c.grp
    WHEN 1 THEN CASE WHEN c.r_ch < 0.02 + 0.12 * greatest(0, coalesce(c.rho_seg, .8) - 0.9) THEN 4 ELSE 1 END
    WHEN 2 THEN 2
    ELSE CASE WHEN c.r_ch < .25 THEN 5 ELSE 3 END END AS ch) x
CROSS JOIN LATERAL (SELECT m.reason_id, m.reason_group, m.top_launch, m.launch_share FROM gen.reason_mix m
                    WHERE m.date_key = c.date_key AND m.ch = x.ch AND m.cum_hi >= c.r_reason ORDER BY m.cum_hi LIMIT 1) rm
CROSS JOIN LATERAL (SELECT p.persona_id FROM gen.persona_mix p
                    WHERE p.ch = x.ch AND p.reason_group = rm.reason_group
                      AND p.launch_id = CASE WHEN c.r_launch < rm.launch_share THEN rm.top_launch ELSE 0 END
                      AND p.cum_hi >= c.r_persona ORDER BY p.cum_hi LIMIT 1) pm;
DROP TABLE gen.cand;

-- 3. Customer, queue, durations, transfers, holds, FCR, escalation, idle gap
CREATE TABLE gen.cand3 AS
SELECT c.seg_id, c.lane, c.k, c.agent_id, c.date_key, c.work_date, c.grp, c.site_id, c.lanes, c.ch, c.reason_id, c.reason_group,
       c.launch_id, c.persona_id,
       CASE WHEN c.persona_id IS NOT NULL THEN pr.lo + floor(c.r_cust * pr.cnt)::int END AS customer_id,
       gen.pick_queue(c.ch, c.reason_group, c.persona_id) AS queue_id,
       f.transferred, f.transfer_count, f.talk_sec, f.hold_count,
       CASE WHEN f.hold_count > 0 THEN round(f.hold_count * 50 * exp(0.6 * c.n_hold - 0.18))::int ELSE 0 END AS hold_sec,
       f.wrap_sec, m.learn > 1 AS learning_window, m.tenure,
       c.r_fcr < least(.97, greatest(.30, .80 + gp.fcr_adj - CASE WHEN f.transferred THEN .12 ELSE 0 END
                 - CASE WHEN m.learn > 1 THEN .10 ELSE 0 END - .08 * exp(-m.tenure / 75.0) + .03 * t.skill_z
                 - CASE WHEN c.site_id = 3 THEN .07 ELSE 0 END - CASE WHEN m.crunch THEN .04 ELSE 0 END
                 - CASE WHEN c.ch IN (3, 5) THEN .05 ELSE 0 END)) AS fcr,
       c.r_esc,
       -ln(1 - c.r_gap) * gp2.h_sec * (1 / c.occ - 1) + CASE WHEN c.k = 1 AND c.lane > 1 THEN c.r_off * 240 ELSE 0 END AS gap
FROM gen.cand2 c
JOIN gen.reason_param rp ON rp.reason_id = c.reason_id
JOIN gen.group_param gp ON gp.reason_group = c.reason_group
JOIN gen.grp_param gp2 ON gp2.grp = c.grp
JOIN gen.agent_trait t ON t.agent_id = c.agent_id
LEFT JOIN gen.persona_param pp ON pp.persona_id = c.persona_id
LEFT JOIN gen.persona_range pr ON pr.persona_id = c.persona_id
LEFT JOIN gen.launch_param lp ON lp.launch_id = c.launch_id
CROSS JOIN LATERAL (SELECT
    c.work_date - c.hire_date AS tenure,
    1 + 0.35 * exp(-(c.work_date - c.hire_date) / 75.0) AS ten_m,
    exp(-0.08 * t.skill_z) AS skill_m,
    CASE WHEN c.launch_id IS NOT NULL AND c.work_date - lp.launch_date BETWEEN 0 AND 40
         THEN 1 + 0.25 * exp(-(c.work_date - lp.launch_date) / 14.0) ELSE 1 END AS learn,
    c.work_date BETWEEN date '2025-06-01' AND date '2025-08-31' AS crunch) m
CROSS JOIN LATERAL (SELECT
    c.r_tr < least(.6, gp.transfer_p * CASE WHEN c.persona_id = 3 THEN 1.5 ELSE 1 END * CASE WHEN m.tenure < 90 THEN 1.5 ELSE 1 END
                   * CASE WHEN c.site_id = 3 THEN 1.3 ELSE 1 END * CASE WHEN m.learn > 1 THEN 1.3 ELSE 1 END
                   * CASE WHEN c.ch IN (3, 5) THEN 0.4 ELSE 1 END) AS transferred) tr
CROSS JOIN LATERAL (SELECT
    tr.transferred,
    CASE WHEN tr.transferred THEN CASE WHEN c.r_tr2 < .85 THEN 1 ELSE 2 END ELSE 0 END AS transfer_count,
    (greatest(CASE WHEN c.ch IN (2, 3, 5) THEN 60 ELSE 20 END,
              round(rp.talk_base * (CASE c.ch WHEN 1 THEN 1.0 WHEN 4 THEN 0.95 WHEN 2 THEN 1.55 WHEN 3 THEN 1.05 ELSE 0.75 END)
                    * coalesce(pp.talk_mult, 1) * m.ten_m * m.skill_m * m.learn * CASE WHEN m.crunch THEN 1.06 ELSE 1 END
                    * exp(0.45 * c.n_talk - 0.10125)))
     + 90 * CASE WHEN tr.transferred THEN CASE WHEN c.r_tr2 < .85 THEN 1 ELSE 2 END ELSE 0 END)::int AS talk_sec,
    CASE WHEN c.ch IN (1, 4) AND c.r_hold < (0.30 + gp.hold_adj + CASE WHEN m.tenure < 90 THEN .10 ELSE 0 END)
         THEN 1 + (c.r_hc < .3)::int + (c.r_hc < .08)::int ELSE 0 END AS hold_count,
    greatest(5, round((CASE c.ch WHEN 1 THEN 55 WHEN 4 THEN 60 WHEN 2 THEN 30 WHEN 3 THEN 45 ELSE 35 END)
                      * gp.wrap_mult * power(m.ten_m, 1.3) * m.skill_m * CASE WHEN m.crunch THEN 1.15 ELSE 1 END
                      * exp(0.5 * c.n_wrap - 0.125)))::int AS wrap_sec) f;
DROP TABLE gen.cand2;

-- 4. Pack contacts back-to-back (with idle gaps) inside each segment/lane; keep those that finish in time
CREATE TABLE gen.ans AS
SELECT x.*, s.s + (x.cum - x.dur) * interval '1 sec' AS answered_ts
FROM (SELECT c.*, (c.talk_sec + c.hold_sec + c.wrap_sec) AS dur,
             sum(c.gap + c.talk_sec + c.hold_sec + c.wrap_sec) OVER (PARTITION BY c.seg_id, c.lane ORDER BY c.k) AS cum
      FROM gen.cand3 c) x
JOIN gen.seg s ON s.seg_id = x.seg_id
WHERE s.s + x.cum * interval '1 sec' <= s.e;
DROP TABLE gen.cand3;
ALTER TABLE gen.ans ADD COLUMN ans_id bigserial PRIMARY KEY;

-- 5. Repeat contacts: ~55% of unresolved contacts come back within 1-5 days (we re-point a later contact to the same customer)
CREATE TABLE gen.day_list AS
SELECT date_key, work_date, count(*) AS n, min(ans_id) AS min_id FROM gen.ans GROUP BY 1, 2;
CREATE TABLE gen.ans_day AS
SELECT ans_id, date_key, row_number() OVER (PARTITION BY date_key ORDER BY ans_id) AS rn FROM gen.ans;
CREATE INDEX ON gen.ans_day (date_key, rn);

CREATE TABLE gen.repeat_map AS
SELECT DISTINCT ON (t.ans_id) t.ans_id AS target_id, a.customer_id, a.reason_id, a.reason_group, a.launch_id, a.persona_id
FROM (SELECT a.ans_id, a.work_date, a.customer_id, a.reason_id, a.reason_group, a.launch_id, a.persona_id,
             random() AS r1, random() AS r2, random() AS r3
      FROM gen.ans a WHERE NOT a.fcr AND a.customer_id IS NOT NULL) a
JOIN gen.day_list dl ON dl.work_date = a.work_date + 1 + floor(a.r1 * 5)::int
JOIN gen.ans_day t ON t.date_key = dl.date_key AND t.rn = 1 + floor(a.r2 * dl.n)::int
WHERE a.r3 < .55
ORDER BY t.ans_id, a.ans_id;

UPDATE gen.ans a SET customer_id = m.customer_id, reason_id = m.reason_id, reason_group = m.reason_group,
                     launch_id = m.launch_id, persona_id = m.persona_id,
                     queue_id = gen.pick_queue(a.ch, m.reason_group, m.persona_id)
FROM gen.repeat_map m WHERE m.target_id = a.ans_id;
DROP TABLE gen.day_list, gen.ans_day;

-- 6. Pressure at the moment of answer
CREATE TABLE gen.ans2 AS
SELECT a.*, gen.iv(a.answered_ts) AS ans_iv, dm.rho, d.day_of_week AS dow, d.full_date,
       random() AS r_w1, random() AS r_w2, random() AS r_w3, random() AS r_w4, random() AS r_w5, random() AS r_s,
       random_normal() AS n_sent, random() AS r_reply
FROM gen.ans a
JOIN cc.dim_date d ON d.date_key = a.date_key
LEFT JOIN gen.demand dm ON dm.date_key = a.date_key AND dm.grp = a.grp AND dm.interval_id = gen.iv(a.answered_ts);
DROP TABLE gen.ans;

-- 7. Abandoned contacts (phone + chat) per interval x queue, rising with pressure
CREATE TABLE gen.ans_rn AS
SELECT ans_id, date_key, ans_iv, queue_id,
       row_number() OVER (PARTITION BY date_key, ans_iv, queue_id ORDER BY ans_id) AS rn
FROM gen.ans2 WHERE ch IN (1, 2);
CREATE INDEX ON gen.ans_rn (date_key, ans_iv, queue_id, rn);

CREATE TABLE gen.abd AS
WITH g AS (
  SELECT date_key, full_date, ans_iv, queue_id, ch, grp, count(*) AS a_cnt, max(rho) AS rho
  FROM gen.ans2 WHERE ch IN (1, 2) GROUP BY 1, 2, 3, 4, 5, 6
)
SELECT g.date_key, g.full_date, g.ans_iv, g.queue_id, g.ch, g.grp, g.a_cnt, g.rho, n.i,
       random() AS r_t, random() AS r_off, random() AS r_w, random() AS r_s, random() AS r_c
FROM g
CROSS JOIN LATERAL generate_series(1, floor(g.a_cnt * least(.4, CASE g.ch
        WHEN 1 THEN .015 + .28 * greatest(0, coalesce(g.rho, .8) - .78)
        ELSE .03 + .30 * greatest(0, coalesce(g.rho, .8) - .78) END) + random())::int) n(i);
