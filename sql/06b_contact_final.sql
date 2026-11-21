-- Final contact table: queue waits (from pressure), abandons, timestamps, sentiment, repeats, chat concurrency.
-- Re-runnable on its own to re-tune wait-time parameters.
\set ON_ERROR_STOP on
SET client_min_messages = warning;
SET max_parallel_workers_per_gather = 0;
SET work_mem = '1GB';
SELECT setseed(0.46);
TRUNCATE cc.contact;
DROP TABLE IF EXISTS gen.contact_stage;

CREATE TABLE gen.contact_stage AS
-- ---------- Answered / handled contacts ----------
SELECT a.customer_id, a.ch::smallint AS channel_id, a.queue_id, a.agent_id, a.reason_id::smallint, a.launch_id::smallint,
       o.offered_ts, a.answered_ts, NULL::timestamptz AS abandoned_ts,
       a.answered_ts + (a.talk_sec + a.hold_sec) * interval '1 sec' AS customer_end_ts,
       a.answered_ts + (a.talk_sec + a.hold_sec + a.wrap_sec) * interval '1 sec' AS wrap_end_ts,
       round(extract(epoch FROM a.answered_ts - o.offered_ts))::int AS queue_wait_sec,
       a.talk_sec, a.hold_sec, a.hold_count::smallint, a.wrap_sec, (a.talk_sec + a.hold_sec + a.wrap_sec) AS handle_sec,
       true AS answered, false AS abandoned, false AS short_abandon,
       round(extract(epoch FROM a.answered_ts - o.offered_ts)) <= q.sl_threshold_sec AS met_service_level,
       a.transferred, a.transfer_count::smallint, a.fcr AS first_contact_resolved,
       a.r_esc < .02 + CASE WHEN a.reason_group = 'Complaint' THEN .18 ELSE 0 END + CASE WHEN NOT a.fcr THEN .03 ELSE 0 END AS escalated,
       round(least(1, greatest(-1, 0.25 + gp.sent_adj
             - CASE WHEN a.ch IN (1, 2) THEN least(.5, w.wait / 600.0) WHEN a.ch = 4 THEN least(.3, w.wait / 14400.0) ELSE least(.3, w.wait / 172800.0) END
             - CASE WHEN a.fcr THEN 0 ELSE .25 END - CASE WHEN a.transferred THEN .10 ELSE 0 END
             + coalesce(lp.sent_adj, 0) + .25 * a.n_sent))::numeric, 3) AS sentiment_score,
       CASE WHEN a.ch IN (3, 5) THEN (1 + (NOT a.fcr)::int + (a.r_reply < .2)::int)::smallint END AS reply_count
FROM gen.ans2 a
JOIN cc.dim_queue q ON q.queue_id = a.queue_id
JOIN gen.group_param gp ON gp.reason_group = a.reason_group
LEFT JOIN gen.launch_param lp ON lp.launch_id = a.launch_id
CROSS JOIN LATERAL (SELECT least(greatest(coalesce(a.rho, .8), .3), 1.6) AS rc) r
CROSS JOIN LATERAL (SELECT least(.7, greatest(.03, 1.55 - 1.3 * r.rc)) AS p0) p
CROSS JOIN LATERAL (SELECT CASE a.ch
    WHEN 1 THEN least(2400, greatest(1, extract(epoch FROM a.answered_ts - (a.full_date + CASE WHEN a.dow = 6 THEN time '08:00' ELSE time '07:00' END)::timestamptz)),
                CASE WHEN a.r_w1 < p.p0 THEN 1 + a.r_w2 * 5
                     ELSE 6 - ln(1 - a.r_w2) * 16 * exp(3.2 * (r.rc - .8)) * CASE WHEN a.queue_id = 2 THEN .7 ELSE 1 END END)
    WHEN 2 THEN least(2400, greatest(1, extract(epoch FROM a.answered_ts - (a.full_date + CASE WHEN a.dow = 6 THEN time '08:00' ELSE time '07:00' END)::timestamptz)),
                CASE WHEN a.r_w1 < p.p0 THEN 2 + a.r_w2 * 6 ELSE 8 - ln(1 - a.r_w2) * 30 * exp(3.2 * (r.rc - .8)) END)
    WHEN 4 THEN least(28800, 300 - ln(1 - a.r_w2) * 2400 * exp(2.5 * (r.rc - .8)))
    ELSE least(432000, -ln(1 - a.r_w2) * 14400 * exp(2.5 * (r.rc - .8))
               + CASE WHEN extract(hour FROM a.answered_ts) < 10 AND a.r_w3 < .55 THEN (6 + 8 * a.r_w4) * 3600 ELSE 0 END
               + CASE WHEN a.dow = 1 AND extract(hour FROM a.answered_ts) < 13 AND a.r_w5 < .6 THEN (10 + 30 * a.r_w4) * 3600 ELSE 0 END)
  END AS wait) w
CROSS JOIN LATERAL (SELECT greatest(a.answered_ts - w.wait * interval '1 sec', timestamptz '2024-01-01 00:00') AS offered_ts) o

UNION ALL
-- ---------- Abandoned contacts (no agent, no talk/wrap) ----------
SELECT CASE WHEN t.persona_id IS NOT NULL THEN pr.lo + floor(b.r_c * pr.cnt)::int END,
       b.ch::smallint, b.queue_id, NULL::int, t.reason_id::smallint, t.launch_id::smallint,
       ab.offered_ts, NULL, ab.offered_ts + ab.wait * interval '1 sec', NULL, NULL,
       round(ab.wait)::int, 0, 0, 0::smallint, 0, 0,
       false, true, round(ab.wait) < 5, false,
       false, 0::smallint, NULL, false, NULL, NULL
FROM gen.abd b
JOIN gen.ans_rn rn ON rn.date_key = b.date_key AND rn.ans_iv = b.ans_iv AND rn.queue_id = b.queue_id
                  AND rn.rn = 1 + floor(b.r_t * b.a_cnt)::int
JOIN gen.ans2 t ON t.ans_id = rn.ans_id
LEFT JOIN gen.persona_range pr ON pr.persona_id = t.persona_id
CROSS JOIN LATERAL (SELECT least(greatest(coalesce(b.rho, .8), .3), 1.6) AS rc) r
CROSS JOIN LATERAL (SELECT (b.full_date + time '00:00' + b.ans_iv * interval '15 min')::timestamptz + b.r_off * interval '900 sec' AS offered_ts,
                           CASE WHEN b.r_s < .18 THEN 1 + 4 * b.r_w
                                ELSE least(1500, 5 - ln(1 - b.r_w) * CASE b.ch WHEN 1 THEN 55 ELSE 90 END * exp(1.5 * (r.rc - .8))) END AS wait) ab;

INSERT INTO cc.contact (contact_id, customer_id, channel_id, queue_id, agent_id, reason_id, launch_id, date_key, interval_id,
  offered_ts, answered_ts, abandoned_ts, customer_end_ts, wrap_end_ts, queue_wait_sec, talk_sec, hold_sec, hold_count, wrap_sec,
  handle_sec, answered, abandoned, short_abandon, met_service_level, transferred, transfer_count, first_contact_resolved,
  escalated, sentiment_score, reply_count)
SELECT row_number() OVER (ORDER BY offered_ts, agent_id NULLS LAST), customer_id, channel_id, queue_id, agent_id, reason_id, launch_id,
       gen.dk(offered_ts), gen.iv(offered_ts),
       offered_ts, answered_ts, abandoned_ts, customer_end_ts, wrap_end_ts, queue_wait_sec, talk_sec, hold_sec, hold_count, wrap_sec,
       handle_sec, answered, abandoned, short_abandon, met_service_level, transferred, transfer_count, first_contact_resolved,
       escalated, sentiment_score, reply_count
FROM gen.contact_stage;
DROP TABLE gen.contact_stage;

-- Repeat within 7 days (same customer contacts again, any channel)
UPDATE cc.contact c SET repeat_within_7d = true
FROM (SELECT contact_id, lead(offered_ts) OVER (PARTITION BY customer_id ORDER BY offered_ts) AS nxt
      FROM cc.contact WHERE customer_id IS NOT NULL) x
WHERE x.contact_id = c.contact_id AND x.nxt <= c.offered_ts + interval '7 days';

-- Chat concurrency: chats the agent had open when this chat was answered (including this one)
CREATE INDEX IF NOT EXISTS contact_agent_ans_idx ON cc.contact (agent_id, answered_ts);
UPDATE cc.contact c SET concurrent_chats = x.n
FROM (SELECT c1.contact_id,
             (SELECT count(*) FROM cc.contact c2
              WHERE c2.agent_id = c1.agent_id AND c2.channel_id = 2
                AND c2.answered_ts BETWEEN c1.answered_ts - interval '3 hours' AND c1.answered_ts
                AND c2.customer_end_ts > c1.answered_ts)::smallint AS n
      FROM cc.contact c1 WHERE c1.channel_id = 2 AND c1.answered) x
WHERE x.contact_id = c.contact_id;
VACUUM ANALYZE cc.contact;
