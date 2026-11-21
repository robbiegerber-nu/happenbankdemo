-- Dashboard-ready views
\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE OR REPLACE VIEW cc.v_contact_detail AS
SELECT c.contact_id, c.date_key, d.full_date, d.day_name, d.week_start, d.year_month, d.year_num, d.quarter_num,
       c.interval_id, ti.interval_label, ti.hour_of_day, ti.daypart,
       ch.channel_name, q.queue_name, q.skill, q.sl_threshold_sec, q.sl_target_pct,
       c.agent_id, a.display_name AS agent_name, a.role AS agent_role, a.hire_date AS agent_hire_date,
       (d.full_date - a.hire_date) AS agent_tenure_days,
       t.team_name, s.site_name, s.is_outsourced, sup.display_name AS supervisor_name,
       r.reason, r.reason_group, pl.launch_name, pl.launch_type,
       c.customer_id, p.persona_name, cu.age, cu.age_band, cu.gender, cu.income_band, cu.segment, cu.digital_enrolled,
       cu.preferred_language, rg.state_code, rg.metro, rg.area_type,
       c.offered_ts, c.answered_ts, c.abandoned_ts, c.customer_end_ts, c.wrap_end_ts,
       c.queue_wait_sec, c.talk_sec, c.hold_sec, c.hold_count, c.wrap_sec, c.handle_sec,
       c.answered, c.abandoned, c.short_abandon,
       (c.answered OR (c.abandoned AND NOT c.short_abandon)) AS is_sl_eligible,
       c.met_service_level, c.transferred, c.transfer_count, c.first_contact_resolved, c.repeat_within_7d, c.escalated,
       c.sentiment_score, c.concurrent_chats, c.reply_count,
       sv.csat, sv.nps, sv.ces
FROM cc.contact c
JOIN cc.dim_date d ON d.date_key = c.date_key
JOIN cc.dim_time_interval ti ON ti.interval_id = c.interval_id
JOIN cc.dim_channel ch ON ch.channel_id = c.channel_id
JOIN cc.dim_queue q ON q.queue_id = c.queue_id
JOIN cc.dim_contact_reason r ON r.reason_id = c.reason_id
LEFT JOIN cc.dim_agent a ON a.agent_id = c.agent_id
LEFT JOIN cc.dim_team t ON t.team_id = a.team_id
LEFT JOIN cc.dim_site s ON s.site_id = t.site_id
LEFT JOIN cc.dim_agent sup ON sup.agent_id = t.supervisor_id
LEFT JOIN cc.product_launch pl ON pl.launch_id = c.launch_id
LEFT JOIN cc.customer cu ON cu.customer_id = c.customer_id
LEFT JOIN cc.dim_persona p ON p.persona_id = cu.persona_id
LEFT JOIN cc.dim_region rg ON rg.region_id = cu.region_id
LEFT JOIN cc.survey_response sv ON sv.contact_id = c.contact_id;
COMMENT ON VIEW cc.v_contact_detail IS 'One row per contact with every descriptive attribute (agent name, team, site, supervisor, persona, demographics, launch) and all durations.';

CREATE OR REPLACE VIEW cc.v_service_level_interval AS
SELECT iv.interval_ts, iv.date_key, d.full_date, d.day_name, iv.interval_id, ti.interval_label, ti.daypart,
       ch.channel_name, q.queue_name, q.sl_threshold_sec, q.sl_target_pct,
       iv.forecast_contacts, iv.offered, iv.answered, iv.answered_within_sl, iv.abandoned, iv.short_abandoned,
       iv.service_level_pct, iv.abandon_rate AS abandon_pct, iv.asa_sec, iv.forecast_aht_sec, iv.actual_aht_sec,
       iv.scheduled_fte, iv.required_fte, round(iv.scheduled_fte - iv.required_fte, 2) AS staffing_gap_fte,
       round(100.0 * (iv.offered - iv.forecast_contacts) / nullif(iv.forecast_contacts, 0), 1) AS forecast_error_pct
FROM cc.interval_volume iv
JOIN cc.dim_date d ON d.date_key = iv.date_key
JOIN cc.dim_time_interval ti ON ti.interval_id = iv.interval_id
JOIN cc.dim_queue q ON q.queue_id = iv.queue_id
JOIN cc.dim_channel ch ON ch.channel_id = q.channel_id;
COMMENT ON VIEW cc.v_service_level_interval IS '15-minute service level, ASA, abandon %, forecast vs actual and staffing by queue.';

CREATE OR REPLACE VIEW cc.v_service_level_daily AS
SELECT c.date_key, d.full_date, d.day_name, d.week_start, d.year_month, ch.channel_name, q.queue_name, q.sl_threshold_sec, q.sl_target_pct,
       count(*) AS offered,
       count(*) FILTER (WHERE c.answered) AS answered,
       count(*) FILTER (WHERE c.abandoned) AS abandoned,
       count(*) FILTER (WHERE c.short_abandon) AS short_abandoned,
       count(*) FILTER (WHERE c.answered AND c.met_service_level) AS answered_within_sl,
       round(100.0 * count(*) FILTER (WHERE c.answered AND c.met_service_level)
             / nullif(count(*) FILTER (WHERE c.answered OR (c.abandoned AND NOT c.short_abandon)), 0), 2) AS service_level_pct,
       round(avg(c.queue_wait_sec) FILTER (WHERE c.answered), 1) AS asa_sec,
       max(c.queue_wait_sec) AS longest_wait_sec,
       round(100.0 * count(*) FILTER (WHERE c.abandoned) / count(*), 2) AS abandon_pct,
       round(avg(c.handle_sec) FILTER (WHERE c.answered), 1) AS aht_sec
FROM cc.contact c
JOIN cc.dim_date d ON d.date_key = c.date_key
JOIN cc.dim_queue q ON q.queue_id = c.queue_id
JOIN cc.dim_channel ch ON ch.channel_id = c.channel_id
GROUP BY c.date_key, d.full_date, d.day_name, d.week_start, d.year_month, ch.channel_name, q.queue_name, q.sl_threshold_sec, q.sl_target_pct;
COMMENT ON VIEW cc.v_service_level_daily IS 'Daily service level %, ASA, longest wait, abandon % and AHT by channel and queue.';

CREATE OR REPLACE VIEW cc.v_handle_time AS
SELECT d.year_month, ch.channel_name, t.team_name, s.site_name, a.agent_id, a.display_name AS agent_name, r.reason_group, r.reason,
       count(*) AS contacts_handled,
       round(avg(c.talk_sec), 1) AS avg_talk_sec, round(avg(c.hold_sec), 1) AS avg_hold_sec,
       round(avg(c.wrap_sec), 1) AS avg_wrap_sec, round(avg(c.handle_sec), 1) AS aht_sec,
       round(percentile_cont(0.9) WITHIN GROUP (ORDER BY c.handle_sec)::numeric, 1) AS p90_handle_sec
FROM cc.contact c
JOIN cc.dim_date d ON d.date_key = c.date_key
JOIN cc.dim_channel ch ON ch.channel_id = c.channel_id
JOIN cc.dim_agent a ON a.agent_id = c.agent_id
JOIN cc.dim_team t ON t.team_id = a.team_id
JOIN cc.dim_site s ON s.site_id = t.site_id
JOIN cc.dim_contact_reason r ON r.reason_id = c.reason_id
WHERE c.answered
GROUP BY d.year_month, ch.channel_name, t.team_name, s.site_name, a.agent_id, a.display_name, r.reason_group, r.reason;
COMMENT ON VIEW cc.v_handle_time IS 'Monthly talk, hold, wrap and handle time by channel, agent, team, site and reason.';

CREATE OR REPLACE VIEW cc.v_agent_adherence AS
SELECT ad.agent_id, a.display_name AS agent_name, a.employee_number, a.role, t.team_name, s.site_name, s.is_outsourced,
       sup.display_name AS supervisor_name, ch.channel_name AS primary_channel,
       ad.date_key, d.full_date, d.day_name, d.week_start, d.year_month, (d.full_date - a.hire_date) AS tenure_days,
       ad.is_pto, ad.is_absent, ad.is_training_day,
       ad.scheduled_min, ad.logged_in_min, ad.in_adherence_min, ad.adherence_pct, ad.conformance_pct,
       ad.late_login_min, ad.early_logout_min, ad.extended_break_min, ad.unplanned_aux_min,
       ad.available_min, ad.handle_min, ad.occupancy_pct,
       ad.shrinkage_break_min, ad.shrinkage_lunch_min, ad.shrinkage_training_min, ad.shrinkage_coaching_min,
       ad.shrinkage_meeting_min, ad.shrinkage_absence_min, ad.contacts_handled
FROM cc.agent_daily ad
JOIN cc.dim_agent a ON a.agent_id = ad.agent_id
JOIN cc.dim_team t ON t.team_id = a.team_id
JOIN cc.dim_site s ON s.site_id = t.site_id
JOIN cc.dim_agent sup ON sup.agent_id = t.supervisor_id
JOIN cc.dim_channel ch ON ch.channel_id = a.primary_channel_id
JOIN cc.dim_date d ON d.date_key = ad.date_key;
COMMENT ON VIEW cc.v_agent_adherence IS 'Daily schedule adherence, conformance, occupancy and shrinkage per agent with team, site and supervisor. Use weighted averages: sum(in_adherence_min)/sum(scheduled_min).';

CREATE OR REPLACE VIEW cc.v_agent_scorecard AS
WITH c AS (
  SELECT c.agent_id, d.year_month, count(*) AS contacts, avg(c.handle_sec) AS aht, avg(c.wrap_sec) AS wrap,
         avg(c.first_contact_resolved::int) AS fcr, avg(c.transferred::int) AS transfer_rate
  FROM cc.contact c JOIN cc.dim_date d ON d.date_key = c.date_key WHERE c.answered GROUP BY 1, 2
), s AS (
  SELECT sv.agent_id, d.year_month, count(*) AS surveys, avg((sv.csat >= 4)::int) AS csat_pct,
         avg((sv.nps >= 9)::int) - avg((sv.nps <= 6)::int) AS nps
  FROM cc.survey_response sv JOIN cc.dim_date d ON d.date_key = sv.date_key GROUP BY 1, 2
), w AS (
  SELECT ad.agent_id, d.year_month,
         sum(ad.in_adherence_min) FILTER (WHERE NOT ad.is_pto AND NOT ad.is_absent)
           / nullif(sum(ad.scheduled_min) FILTER (WHERE NOT ad.is_pto AND NOT ad.is_absent), 0) AS adherence,
         sum(ad.handle_min) / nullif(sum(ad.available_min), 0) AS occupancy_raw,
         avg(ad.occupancy_pct) AS occupancy_pct, avg(ad.quality_score) AS quality,
         count(*) FILTER (WHERE ad.is_absent) AS absent_days
  FROM cc.agent_daily ad JOIN cc.dim_date d ON d.date_key = ad.date_key GROUP BY 1, 2
)
SELECT a.agent_id, a.display_name AS agent_name, a.role, t.team_name, st.site_name, sup.display_name AS supervisor_name,
       ch.channel_name AS primary_channel, w.year_month,
       coalesce(c.contacts, 0) AS contacts_handled, round(c.aht, 1) AS aht_sec, round(c.wrap, 1) AS avg_wrap_sec,
       round(100 * c.fcr, 1) AS fcr_pct, round(100 * c.transfer_rate, 1) AS transfer_pct,
       s.surveys, round(100 * s.csat_pct, 1) AS csat_pct, round(100 * s.nps, 1) AS nps,
       round(100 * w.adherence, 1) AS adherence_pct, round(w.occupancy_pct, 1) AS occupancy_pct,
       round(w.quality, 1) AS quality_score, w.absent_days
FROM w
JOIN cc.dim_agent a ON a.agent_id = w.agent_id
JOIN cc.dim_team t ON t.team_id = a.team_id
JOIN cc.dim_site st ON st.site_id = t.site_id
JOIN cc.dim_agent sup ON sup.agent_id = t.supervisor_id
JOIN cc.dim_channel ch ON ch.channel_id = a.primary_channel_id
LEFT JOIN c ON c.agent_id = w.agent_id AND c.year_month = w.year_month
LEFT JOIN s ON s.agent_id = w.agent_id AND s.year_month = w.year_month;
COMMENT ON VIEW cc.v_agent_scorecard IS 'Monthly agent scorecard: volume, AHT, wrap, FCR, transfers, CSAT, NPS, adherence, occupancy, quality.';

CREATE OR REPLACE VIEW cc.v_launch_impact AS
WITH rel AS (SELECT DISTINCT launch_id, reason_id FROM cc.launch_reason_impact),
daily AS (
  SELECT l.launch_id, c.date_key,
         count(*) AS all_contacts,
         count(*) FILTER (WHERE rel.reason_id IS NOT NULL) AS related_reason_contacts,
         count(*) FILTER (WHERE c.launch_id = l.launch_id) AS launch_tagged_contacts,
         avg(c.handle_sec) FILTER (WHERE c.answered) AS aht,
         avg(c.first_contact_resolved::int) FILTER (WHERE c.answered) AS fcr,
         avg(c.sentiment_score) AS sentiment
  FROM cc.product_launch l
  JOIN cc.contact c ON c.date_key BETWEEN to_char(l.launch_date - 56, 'YYYYMMDD')::int AND to_char(l.launch_date + 84, 'YYYYMMDD')::int
  LEFT JOIN rel ON rel.launch_id = l.launch_id AND rel.reason_id = c.reason_id
  GROUP BY l.launch_id, c.date_key
), surveys AS (
  SELECT l.launch_id, sv.date_key, avg((sv.csat >= 4)::int) AS csat
  FROM cc.product_launch l
  JOIN cc.survey_response sv ON sv.date_key BETWEEN to_char(l.launch_date - 56, 'YYYYMMDD')::int AND to_char(l.launch_date + 84, 'YYYYMMDD')::int
  GROUP BY 1, 2
), j AS (
  SELECT l.launch_id, l.launch_name, l.launch_type, l.launch_date, l.target_personas, d.full_date, d.day_of_week,
         (d.full_date - l.launch_date) AS days_from_launch,
         ((d.full_date - l.launch_date) + 56) / 7 - 8 AS weeks_from_launch,
         dl.all_contacts, dl.related_reason_contacts, dl.launch_tagged_contacts, dl.aht, dl.fcr, dl.sentiment, s.csat
  FROM cc.product_launch l
  JOIN daily dl ON dl.launch_id = l.launch_id
  JOIN cc.dim_date d ON d.date_key = dl.date_key
  LEFT JOIN surveys s ON s.launch_id = l.launch_id AND s.date_key = dl.date_key
)
SELECT j.launch_id, j.launch_name, j.launch_type, j.launch_date, j.target_personas, j.full_date, j.days_from_launch, j.weeks_from_launch,
       j.all_contacts, j.related_reason_contacts, j.launch_tagged_contacts,
       round(j.aht, 1) AS aht_sec, round(100 * j.fcr, 1) AS fcr_pct, round(100 * j.csat, 1) AS csat_pct, round(j.sentiment, 3) AS sentiment,
       round(b.base_related, 1) AS baseline_related_contacts,
       round(100.0 * j.related_reason_contacts / nullif(b.base_related, 0), 1) AS related_volume_index,
       round(100 * b.base_fcr, 1) AS baseline_fcr_pct, round(b.base_aht, 1) AS baseline_aht_sec
FROM j
LEFT JOIN (SELECT launch_id, day_of_week, avg(related_reason_contacts) AS base_related, avg(fcr) AS base_fcr, avg(aht) AS base_aht
           FROM j WHERE days_from_launch BETWEEN -56 AND -8 GROUP BY 1, 2) b
  ON b.launch_id = j.launch_id AND b.day_of_week = j.day_of_week;
COMMENT ON VIEW cc.v_launch_impact IS 'Each launch from 8 weeks before to 12 weeks after: daily volume of related reasons vs same-weekday pre-launch baseline (index 100 = baseline), AHT, FCR, CSAT, sentiment.';

CREATE OR REPLACE VIEW cc.v_persona_kpis AS
SELECT d.year_month, p.persona_name, cu.age_band, cu.income_band, cu.gender, cu.segment, rg.state_code, rg.area_type, ch.channel_name,
       count(*) AS contacts,
       count(DISTINCT c.customer_id) AS customers_contacting,
       round(100.0 * count(*) FILTER (WHERE c.abandoned) / count(*), 2) AS abandon_pct,
       round(avg(c.queue_wait_sec) FILTER (WHERE c.answered), 1) AS asa_sec,
       round(avg(c.handle_sec) FILTER (WHERE c.answered), 1) AS aht_sec,
       round(100 * avg(c.first_contact_resolved::int) FILTER (WHERE c.answered), 1) AS fcr_pct,
       round(100 * avg(c.repeat_within_7d::int), 1) AS repeat_7d_pct,
       round(100 * avg(c.transferred::int) FILTER (WHERE c.answered), 1) AS transfer_pct,
       round(avg(c.sentiment_score), 3) AS avg_sentiment,
       count(sv.survey_id) AS surveys,
       round(100 * avg((sv.csat >= 4)::int), 1) AS csat_pct,
       round(100 * (avg((sv.nps >= 9)::int) - avg((sv.nps <= 6)::int)), 1) AS nps
FROM cc.contact c
JOIN cc.customer cu ON cu.customer_id = c.customer_id
JOIN cc.dim_persona p ON p.persona_id = cu.persona_id
JOIN cc.dim_region rg ON rg.region_id = cu.region_id
JOIN cc.dim_channel ch ON ch.channel_id = c.channel_id
JOIN cc.dim_date d ON d.date_key = c.date_key
LEFT JOIN cc.survey_response sv ON sv.contact_id = c.contact_id
GROUP BY d.year_month, p.persona_name, cu.age_band, cu.income_band, cu.gender, cu.segment, rg.state_code, rg.area_type, ch.channel_name;
COMMENT ON VIEW cc.v_persona_kpis IS 'Monthly KPIs by persona, age band, income band, gender, segment, state, area type and channel (identified customers only).';
