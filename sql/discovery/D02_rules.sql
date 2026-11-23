-- Data quality rules, stored as data. Each check_sql returns ONE number (the measured value).
-- Status: measured > fail_above => Fail; measured > warn_above => Warn; otherwise Pass.
-- {run_id} is replaced with the current run id (used by rules that read this run's daily volume).
-- Dates (v3.1): discovery.period_end() is the latest business day loaded (31 Oct 2026 before daily loads began);
-- discovery.snapshot_date() is the date of the monthly customer and product snapshot, which is not a daily feed.
\set ON_ERROR_STOP on
SET client_min_messages = warning;
DELETE FROM discovery.dq_rule;

INSERT INTO discovery.dq_rule (rule_id, table_name, column_name, dimension, rule_name, description, check_sql, unit, warn_above, fail_above, severity, expected_note) VALUES
-- ======================= COMPLETENESS =======================
('CMP-001','contact','answered_ts','Completeness','Answered time present only for answered contacts',
 'answered_ts must be filled for answered contacts and empty for abandoned ones.',
 $$SELECT count(*) FROM cc.contact WHERE (answered AND answered_ts IS NULL) OR (NOT answered AND answered_ts IS NOT NULL)$$,'rows',0,0,'Critical',NULL),
('CMP-002','contact','agent_id','Completeness','Agent present only for answered contacts',
 'Every answered contact needs the agent who handled it; abandoned contacts have no agent.',
 $$SELECT count(*) FROM cc.contact WHERE (answered AND agent_id IS NULL) OR (abandoned AND agent_id IS NOT NULL)$$,'rows',0,0,'Critical',NULL),
('CMP-003','contact','wrap_end_ts','Completeness','End and wrap-up times present for answered contacts',
 'Answered contacts need customer_end_ts and wrap_end_ts to calculate handle and wrap-up time.',
 $$SELECT count(*) FROM cc.contact WHERE answered AND (customer_end_ts IS NULL OR wrap_end_ts IS NULL)$$,'rows',0,0,'High',NULL),
('CMP-004','contact','first_contact_resolved','Completeness','Resolution recorded for answered contacts',
 'Agents must record whether the issue was resolved, otherwise FCR cannot be measured.',
 $$SELECT count(*) FROM cc.contact WHERE answered AND first_contact_resolved IS NULL$$,'rows',0,0,'Medium',NULL),
('CMP-005','contact','customer_id','Completeness','Anonymous phone and chat contacts',
 '% of phone and chat contacts where the customer did not identify themselves.',
 $$SELECT 100.0 * avg((customer_id IS NULL)::int) FROM cc.contact WHERE channel_id IN (1, 2)$$,'%',10,15,'Low',
 'About 8% anonymous by design (unauthenticated callers). Exclude from persona analysis or show as "Unknown".'),
('CMP-006','contact','customer_id','Completeness','Customer present on email, secure message and callback',
 'These channels always know the customer, so customer_id must never be empty.',
 $$SELECT count(*) FROM cc.contact WHERE channel_id IN (3, 4, 5) AND customer_id IS NULL$$,'rows',0,0,'High',NULL),
('CMP-007','customer','income_band','Completeness','Income band captured',
 '% of customers with no income band.',
 $$SELECT 100.0 * avg((income_band IS NULL)::int) FROM cc.customer$$,'%',3,5,'Medium',
 'About 2% not captured by design. Show as "Unknown" rather than dropping customers.'),
('CMP-008','customer','gender','Completeness','Gender captured',
 '% of customers with no gender recorded.',
 $$SELECT 100.0 * avg((gender IS NULL)::int) FROM cc.customer$$,'%',3,5,'Medium',
 'About 2% not captured by design. Show as "Unknown".'),
('CMP-009','customer','digital_enrolled_date','Completeness','Enrolment date matches enrolment flag',
 'Customers enrolled in digital banking must have an enrolment date; others must not.',
 $$SELECT count(*) FROM cc.customer WHERE digital_enrolled <> (digital_enrolled_date IS NOT NULL)$$,'rows',0,0,'Medium',NULL),
('CMP-010','complaint','closed_ts','Completeness','Closed date present only for closed complaints',
 'Closed complaints need a closed date; open complaints must not have one.',
 $$SELECT count(*) FROM cc.complaint WHERE (status = 'Closed' AND closed_ts IS NULL) OR (status = 'Open' AND closed_ts IS NOT NULL)$$,'rows',0,0,'High',NULL),
('CMP-011','agent_daily','adherence_pct','Completeness','Adherence calculated for every worked day',
 'Every day an agent worked (not PTO or absent) needs an adherence %.',
 $$SELECT count(*) FROM cc.agent_daily WHERE NOT is_pto AND NOT is_absent AND scheduled_min > 0 AND adherence_pct IS NULL$$,'rows',0,0,'Medium',NULL),
('CMP-012','contact','offered_ts','Completeness','No open days without contacts',
 'Number of days the center was open but recorded no contacts (a sign of a missing data load).',
 $$SELECT count(*) FROM cc.dim_date d WHERE NOT d.is_center_closed AND NOT EXISTS (SELECT 1 FROM cc.contact c WHERE c.date_key = d.date_key)$$,'days',0,0,'High',NULL),
('CMP-013','interval_volume','date_key','Completeness','No open days missing from interval summary',
 'Number of open days with no rows in the 15-minute summary.',
 $$SELECT count(*) FROM cc.dim_date d WHERE NOT d.is_center_closed AND NOT EXISTS (SELECT 1 FROM cc.interval_volume v WHERE v.date_key = d.date_key)$$,'days',0,0,'Medium',NULL),
('CMP-014','agent_daily','logged_in_min','Completeness','Worked days have agent activity',
 'Scheduled days not marked PTO or absent but with no logged-in time (missing activity feed).',
 $$SELECT count(*) FROM cc.agent_daily WHERE NOT is_pto AND NOT is_absent AND logged_in_min = 0$$,'rows',0,0,'Medium',NULL),
('CMP-015','survey_response','verbatim_theme','Completeness','Survey comment theme coded',
 'Every survey response should have a verbatim theme.',
 $$SELECT count(*) FROM cc.survey_response WHERE verbatim_theme IS NULL OR btrim(verbatim_theme) = ''$$,'rows',0,0,'Low',NULL),
('CMP-016','dim_date','full_date','Completeness','Calendar has no gaps',
 'Missing days in the calendar table (every date in the period must exist).',
 $$SELECT (max(full_date) - min(full_date) + 1) - count(*) FROM cc.dim_date$$,'days',0,0,'Critical',NULL),
('CMP-017','ivr_session','customer_id','Completeness','Unidentified IVR callers',
 '% of IVR sessions where the caller did not authenticate.',
 $$SELECT 100.0 * avg((customer_id IS NULL)::int) FROM cc.ivr_session$$,'%',10,15,'Low','About 8% expected, matching anonymous phone contacts.'),

-- Profile-driven rules (added after run 3: profiling showed customer_product.close_date 100% empty and
-- customer_product.status constant, a generation defect no row-level rule had caught)
('CMP-018','cc (all tables)',NULL,'Completeness','No unexpectedly empty columns',
 'Columns that are 100% NULL in this run''s column profile: the field is never populated.',
 $$SELECT count(*) FROM discovery.dq_column_profile WHERE run_id = {run_id} AND row_count > 0 AND null_pct = 100$$,'columns',0,0,'High',
 'Profile-driven rule. Reads the column profile built earlier in the same run.'),

-- ======================= UNIQUENESS =======================
('UNQ-001','contact','contact_id','Uniqueness','Contact ID unique',
 'Duplicate primary keys in contact.', $$SELECT count(*) - count(DISTINCT contact_id) FROM cc.contact$$,'rows',0,0,'Critical',NULL),
('UNQ-002','ivr_session','session_id','Uniqueness','IVR session ID unique',
 'Duplicate primary keys in ivr_session.', $$SELECT count(*) - count(DISTINCT session_id) FROM cc.ivr_session$$,'rows',0,0,'Critical',NULL),
('UNQ-003','survey_response','survey_id','Uniqueness','Survey ID unique',
 'Duplicate primary keys in survey_response.', $$SELECT count(*) - count(DISTINCT survey_id) FROM cc.survey_response$$,'rows',0,0,'Critical',NULL),
('UNQ-004','complaint','complaint_id','Uniqueness','Complaint ID unique',
 'Duplicate primary keys in complaint.', $$SELECT count(*) - count(DISTINCT complaint_id) FROM cc.complaint$$,'rows',0,0,'Critical',NULL),
('UNQ-005','customer','customer_id','Uniqueness','Customer ID unique',
 'Duplicate primary keys in customer.', $$SELECT count(*) - count(DISTINCT customer_id) FROM cc.customer$$,'rows',0,0,'Critical',NULL),
('UNQ-006','customer_product','customer_product_id','Uniqueness','Customer product ID unique',
 'Duplicate primary keys in customer_product.', $$SELECT count(*) - count(DISTINCT customer_product_id) FROM cc.customer_product$$,'rows',0,0,'Critical',NULL),
('UNQ-007','agent_schedule','schedule_id','Uniqueness','Schedule block ID unique',
 'Duplicate primary keys in agent_schedule.', $$SELECT count(*) - count(DISTINCT schedule_id) FROM cc.agent_schedule$$,'rows',0,0,'Critical',NULL),
('UNQ-008','agent_activity','activity_id','Uniqueness','Activity ID unique',
 'Duplicate primary keys in agent_activity.', $$SELECT count(*) - count(DISTINCT activity_id) FROM cc.agent_activity$$,'rows',0,0,'Critical',NULL),
('UNQ-009','interval_volume','interval_ts','Uniqueness','One summary row per interval and queue',
 'Duplicate interval x queue rows would double-count volume.',
 $$SELECT count(*) - count(DISTINCT (interval_ts, queue_id)) FROM cc.interval_volume$$,'rows',0,0,'Critical',NULL),
('UNQ-010','agent_daily','agent_id','Uniqueness','One summary row per agent and day',
 'Duplicate agent x day rows would double-count adherence and productivity.',
 $$SELECT count(*) - count(DISTINCT (agent_id, date_key)) FROM cc.agent_daily$$,'rows',0,0,'Critical',NULL),
('UNQ-011','survey_response','contact_id','Uniqueness','At most one survey per contact',
 'A contact should never be surveyed twice.',
 $$SELECT count(*) - count(DISTINCT contact_id) FROM cc.survey_response$$,'rows',0,0,'High',NULL),
('UNQ-012','contact','offered_ts','Uniqueness','No duplicate contact events',
 'Same customer, channel and second offered twice: a sign of double-loaded records.',
 $$SELECT count(*) FROM (SELECT customer_id, channel_id, date_trunc('second', offered_ts) FROM cc.contact WHERE customer_id IS NOT NULL GROUP BY 1, 2, 3 HAVING count(*) > 1) x$$,'rows',0,10,'Medium',NULL),
('UNQ-013','customer_product','product_id','Uniqueness','One holding per customer and product',
 'A customer holding the same product twice suggests a duplicate load.',
 $$SELECT count(*) FROM (SELECT customer_id, product_id FROM cc.customer_product GROUP BY 1, 2 HAVING count(*) > 1) x$$,'rows',0,0,'Low',NULL),
('UNQ-014','dim_agent','employee_number','Uniqueness','Employee number unique',
 'Each agent must have a unique employee number.',
 $$SELECT count(*) - count(DISTINCT employee_number) FROM cc.dim_agent$$,'rows',0,0,'High',NULL),
('UNQ-015','dim_agent','display_name','Uniqueness','Agent names distinguishable',
 'Agents sharing a display name are hard to tell apart on reports.',
 $$SELECT count(*) - count(DISTINCT display_name) FROM cc.dim_agent$$,'rows',0,3,'Low',NULL),

-- ======================= VALIDITY =======================
('VAL-001','contact','queue_wait_sec','Validity','No negative durations',
 'Queue wait, talk, hold and wrap-up must never be negative.',
 $$SELECT count(*) FROM cc.contact WHERE queue_wait_sec < 0 OR talk_sec < 0 OR hold_sec < 0 OR wrap_sec < 0$$,'rows',0,0,'Critical',NULL),
('VAL-002','contact','offered_ts','Validity','Contact timestamps in order',
 'offered <= answered <= customer end <= wrap end for every answered contact.',
 $$SELECT count(*) FROM cc.contact WHERE answered AND NOT (offered_ts <= answered_ts AND answered_ts <= customer_end_ts AND customer_end_ts <= wrap_end_ts)$$,'rows',0,0,'Critical',NULL),
('VAL-003','contact','handle_sec','Validity','Handle time = talk + hold + wrap',
 'Handle time must equal the sum of its parts.',
 $$SELECT count(*) FROM cc.contact WHERE handle_sec <> talk_sec + hold_sec + wrap_sec$$,'rows',0,0,'High',NULL),
('VAL-004','contact','offered_ts','Validity','Contacts inside the reporting period',
 'Contacts offered before 1 Jan 2024 or after 31 Oct 2026.',
 $$SELECT count(*) FROM cc.contact WHERE offered_ts < '2024-01-01' OR offered_ts >= (SELECT discovery.period_end()) + 1$$,'rows',0,0,'High',NULL),
('VAL-005','contact','offered_ts','Validity','Phone and chat offered only in opening hours',
 'Customers can only join the phone or chat queue Mon-Fri 7:00-21:00 and Sat 8:00-17:00, never on a closed day.',
 $$SELECT count(*) FROM cc.contact c JOIN cc.dim_date d ON d.full_date = c.offered_ts::date
   WHERE c.channel_id IN (1, 2) AND (d.is_center_closed
     OR (d.day_of_week = 6 AND NOT c.offered_ts::time BETWEEN '08:00' AND '17:00')
     OR (d.day_of_week < 6 AND NOT c.offered_ts::time BETWEEN '07:00' AND '21:00'))$$,'rows',0,0,'High',
 'Run 1 found 6,039 contacts offered before opening (agents logging in early); run 2 found 8 offered after closing (agents logging out late). Fixed at source and removed by remediation R01.'),
('VAL-023','contact','answered_ts','Validity','Queued calls answered promptly after closing',
 'Phone and chat contacts still being answered more than 15 minutes after closing time (calls waiting at close are answered, but not long after).',
 $$SELECT count(*) FROM cc.contact c JOIN cc.dim_date d ON d.full_date = c.answered_ts::date
   WHERE c.channel_id IN (1, 2) AND c.answered AND NOT d.is_center_closed
     AND c.answered_ts::time > CASE WHEN d.day_of_week = 6 THEN time '17:15' ELSE time '21:15' END$$,'rows',0,0,'Medium',NULL),
('VAL-006','contact','talk_sec','Validity','Implausibly long contacts',
 '% of answered contacts with more than 2 hours of talk time.',
 $$SELECT 100.0 * avg((talk_sec > 7200)::int) FROM cc.contact WHERE answered$$,'%',0.01,0.1,'Low',NULL),
('VAL-007','contact','queue_wait_sec','Validity','Very long phone and chat waits',
 '% of answered phone and chat contacts that waited more than 20 minutes.',
 $$SELECT 100.0 * avg((queue_wait_sec > 1200)::int) FROM cc.contact WHERE answered AND channel_id IN (1, 2)$$,'%',0.5,2,'Medium',
 'Long waits are real during the summer 2025 staffing crunch; investigate if this rises.'),
('VAL-008','contact','sentiment_score','Validity','Sentiment within -1 to +1',
 'Sentiment scores outside the valid range.',
 $$SELECT count(*) FROM cc.contact WHERE sentiment_score NOT BETWEEN -1 AND 1$$,'rows',0,0,'Medium',NULL),
('VAL-009','survey_response','csat','Validity','Survey scores within scale',
 'CSAT 1-5, NPS 0-10 and CES 1-7.',
 $$SELECT count(*) FROM cc.survey_response WHERE csat NOT BETWEEN 1 AND 5 OR nps NOT BETWEEN 0 AND 10 OR ces NOT BETWEEN 1 AND 7$$,'rows',0,0,'Critical',NULL),
('VAL-010','agent_daily','adherence_pct','Validity','Adherence between 0% and 100%',
 'Adherence percentages outside 0-100.',
 $$SELECT count(*) FROM cc.agent_daily WHERE adherence_pct NOT BETWEEN 0 AND 100$$,'rows',0,0,'High',NULL),
('VAL-011','agent_daily','occupancy_pct','Validity','Occupancy between 0% and 100%',
 'Occupancy cannot exceed 100% of available time.',
 $$SELECT count(*) FROM cc.agent_daily WHERE occupancy_pct NOT BETWEEN 0 AND 100$$,'rows',0,0,'Medium',NULL),
('VAL-012','customer','age','Validity','Customer age 18-100',
 'Customers younger than 18 or older than 100.',
 $$SELECT count(*) FROM cc.customer WHERE age NOT BETWEEN 18 AND 100$$,'rows',0,0,'Medium',NULL),
('VAL-013','customer','customer_since','Validity','Customer relationship starts before first contact',
 'Contacts dated before the customer became a customer.',
 $$SELECT count(*) FROM cc.contact c JOIN cc.customer cu USING (customer_id) WHERE cu.customer_since > c.offered_ts::date$$,'rows',0,0,'High',NULL),
('VAL-014','complaint','days_to_close','Validity','Complaints close after they open',
 'Complaints closed before they were opened, or with negative days to close.',
 $$SELECT count(*) FROM cc.complaint WHERE closed_ts < opened_ts OR days_to_close < 0$$,'rows',0,0,'High',NULL),
('VAL-015','customer_product','close_date','Validity','Products close after they open',
 'Product holdings closed before they were opened.',
 $$SELECT count(*) FROM cc.customer_product WHERE close_date < open_date$$,'rows',0,0,'High',NULL),
('VAL-016','agent_activity','duration_sec','Validity','Agent states have positive duration',
 'Activity states with zero or negative length.',
 $$SELECT count(*) FROM cc.agent_activity WHERE duration_sec <= 0 OR state_end_ts <= state_start_ts$$,'rows',0,0,'Medium',NULL),
('VAL-017','contact','agent_id','Validity','Agents handle contacts only while employed',
 'Contacts answered by an agent before their hire date or after they left.',
 $$SELECT count(*) FROM cc.contact c JOIN cc.dim_agent a USING (agent_id)
   WHERE c.answered_ts::date < a.hire_date OR c.answered_ts::date >= a.term_date$$,'rows',0,0,'High',NULL),
('VAL-018','contact','abandoned','Validity','Abandoned contacts have no handling',
 'Abandoned contacts with talk time, wrap-up time or marked answered.',
 $$SELECT count(*) FROM cc.contact WHERE abandoned AND (answered OR talk_sec > 0 OR wrap_sec > 0)$$,'rows',0,0,'Critical',NULL),
('VAL-019','contact','concurrent_chats','Validity','Chat concurrency within limit',
 'Chats handled while the agent already had 3 or more open.',
 $$SELECT count(*) FROM cc.contact WHERE concurrent_chats > 3$$,'rows',0,0,'High',NULL),
('VAL-020','agent_daily','quality_score','Validity','Quality scores within 50-100',
 'Quality evaluation scores outside the scoring scale.',
 $$SELECT count(*) FROM cc.agent_daily WHERE quality_score NOT BETWEEN 50 AND 100$$,'rows',0,0,'Low',NULL),
('VAL-021','ivr_session','duration_sec','Validity','IVR sessions have sensible length',
 'IVR sessions shorter than 5 seconds or longer than 30 minutes.',
 $$SELECT count(*) FROM cc.ivr_session WHERE duration_sec < 5 OR duration_sec > 1800$$,'rows',0,0,'Low',NULL),
('VAL-022','agent_schedule','scheduled_min','Validity','Schedule blocks have positive length',
 'Schedule blocks with zero or negative minutes.',
 $$SELECT count(*) FROM cc.agent_schedule WHERE scheduled_min <= 0 OR scheduled_end_ts <= scheduled_start_ts$$,'rows',0,0,'Medium',NULL),

('VAL-024','cc (all tables)',NULL,'Validity','No unexpectedly constant columns',
 'Columns with a single distinct value across many rows: a flag or category that never varies usually means a broken feed or generator.',
 $$SELECT count(*) FROM discovery.dq_column_profile WHERE run_id = {run_id} AND row_count > 1 AND distinct_count = 1
     AND (table_name, column_name) NOT IN (('dim_site', 'timezone'))$$,'columns',0,0,'High',
 'Profile-driven rule. Allow-listed: dim_site.timezone (all sites are in Central time by design).'),
('VAL-025','customer_product','open_date','Validity','Launch product openings spread over time',
 'Products launched in the period whose openings fall on fewer than half of the days the product has been available (capped at 100 days): real customers do not all open accounts on the same few dates.',
 $$SELECT count(*) FROM (SELECT cp.product_id, min(p.introduced_date) AS intro FROM cc.customer_product cp JOIN cc.dim_product p USING (product_id)
     WHERE p.is_new_in_period GROUP BY 1
     HAVING count(DISTINCT cp.open_date) < 0.5 * least(100, discovery.snapshot_date() - min(p.introduced_date))) x$$,'products',0,0,'Medium',
 'Run 4: P2P Payments, High-Yield Savings and others opened on as few as 4 distinct days (generator defect, fixed by 07b_customer_products.sql).'),

-- ======================= CONSISTENCY =======================
('CON-001','interval_volume','offered','Consistency','Interval offered total = contact count',
 'The 15-minute summary must contain exactly as many offered contacts as the detail table.',
 $$SELECT abs((SELECT sum(offered) FROM cc.interval_volume) - (SELECT count(*) FROM cc.contact))$$,'rows',0,0,'Critical',NULL),
('CON-002','interval_volume','answered','Consistency','Interval answered total = answered contacts',
 'Answered totals must reconcile between summary and detail.',
 $$SELECT abs((SELECT sum(answered) FROM cc.interval_volume) - (SELECT count(*) FROM cc.contact WHERE answered))$$,'rows',0,0,'Critical',NULL),
('CON-003','agent_daily','contacts_handled','Consistency','Agent-day contacts = answered contacts',
 'Contacts per agent per day must reconcile to the contact detail.',
 $$SELECT abs((SELECT sum(contacts_handled) FROM cc.agent_daily WHERE date_key <= to_char((SELECT discovery.period_end()), 'YYYYMMDD')::int)
            - (SELECT count(*) FROM cc.contact WHERE answered AND answered_ts::date <= (SELECT discovery.period_end())))$$,'rows',0,0,'Critical',
 'Compares up to the latest day loaded: an email answered the day after it arrived is counted when that day is loaded.'),
('CON-004','survey_response','agent_id','Consistency','Survey agent matches contact agent',
 'Surveys credited to a different agent than the one who handled the contact.',
 $$SELECT count(*) FROM cc.survey_response s JOIN cc.contact c USING (contact_id) WHERE s.agent_id <> c.agent_id$$,'rows',0,0,'High',NULL),
('CON-005','survey_response','customer_id','Consistency','Survey customer matches contact customer',
 'Surveys from a different customer than the one on the contact.',
 $$SELECT count(*) FROM cc.survey_response s JOIN cc.contact c USING (contact_id) WHERE s.customer_id IS DISTINCT FROM c.customer_id$$,'rows',0,0,'High',NULL),
('CON-006','ivr_session','contact_id','Consistency','IVR opt-outs link to phone contacts',
 'IVR sessions that transferred to an agent must link to a phone contact.',
 $$SELECT count(*) FROM cc.ivr_session i JOIN cc.contact c USING (contact_id) WHERE c.channel_id <> 1$$,'rows',0,0,'High',NULL),
('CON-007','contact','channel_id','Consistency','Every phone contact came through the IVR',
 'Phone contacts with no IVR session.',
 $$SELECT count(*) FROM cc.contact c WHERE c.channel_id = 1 AND NOT EXISTS (SELECT 1 FROM cc.ivr_session i WHERE i.contact_id = c.contact_id)$$,'rows',0,0,'Medium',NULL),
('CON-008','contact','agent_id','Consistency','Agents never handle overlapping contacts',
 'Phone, email and callback agents answering a new contact before finishing the previous one.',
 $$SELECT count(*) FROM (SELECT wrap_end_ts, lead(answered_ts) OVER (PARTITION BY agent_id ORDER BY answered_ts) AS nxt
                         FROM cc.contact WHERE answered AND channel_id <> 2) x WHERE nxt < wrap_end_ts$$,'rows',0,0,'Critical',NULL),
('CON-009','contact','answered_ts','Consistency','Contacts handled only while agent is Available',
 'Contacts handled while the agent was on break, in training, unavailable or logged out.',
 $$SELECT count(*) FROM cc.contact c WHERE c.answered AND c.answered_ts::date <= (SELECT discovery.period_end()) AND NOT EXISTS (SELECT 1 FROM cc.agent_activity a
     WHERE a.agent_id = c.agent_id AND a.date_key = to_char(c.answered_ts, 'YYYYMMDD')::int
       AND a.state = 'Available' AND c.answered_ts >= a.state_start_ts AND c.wrap_end_ts <= a.state_end_ts)$$,'rows',0,0,'Critical',
 'Checks contacts answered up to the latest day loaded; that day''s agent activity arrives with it.'),
('CON-010','agent_activity','state_start_ts','Consistency','Agent states never overlap',
 'An agent recorded in two states at the same time.',
 $$SELECT count(*) FROM (SELECT state_end_ts, lead(state_start_ts) OVER (PARTITION BY agent_id ORDER BY state_start_ts) AS nxt
                         FROM cc.agent_activity) x WHERE nxt < state_end_ts - interval '1 ms'$$,'rows',0,0,'High',NULL),
('CON-011','agent_schedule','scheduled_start_ts','Consistency','Schedule blocks never overlap',
 'An agent scheduled for two activities at the same time.',
 $$SELECT count(*) FROM (SELECT scheduled_end_ts, lead(scheduled_start_ts) OVER (PARTITION BY agent_id ORDER BY scheduled_start_ts) AS nxt
                         FROM cc.agent_schedule) x WHERE nxt < scheduled_end_ts$$,'rows',0,0,'High',NULL),
('CON-012','complaint','contact_id','Consistency','Complaint customer matches its contact',
 'Complaints linked to a contact from a different customer.',
 $$SELECT count(*) FROM cc.complaint k JOIN cc.contact c USING (contact_id) WHERE k.customer_id IS DISTINCT FROM c.customer_id$$,'rows',0,0,'Medium',NULL),
('CON-013','contact','launch_id','Consistency','Launch-tagged contacts have a launch-related reason',
 'Contacts tagged to a launch whose reason is not one that launch drives.',
 $$SELECT count(*) FROM cc.contact c WHERE c.launch_id IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM cc.launch_reason_impact i WHERE i.launch_id = c.launch_id AND i.reason_id = c.reason_id)$$,'rows',0,0,'Medium',NULL),
('CON-014','contact','met_service_level','Consistency','Service level flag matches queue threshold',
 'met_service_level disagrees with queue wait vs. the queue''s threshold.',
 $$SELECT count(*) FROM cc.contact c JOIN cc.dim_queue q USING (queue_id)
   WHERE c.answered AND c.met_service_level <> (c.queue_wait_sec <= q.sl_threshold_sec)$$,'rows',0,0,'High',NULL),
('CON-015','contact','date_key','Consistency','Date key matches offered date',
 'date_key that does not match the date of offered_ts.',
 $$SELECT count(*) FROM cc.contact WHERE date_key <> to_char(offered_ts, 'YYYYMMDD')::int$$,'rows',0,0,'Medium',NULL),
('CON-016','contact','queue_id','Consistency','Queue belongs to the contact''s channel',
 'Contacts routed to a queue of a different channel.',
 $$SELECT count(*) FROM cc.contact c JOIN cc.dim_queue q USING (queue_id) WHERE q.channel_id <> c.channel_id$$,'rows',0,0,'High',NULL),
('CON-017','dim_agent','team_id','Consistency','Agents work the channel of their team',
 'Agents whose primary channel differs from their team''s channel.',
 $$SELECT count(*) FROM cc.dim_agent a JOIN cc.dim_team t USING (team_id) WHERE a.role <> 'Supervisor' AND a.primary_channel_id <> t.primary_channel_id$$,'rows',0,0,'Low',NULL),

-- ======================= VOLUME =======================
('VOL-001','contact',NULL,'Volume','Contact volume above minimum',
 'Rows short of the 100,000 minimum.', $$SELECT greatest(0, 100000 - count(*)) FROM cc.contact$$,'rows',0,0,'Medium',NULL),
('VOL-002','ivr_session',NULL,'Volume','IVR volume above minimum',
 'Rows short of the 100,000 minimum.', $$SELECT greatest(0, 100000 - count(*)) FROM cc.ivr_session$$,'rows',0,0,'Medium',NULL),
('VOL-003','customer_product',NULL,'Volume','Product holdings above minimum',
 'Rows short of the 100,000 minimum.', $$SELECT greatest(0, 100000 - count(*)) FROM cc.customer_product$$,'rows',0,0,'Medium',NULL),
('VOL-004','agent_activity',NULL,'Volume','Agent activity above minimum',
 'Rows short of the 100,000 minimum.', $$SELECT greatest(0, 100000 - count(*)) FROM cc.agent_activity$$,'rows',0,0,'Medium',NULL),
('VOL-005','interval_volume',NULL,'Volume','Interval summary above minimum',
 'Rows short of the 100,000 minimum.', $$SELECT greatest(0, 100000 - count(*)) FROM cc.interval_volume$$,'rows',0,0,'Medium',NULL),
('VOL-006','agent_schedule',NULL,'Volume','Schedule above minimum',
 'Rows short of the 100,000 minimum.', $$SELECT greatest(0, 100000 - count(*)) FROM cc.agent_schedule$$,'rows',0,0,'Medium',NULL),
('VOL-007','survey_response',NULL,'Volume','Surveys above minimum',
 'Rows short of the 100,000 minimum.', $$SELECT greatest(0, 100000 - count(*)) FROM cc.survey_response$$,'rows',0,0,'Medium',NULL),
('VOL-008','customer',NULL,'Volume','Customers above minimum',
 'Rows short of the 100,000 minimum.', $$SELECT greatest(0, 100000 - count(*)) FROM cc.customer$$,'rows',0,0,'Medium',NULL),
('VOL-009','complaint',NULL,'Volume','Complaints above minimum',
 'Rows short of the 100,000 minimum.', $$SELECT greatest(0, 100000 - count(*)) FROM cc.complaint$$,'rows',0,0,'Medium',NULL),
('VOL-010','agent_daily',NULL,'Volume','Agent-day summary above minimum',
 'Rows short of the 100,000 minimum.', $$SELECT greatest(0, 100000 - count(*)) FROM cc.agent_daily$$,'rows',0,0,'Medium',NULL),
('VOL-011','contact','offered_ts','Volume','Unusual contact volume days',
 'Open days with contact volume more than 35% above or below the same weekday''s recent median.',
 $$SELECT count(*) FROM discovery.dq_daily_volume WHERE run_id = {run_id} AND table_name = 'contact' AND is_outlier$$,'days',0,20,'Medium',
 'Expected spikes: post-holiday surges, the 7-8 Apr 2026 online banking outage and launch peaks. Review each flagged day.'),
('VOL-012','ivr_session','start_ts','Volume','Unusual IVR volume days',
 'Open days with IVR volume more than 35% above or below the same weekday''s recent median.',
 $$SELECT count(*) FROM discovery.dq_daily_volume WHERE run_id = {run_id} AND table_name = 'ivr_session' AND is_outlier$$,'days',0,20,'Low',
 'Follows contact volume; spikes on the same days are expected.'),
('VOL-013','agent_activity','agent_id','Volume','Unusual number of agents logged in',
 'Open days where the number of agents who logged in is more than 35% above or below the same weekday''s recent median (a missing or partial activity feed).',
 $$SELECT count(*) FROM discovery.dq_daily_volume WHERE run_id = {run_id} AND table_name = 'agents_logged_in' AND is_outlier$$,'days',0,10,'Medium',
 'Refined after run 1: counting state records per day (58 flagged days) reacted to coaching, training and break patterns, not feed problems. Expected: early Sep 2025, when post-freeze hiring classes finished training and headcount jumped 35-47%.'),
('VOL-014','complaint','opened_ts','Volume','Unusual complaint volume days',
 'Open days with complaint volume more than 35% above or below normal.',
 $$SELECT count(*) FROM discovery.dq_daily_volume WHERE run_id = {run_id} AND table_name = 'complaint' AND is_outlier$$,'days',5,30,'Low',
 'Small daily counts swing more; the fee change (Mar 2025) and re-platform (Feb 2026) raise complaints.'),

-- ======================= TIMELINESS =======================
('TML-001','contact','offered_ts','Timeliness','Contact data up to date',
 'Days between the latest contact and the end of the reporting period (31 Oct 2026).',
 $$SELECT discovery.period_end() - max(offered_ts)::date FROM cc.contact$$,'days',1,7,'High',NULL),
('TML-002','ivr_session','start_ts','Timeliness','IVR data up to date',
 'Days between the latest IVR session and the end of the period.',
 $$SELECT discovery.period_end() - max(start_ts)::date FROM cc.ivr_session$$,'days',1,7,'Medium',NULL),
('TML-003','survey_response','survey_ts','Timeliness','Survey data up to date',
 'Days between the latest survey and the end of the period.',
 $$SELECT discovery.period_end() - max(survey_ts)::date FROM cc.survey_response$$,'days',2,7,'Medium',NULL),
('TML-004','complaint','opened_ts','Timeliness','Complaint data up to date',
 'Days between the latest complaint and the end of the period.',
 $$SELECT discovery.period_end() - max(opened_ts)::date FROM cc.complaint$$,'days',2,7,'Medium',NULL),
('TML-005','interval_volume','interval_ts','Timeliness','Interval summary up to date',
 'Days between the latest interval and the end of the period.',
 $$SELECT discovery.period_end() - max(interval_ts)::date FROM cc.interval_volume$$,'days',1,7,'High',NULL),
('TML-006','agent_schedule','scheduled_start_ts','Timeliness','Schedules up to date',
 'Days between the latest schedule and the end of the period.',
 $$SELECT discovery.period_end() - max(scheduled_start_ts)::date FROM cc.agent_schedule$$,'days',1,7,'Medium',NULL),
('TML-007','agent_activity','state_start_ts','Timeliness','Agent activity up to date',
 'Days between the latest agent activity and the end of the period.',
 $$SELECT discovery.period_end() - max(state_start_ts)::date FROM cc.agent_activity$$,'days',1,7,'High',NULL),
('TML-008','agent_daily','date_key','Timeliness','Agent-day summary up to date',
 'Days between the latest agent-day summary and the end of the period.',
 $$SELECT discovery.period_end() - to_date(max(date_key)::text, 'YYYYMMDD') FROM cc.agent_daily$$,'days',1,7,'High',NULL),
('TML-009','customer_product','open_date','Timeliness','Product openings up to date',
 'Days between the latest product opening and the end of the period.',
 $$SELECT discovery.snapshot_date() - max(open_date) FROM cc.customer_product$$,'days',3,14,'Low',NULL),
('TML-010','customer','customer_since','Timeliness','No future-dated customers',
 'Customers whose relationship starts after the end of the period.',
 $$SELECT count(*) FROM cc.customer WHERE customer_since > discovery.snapshot_date()$$,'rows',0,0,'Medium',NULL);

-- ======================= Business-user context =======================
-- problem_plain: the problem in plain words, used in "What changed" headlines ("Fixed: <problem>")
UPDATE discovery.dq_rule r SET problem_plain = v.p FROM (VALUES
 ('CMP-005', 'phone and chat contacts where the customer was not identified'),
 ('CMP-007', 'customers with no income band recorded'),
 ('CMP-008', 'customers with no gender recorded'),
 ('CMP-012', 'open days with no contacts recorded'),
 ('CMP-018', 'a data field that was never filled in'),
 ('UNQ-012', 'the same contact recorded twice'),
 ('VAL-005', 'contacts recorded while the phones were closed'),
 ('VAL-007', 'very long phone and chat waits'),
 ('VAL-023', 'calls answered long after closing time'),
 ('VAL-024', 'a data field that never changed'),
 ('VAL-025', 'new product openings bunched on a few days'),
 ('VOL-011', 'days with unusual contact volume'),
 ('VOL-012', 'days with unusual phone menu (IVR) volume'),
 ('VOL-013', 'days with an unusual number of agents logged in'),
 ('VOL-014', 'days with unusual complaint volume')
) v(id, p) WHERE r.rule_id = v.id;

-- evidence_sql: returns a JSON list of {item, detail, records} (or {t, c, detail, records} for a data field)
UPDATE discovery.dq_rule SET evidence_sql = $$
  SELECT jsonb_agg(jsonb_build_object('t', table_name, 'c', column_name, 'records', row_count,
           'detail', 'empty on all ' || to_char(row_count, 'FM999,999,999') || ' records') ORDER BY row_count DESC)
  FROM discovery.dq_column_profile WHERE run_id = {run_id} AND row_count > 0 AND null_pct = 100$$
WHERE rule_id = 'CMP-018';

UPDATE discovery.dq_rule SET evidence_sql = $$
  SELECT jsonb_agg(jsonb_build_object('t', table_name, 'c', column_name, 'records', row_count,
           'detail', 'every one of ' || to_char(row_count, 'FM999,999,999') || ' records is "' || coalesce(min_value, 'true/false') || '"') ORDER BY row_count DESC)
  FROM discovery.dq_column_profile WHERE run_id = {run_id} AND row_count > 1 AND distinct_count = 1
    AND (table_name, column_name) NOT IN (('dim_site', 'timezone'))$$
WHERE rule_id = 'VAL-024';

UPDATE discovery.dq_rule SET evidence_sql = $$
  SELECT jsonb_agg(jsonb_build_object('item', x.product_name, 'records', x.holders,
           'detail', 'opened on only ' || x.days || ' different days (' || to_char(x.holders, 'FM999,999') || ' accounts)') ORDER BY x.days)
  FROM (SELECT p.product_name, count(DISTINCT cp.open_date) AS days, count(*) AS holders, min(p.introduced_date) AS intro
        FROM cc.customer_product cp JOIN cc.dim_product p USING (product_id) WHERE p.is_new_in_period GROUP BY 1) x
  WHERE x.days < 0.5 * least(100, discovery.snapshot_date() - x.intro)$$
WHERE rule_id = 'VAL-025';

UPDATE discovery.dq_rule SET evidence_sql = $$
  SELECT jsonb_agg(jsonb_build_object('item', x.bucket, 'records', x.n,
           'detail', to_char(x.n, 'FM999,999') || ' contacts, ' || to_char(x.first_t, 'HH24:MI') || '–' || to_char(x.last_t, 'HH24:MI')) ORDER BY x.n DESC)
  FROM (SELECT CASE WHEN d.is_center_closed THEN 'On a day the center was closed'
                    WHEN c.offered_ts::time < CASE WHEN d.day_of_week = 6 THEN time '08:00' ELSE time '07:00' END THEN 'Before opening time'
                    ELSE 'After closing time' END AS bucket,
               count(*) AS n, min(c.offered_ts::time) AS first_t, max(c.offered_ts::time) AS last_t
        FROM cc.contact c JOIN cc.dim_date d ON d.full_date = c.offered_ts::date
        WHERE c.channel_id IN (1, 2) AND (d.is_center_closed
          OR (d.day_of_week = 6 AND NOT c.offered_ts::time BETWEEN '08:00' AND '17:00')
          OR (d.day_of_week < 6 AND NOT c.offered_ts::time BETWEEN '07:00' AND '21:00'))
        GROUP BY 1) x$$
WHERE rule_id = 'VAL-005';

UPDATE discovery.dq_rule SET evidence_sql = $$
  SELECT jsonb_agg(jsonb_build_object('item', 'Customer contacts on ' || to_char(x.ts, 'Mon DD, YYYY HH24:MI:SS'), 'records', x.n,
           'detail', x.n || ' records with the same customer, channel and second'))
  FROM (SELECT date_trunc('second', offered_ts) AS ts, count(*) AS n FROM cc.contact WHERE customer_id IS NOT NULL
        GROUP BY customer_id, channel_id, date_trunc('second', offered_ts) HAVING count(*) > 1) x$$
WHERE rule_id = 'UNQ-012';

-- Volume rules: list the flagged days with how far they were from normal
UPDATE discovery.dq_rule r SET evidence_sql = replace(replace($$
  SELECT jsonb_agg(jsonb_build_object('item', to_char(day, 'Dy Mon DD, YYYY'), 'records', row_count,
           'detail', CASE WHEN ratio >= 1 THEN round((ratio - 1) * 100) || '% above normal'
                          ELSE round((1 - ratio) * 100) || '% below normal' END
                     || ' (' || to_char(row_count, 'FM999,999') || ' ##WHAT## vs about ' || to_char(round(baseline), 'FM999,999') || ')')
         ORDER BY abs(ratio - 1) DESC)
  FROM discovery.dq_daily_volume WHERE run_id = {run_id} AND table_name = '##TBL##' AND is_outlier$$,
  '##TBL##', v.tbl), '##WHAT##', v.what)
FROM (VALUES ('VOL-011', 'contact', 'contacts'), ('VOL-012', 'ivr_session', 'calls'),
             ('VOL-013', 'agents_logged_in', 'agents'), ('VOL-014', 'complaint', 'complaints')) v(id, tbl, what)
WHERE r.rule_id = v.id;

SELECT dimension, count(*) AS rules FROM discovery.dq_rule GROUP BY 1 ORDER BY 1;
