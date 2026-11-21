-- Column-level documentation stored in the database (single source of truth for the data dictionary).
-- The wiki Data Dictionary pages are generated from these comments by tools/generate_data_dictionary.ps1.
\set ON_ERROR_STOP on
SET client_min_messages = warning;

-- ---------- dataset_info ----------
COMMENT ON COLUMN cc.dataset_info.info_key   IS 'Metadata item name.';
COMMENT ON COLUMN cc.dataset_info.info_value IS 'Metadata item value.';

-- ---------- dim_date ----------
COMMENT ON COLUMN cc.dim_date.date_key              IS 'Primary key. Date as an integer yyyymmdd (e.g. 20250314).';
COMMENT ON COLUMN cc.dim_date.full_date             IS 'Calendar date.';
COMMENT ON COLUMN cc.dim_date.day_name              IS 'Day of week name (Monday..Sunday).';
COMMENT ON COLUMN cc.dim_date.day_of_week           IS 'ISO day of week: 1 = Monday .. 7 = Sunday.';
COMMENT ON COLUMN cc.dim_date.is_weekend            IS 'True on Saturday and Sunday.';
COMMENT ON COLUMN cc.dim_date.is_holiday            IS 'True on US federal holidays.';
COMMENT ON COLUMN cc.dim_date.holiday_name          IS 'Holiday name; null on non-holidays.';
COMMENT ON COLUMN cc.dim_date.is_center_closed      IS 'True when phone and chat are closed (Sundays and six major holidays). Email still arrives.';
COMMENT ON COLUMN cc.dim_date.week_start            IS 'Monday of the week containing this date.';
COMMENT ON COLUMN cc.dim_date.month_num             IS 'Month number 1-12.';
COMMENT ON COLUMN cc.dim_date.month_name            IS 'Month name.';
COMMENT ON COLUMN cc.dim_date.quarter_num           IS 'Calendar quarter 1-4.';
COMMENT ON COLUMN cc.dim_date.year_num              IS 'Calendar year.';
COMMENT ON COLUMN cc.dim_date.year_month            IS 'Year and month as text yyyy-mm (sortable).';
COMMENT ON COLUMN cc.dim_date.fiscal_period         IS 'Fiscal period label (fiscal year = calendar year), e.g. FY2025-P03.';
COMMENT ON COLUMN cc.dim_date.is_month_start_window IS 'True on days 1-3 of the month (typically busier).';
COMMENT ON COLUMN cc.dim_date.is_payday             IS 'True on the 1st and 15th, moved back to the previous weekday.';

-- ---------- dim_time_interval ----------
COMMENT ON COLUMN cc.dim_time_interval.interval_id    IS 'Primary key 0-95: 15-minute slot of the day (0 = 00:00, 28 = 07:00, 84 = 21:00).';
COMMENT ON COLUMN cc.dim_time_interval.interval_start IS 'Local start time of the slot.';
COMMENT ON COLUMN cc.dim_time_interval.interval_end   IS 'Local end time of the slot.';
COMMENT ON COLUMN cc.dim_time_interval.hour_of_day    IS 'Hour 0-23.';
COMMENT ON COLUMN cc.dim_time_interval.daypart        IS 'Morning (07-10), Midday (10-14), Afternoon (14-17), Evening (17-21), After hours.';
COMMENT ON COLUMN cc.dim_time_interval.interval_label IS 'Start time as HH:MM text.';

-- ---------- dim_channel ----------
COMMENT ON COLUMN cc.dim_channel.channel_id       IS 'Primary key.';
COMMENT ON COLUMN cc.dim_channel.channel_name     IS 'Phone, Chat, Email, Callback or Secure Message.';
COMMENT ON COLUMN cc.dim_channel.is_real_time     IS 'True for live channels (phone, chat) where customers wait on the line.';
COMMENT ON COLUMN cc.dim_channel.sl_target_pct    IS 'Default service level target (% of contacts within threshold).';
COMMENT ON COLUMN cc.dim_channel.sl_threshold_sec IS 'Default service level threshold in seconds (86,400 = 24 hours).';
COMMENT ON COLUMN cc.dim_channel.sl_label         IS 'Service level target in words.';

-- ---------- dim_queue ----------
COMMENT ON COLUMN cc.dim_queue.queue_id         IS 'Primary key.';
COMMENT ON COLUMN cc.dim_queue.queue_name       IS 'Queue display name, prefixed with its channel.';
COMMENT ON COLUMN cc.dim_queue.channel_id       IS 'Channel the queue belongs to (dim_channel).';
COMMENT ON COLUMN cc.dim_queue.skill            IS 'Skill required to handle the queue.';
COMMENT ON COLUMN cc.dim_queue.priority         IS 'Routing priority, 1 = highest.';
COMMENT ON COLUMN cc.dim_queue.sl_target_pct    IS 'Service level target for this queue (%).';
COMMENT ON COLUMN cc.dim_queue.sl_threshold_sec IS 'Service level threshold for this queue in seconds; used by contact.met_service_level.';

-- ---------- dim_site / dim_team ----------
COMMENT ON COLUMN cc.dim_site.site_id       IS 'Primary key.';
COMMENT ON COLUMN cc.dim_site.site_name     IS 'Site name.';
COMMENT ON COLUMN cc.dim_site.city          IS 'City.';
COMMENT ON COLUMN cc.dim_site.state_code    IS 'Two-letter state code.';
COMMENT ON COLUMN cc.dim_site.is_outsourced IS 'True for the outsourced partner site.';
COMMENT ON COLUMN cc.dim_site.timezone      IS 'Site time zone (all America/Chicago).';
COMMENT ON COLUMN cc.dim_team.team_id            IS 'Primary key.';
COMMENT ON COLUMN cc.dim_team.team_name          IS 'Team name, prefixed with its channel.';
COMMENT ON COLUMN cc.dim_team.site_id            IS 'Site the team works at (dim_site).';
COMMENT ON COLUMN cc.dim_team.supervisor_id      IS 'Team supervisor (dim_agent with role Supervisor).';
COMMENT ON COLUMN cc.dim_team.primary_channel_id IS 'Channel the team handles (dim_channel).';

-- ---------- dim_agent ----------
COMMENT ON COLUMN cc.dim_agent.agent_id             IS 'Primary key.';
COMMENT ON COLUMN cc.dim_agent.employee_number      IS 'Employee number (E + 5 digits). Unique.';
COMMENT ON COLUMN cc.dim_agent.first_name           IS 'First name (fictional).';
COMMENT ON COLUMN cc.dim_agent.last_name            IS 'Last name (fictional).';
COMMENT ON COLUMN cc.dim_agent.display_name         IS 'First and last name, for reports.';
COMMENT ON COLUMN cc.dim_agent.team_id              IS 'Team (dim_team).';
COMMENT ON COLUMN cc.dim_agent.role                 IS 'Agent, Senior Agent or Supervisor. Supervisors do not handle contacts.';
COMMENT ON COLUMN cc.dim_agent.hire_date            IS 'Hire date. Agents hired in-period spend their first 15 working days in training.';
COMMENT ON COLUMN cc.dim_agent.term_date            IS 'Last day employed + 1; null = still employed on 2026-10-31.';
COMMENT ON COLUMN cc.dim_agent.hire_class_id        IS 'Hiring class start date as yyyymmdd; null for agents hired before 2024.';
COMMENT ON COLUMN cc.dim_agent.primary_channel_id   IS 'Channel the agent works (dim_channel).';
COMMENT ON COLUMN cc.dim_agent.channels_certified   IS 'Channels the agent is trained on (comma-separated).';
COMMENT ON COLUMN cc.dim_agent.employment_type      IS 'Full-time or Part-time.';
COMMENT ON COLUMN cc.dim_agent.shift_pattern        IS 'Working days pattern, e.g. Mon-Fri, Mon-Thu + Sat.';
COMMENT ON COLUMN cc.dim_agent.shift_start          IS 'Usual weekday shift start time (Saturday shifts start 08:00 or 08:30).';
COMMENT ON COLUMN cc.dim_agent.max_concurrent_chats IS 'Chat agents only: maximum chats at once (2 or 3; new hires limited to 2).';

-- ---------- dim_region / dim_persona ----------
COMMENT ON COLUMN cc.dim_region.region_id  IS 'Primary key.';
COMMENT ON COLUMN cc.dim_region.state_code IS 'Two-letter state code.';
COMMENT ON COLUMN cc.dim_region.state_name IS 'State name.';
COMMENT ON COLUMN cc.dim_region.metro      IS 'Metro area (or "Rural <state>").';
COMMENT ON COLUMN cc.dim_region.area_type  IS 'Urban, Suburban or Rural.';
COMMENT ON COLUMN cc.dim_persona.persona_id        IS 'Primary key.';
COMMENT ON COLUMN cc.dim_persona.persona_name      IS 'Persona name.';
COMMENT ON COLUMN cc.dim_persona.description       IS 'Short description of the persona.';
COMMENT ON COLUMN cc.dim_persona.preferred_channel IS 'Channel this persona favours.';
COMMENT ON COLUMN cc.dim_persona.digital_affinity  IS 'Comfort with digital channels, 1 (low) to 5 (high).';
COMMENT ON COLUMN cc.dim_persona.price_sensitivity IS 'Low, Medium or High sensitivity to fees and rates.';
COMMENT ON COLUMN cc.dim_persona.typical_age_band  IS 'Typical age range.';

-- ---------- products, launches, reasons ----------
COMMENT ON COLUMN cc.dim_product.product_id       IS 'Primary key.';
COMMENT ON COLUMN cc.dim_product.product_name     IS 'Product name (generic).';
COMMENT ON COLUMN cc.dim_product.category         IS 'Deposit, Card, Lending, Mortgage, Digital or Business.';
COMMENT ON COLUMN cc.dim_product.launch_id        IS 'Most significant launch for this product during the period (product_launch); null if none.';
COMMENT ON COLUMN cc.dim_product.is_new_in_period IS 'True if the product was introduced during 2024-2026.';
COMMENT ON COLUMN cc.dim_product.introduced_date  IS 'Date the product was introduced.';
COMMENT ON COLUMN cc.product_launch.launch_id               IS 'Primary key.';
COMMENT ON COLUMN cc.product_launch.launch_name             IS 'Launch name.';
COMMENT ON COLUMN cc.product_launch.launch_date             IS 'Go-live date.';
COMMENT ON COLUMN cc.product_launch.product_id              IS 'Product launched or changed (dim_product).';
COMMENT ON COLUMN cc.product_launch.launch_type             IS 'New Product, Feature, Migration or Pricing Change.';
COMMENT ON COLUMN cc.product_launch.target_personas         IS 'Personas the launch targets (comma-separated), or All customers.';
COMMENT ON COLUMN cc.product_launch.expected_contact_impact IS 'Planned contact center impact: Low, Medium, High or Very High.';
COMMENT ON COLUMN cc.product_launch.marketing_spend_band    IS 'Marketing spend: None, Low, Medium or High.';
COMMENT ON COLUMN cc.product_launch.description             IS 'What changed for customers.';
COMMENT ON COLUMN cc.launch_reason_impact.launch_id IS 'Launch (product_launch).';
COMMENT ON COLUMN cc.launch_reason_impact.reason_id IS 'Contact reason the launch drives (dim_contact_reason).';
COMMENT ON COLUMN cc.launch_reason_impact.peak_lift IS 'Modelled lift in that reason''s volume at the launch peak (2.0 = +200%).';
COMMENT ON COLUMN cc.dim_contact_reason.reason_id                  IS 'Primary key.';
COMMENT ON COLUMN cc.dim_contact_reason.reason                     IS 'Contact reason (agent disposition / IVR selection).';
COMMENT ON COLUMN cc.dim_contact_reason.reason_group               IS 'Account Servicing, Card, Fraud/Dispute, Digital Access, Lending, Product Inquiry or Complaint.';
COMMENT ON COLUMN cc.dim_contact_reason.is_launch_related_possible IS 'True if at least one launch drives this reason.';

-- ---------- customer ----------
COMMENT ON COLUMN cc.customer.customer_id           IS 'Primary key.';
COMMENT ON COLUMN cc.customer.persona_id            IS 'Customer persona (dim_persona).';
COMMENT ON COLUMN cc.customer.region_id             IS 'Home region (dim_region).';
COMMENT ON COLUMN cc.customer.age                   IS 'Age in years at 2024-01-01.';
COMMENT ON COLUMN cc.customer.age_band              IS 'Age band: 18-24, 25-34, 35-44, 45-54, 55-64, 65-74, 75+.';
COMMENT ON COLUMN cc.customer.gender                IS 'Female, Male, Non-binary, Prefer not to say; null (~2%) = not captured.';
COMMENT ON COLUMN cc.customer.income_band           IS 'Household income band; null (~2%) = not captured.';
COMMENT ON COLUMN cc.customer.customer_since        IS 'Date the relationship began (always before the first contact).';
COMMENT ON COLUMN cc.customer.segment               IS 'Mass, Mass Affluent, Private or Small Business.';
COMMENT ON COLUMN cc.customer.digital_enrolled      IS 'True if enrolled in online/mobile banking.';
COMMENT ON COLUMN cc.customer.digital_enrolled_date IS 'Date of digital enrolment; null if not enrolled.';
COMMENT ON COLUMN cc.customer.preferred_language    IS 'English, Spanish or Other.';
COMMENT ON COLUMN cc.customer.household_size        IS 'Number of people in the household.';

-- ---------- customer_product ----------
COMMENT ON COLUMN cc.customer_product.customer_product_id  IS 'Primary key.';
COMMENT ON COLUMN cc.customer_product.customer_id          IS 'Customer (customer).';
COMMENT ON COLUMN cc.customer_product.product_id           IS 'Product (dim_product).';
COMMENT ON COLUMN cc.customer_product.open_date            IS 'Date opened / enrolled.';
COMMENT ON COLUMN cc.customer_product.close_date           IS 'Date closed; null if still open.';
COMMENT ON COLUMN cc.customer_product.status               IS 'Active, Dormant or Closed.';
COMMENT ON COLUMN cc.customer_product.opened_via_launch_id IS 'Launch (product_launch) if opened within 90 days of that product''s launch; otherwise null.';

-- ---------- contact (columns not documented in 09_constraints_indexes.sql) ----------
COMMENT ON COLUMN cc.contact.contact_id     IS 'Primary key, roughly in time order.';
COMMENT ON COLUMN cc.contact.customer_id    IS 'Customer (customer); null = anonymous / unauthenticated (~8% of phone and chat).';
COMMENT ON COLUMN cc.contact.channel_id     IS 'Channel (dim_channel).';
COMMENT ON COLUMN cc.contact.queue_id       IS 'Queue the contact was routed to (dim_queue).';
COMMENT ON COLUMN cc.contact.agent_id       IS 'Agent who handled it (dim_agent); null when abandoned.';
COMMENT ON COLUMN cc.contact.reason_id      IS 'Contact reason (dim_contact_reason).';
COMMENT ON COLUMN cc.contact.date_key       IS 'Date the contact was offered (dim_date).';
COMMENT ON COLUMN cc.contact.interval_id    IS '15-minute interval the contact was offered in (dim_time_interval).';
COMMENT ON COLUMN cc.contact.hold_count     IS 'Number of times the customer was put on hold.';
COMMENT ON COLUMN cc.contact.answered       IS 'True if an agent answered/handled the contact.';
COMMENT ON COLUMN cc.contact.abandoned      IS 'True if the customer gave up before an agent answered (phone and chat only).';
COMMENT ON COLUMN cc.contact.transferred    IS 'True if transferred to another agent or queue.';
COMMENT ON COLUMN cc.contact.transfer_count IS 'Number of transfers.';
COMMENT ON COLUMN cc.contact.escalated      IS 'True if escalated to a supervisor or specialist team.';
COMMENT ON COLUMN cc.contact.reply_count    IS 'Email / secure message only: number of replies sent; null for other channels.';

-- ---------- ivr_session ----------
COMMENT ON COLUMN cc.ivr_session.session_id        IS 'Primary key.';
COMMENT ON COLUMN cc.ivr_session.customer_id       IS 'Customer (customer); null if the caller did not authenticate.';
COMMENT ON COLUMN cc.ivr_session.start_ts          IS 'Call entered the IVR.';
COMMENT ON COLUMN cc.ivr_session.end_ts            IS 'Call left the IVR (hung up, or transferred to the agent queue).';
COMMENT ON COLUMN cc.ivr_session.duration_sec      IS 'Seconds in the IVR.';
COMMENT ON COLUMN cc.ivr_session.date_key          IS 'Date of the session (dim_date).';
COMMENT ON COLUMN cc.ivr_session.menu_path         IS 'Menu path taken, e.g. Main > Cards > Card Activation.';
COMMENT ON COLUMN cc.ivr_session.self_service_task IS 'Self-service task completed; null when the caller asked for an agent.';
COMMENT ON COLUMN cc.ivr_session.contained         IS 'True if fully handled by self-service (no agent needed).';
COMMENT ON COLUMN cc.ivr_session.opt_out_to_agent  IS 'True if the caller asked to speak to an agent.';
COMMENT ON COLUMN cc.ivr_session.contact_id        IS 'Resulting phone contact (contact) when the caller opted out; null if contained.';

-- ---------- survey_response ----------
COMMENT ON COLUMN cc.survey_response.survey_id      IS 'Primary key.';
COMMENT ON COLUMN cc.survey_response.contact_id     IS 'Contact surveyed (contact). One survey per contact at most.';
COMMENT ON COLUMN cc.survey_response.agent_id       IS 'Agent who handled the contact (dim_agent).';
COMMENT ON COLUMN cc.survey_response.customer_id    IS 'Customer who responded (customer).';
COMMENT ON COLUMN cc.survey_response.survey_ts      IS 'Survey completed.';
COMMENT ON COLUMN cc.survey_response.date_key       IS 'Date the survey was completed (dim_date).';
COMMENT ON COLUMN cc.survey_response.verbatim_theme IS 'Theme coded from the customer''s free-text comment.';

-- ---------- complaint ----------
COMMENT ON COLUMN cc.complaint.complaint_id     IS 'Primary key.';
COMMENT ON COLUMN cc.complaint.customer_id      IS 'Customer (customer).';
COMMENT ON COLUMN cc.complaint.contact_id       IS 'Contact that raised it (contact); null if raised outside the contact center.';
COMMENT ON COLUMN cc.complaint.opened_ts        IS 'Complaint logged.';
COMMENT ON COLUMN cc.complaint.closed_ts        IS 'Complaint resolved; null while still open.';
COMMENT ON COLUMN cc.complaint.date_key         IS 'Date opened (dim_date).';
COMMENT ON COLUMN cc.complaint.days_to_close    IS 'Days from opened to closed; null while open.';
COMMENT ON COLUMN cc.complaint.channel_received IS 'Where it was raised: a contact channel, Survey Follow-up, Branch, Web Form, Social Media or Regulator Referral.';
COMMENT ON COLUMN cc.complaint.category         IS 'Complaint category, e.g. Fees & Charges, Digital Banking, Service Quality.';
COMMENT ON COLUMN cc.complaint.severity         IS 'Low, Medium or High.';
COMMENT ON COLUMN cc.complaint.regulatory_flag  IS 'True if reportable to a regulator.';
COMMENT ON COLUMN cc.complaint.root_cause       IS 'Root cause assigned at closure.';
COMMENT ON COLUMN cc.complaint.launch_id        IS 'Launch the complaint relates to (product_launch); null if none.';
COMMENT ON COLUMN cc.complaint.status           IS 'Open or Closed.';

-- ---------- interval_volume (columns not documented in 09) ----------
COMMENT ON COLUMN cc.interval_volume.interval_ts        IS 'Start of the 15-minute interval (part of primary key).';
COMMENT ON COLUMN cc.interval_volume.date_key           IS 'Date (dim_date).';
COMMENT ON COLUMN cc.interval_volume.interval_id        IS 'Interval of the day (dim_time_interval).';
COMMENT ON COLUMN cc.interval_volume.queue_id           IS 'Queue (dim_queue; part of primary key).';
COMMENT ON COLUMN cc.interval_volume.offered            IS 'Contacts offered in the interval.';
COMMENT ON COLUMN cc.interval_volume.answered           IS 'Contacts answered.';
COMMENT ON COLUMN cc.interval_volume.answered_within_sl IS 'Contacts answered within the queue''s service level threshold.';
COMMENT ON COLUMN cc.interval_volume.abandoned          IS 'Contacts abandoned.';
COMMENT ON COLUMN cc.interval_volume.short_abandoned    IS 'Abandoned within 5 seconds (excluded from service level).';
COMMENT ON COLUMN cc.interval_volume.forecast_aht_sec   IS 'Forecast average handle time (previous 4 same weekdays).';
COMMENT ON COLUMN cc.interval_volume.actual_aht_sec     IS 'Actual average handle time of answered contacts.';
COMMENT ON COLUMN cc.interval_volume.asa_sec            IS 'Average speed of answer: mean queue wait of answered contacts.';
COMMENT ON COLUMN cc.interval_volume.abandon_rate       IS 'Abandoned / offered x 100.';

-- ---------- agent_schedule / agent_activity ----------
COMMENT ON COLUMN cc.agent_schedule.schedule_id        IS 'Primary key.';
COMMENT ON COLUMN cc.agent_schedule.agent_id           IS 'Agent (dim_agent).';
COMMENT ON COLUMN cc.agent_schedule.date_key           IS 'Work date (dim_date).';
COMMENT ON COLUMN cc.agent_schedule.activity           IS 'Open Shift (available for contacts), Break, Lunch, Training, Coaching, Meeting or PTO.';
COMMENT ON COLUMN cc.agent_schedule.scheduled_start_ts IS 'Planned start.';
COMMENT ON COLUMN cc.agent_schedule.scheduled_end_ts   IS 'Planned end.';
COMMENT ON COLUMN cc.agent_schedule.scheduled_min      IS 'Planned minutes.';
COMMENT ON COLUMN cc.agent_schedule.is_productive      IS 'True for Open Shift (time planned for handling contacts).';
COMMENT ON COLUMN cc.agent_activity.activity_id    IS 'Primary key.';
COMMENT ON COLUMN cc.agent_activity.agent_id       IS 'Agent (dim_agent).';
COMMENT ON COLUMN cc.agent_activity.date_key       IS 'Work date (dim_date).';
COMMENT ON COLUMN cc.agent_activity.state          IS 'Available (logged in, ready or on a contact), Break, Lunch, Training, Coaching, Meeting or Unavailable (unplanned aux).';
COMMENT ON COLUMN cc.agent_activity.state_start_ts IS 'State began.';
COMMENT ON COLUMN cc.agent_activity.state_end_ts   IS 'State ended.';
COMMENT ON COLUMN cc.agent_activity.duration_sec   IS 'Seconds in the state.';

-- ---------- agent_daily (columns not documented in 09) ----------
COMMENT ON COLUMN cc.agent_daily.agent_id                 IS 'Agent (dim_agent; part of primary key).';
COMMENT ON COLUMN cc.agent_daily.date_key                 IS 'Work date (dim_date; part of primary key).';
COMMENT ON COLUMN cc.agent_daily.is_pto                   IS 'Planned paid time off day.';
COMMENT ON COLUMN cc.agent_daily.is_absent                IS 'Unplanned absence (scheduled but did not log in).';
COMMENT ON COLUMN cc.agent_daily.is_training_day          IS 'New-hire training day (first 15 working days).';
COMMENT ON COLUMN cc.agent_daily.scheduled_min            IS 'Scheduled minutes excluding PTO.';
COMMENT ON COLUMN cc.agent_daily.scheduled_productive_min IS 'Scheduled Open Shift minutes.';
COMMENT ON COLUMN cc.agent_daily.logged_in_min            IS 'Minutes logged in, in any state.';
COMMENT ON COLUMN cc.agent_daily.in_adherence_min         IS 'Minutes where the actual state matched the scheduled activity.';
COMMENT ON COLUMN cc.agent_daily.late_login_min           IS 'Minutes between scheduled start and first login (0 if on time or early).';
COMMENT ON COLUMN cc.agent_daily.early_logout_min         IS 'Minutes between last logout and scheduled end (0 if on time or late).';
COMMENT ON COLUMN cc.agent_daily.extended_break_min       IS 'Break and lunch minutes taken beyond the scheduled length.';
COMMENT ON COLUMN cc.agent_daily.unplanned_aux_min        IS 'Minutes in the Unavailable state (not on the schedule).';
COMMENT ON COLUMN cc.agent_daily.available_min            IS 'Minutes in the Available state.';
COMMENT ON COLUMN cc.agent_daily.handle_min               IS 'Total handle minutes of contacts answered that day.';
COMMENT ON COLUMN cc.agent_daily.shrinkage_break_min      IS 'Actual break minutes.';
COMMENT ON COLUMN cc.agent_daily.shrinkage_lunch_min      IS 'Actual lunch minutes.';
COMMENT ON COLUMN cc.agent_daily.shrinkage_training_min   IS 'Actual training minutes.';
COMMENT ON COLUMN cc.agent_daily.shrinkage_coaching_min   IS 'Actual coaching minutes.';
COMMENT ON COLUMN cc.agent_daily.shrinkage_meeting_min    IS 'Actual meeting minutes.';
COMMENT ON COLUMN cc.agent_daily.shrinkage_absence_min    IS 'Scheduled minutes lost to unplanned absence.';
COMMENT ON COLUMN cc.agent_daily.contacts_handled         IS 'Contacts answered, all channels.';
COMMENT ON COLUMN cc.agent_daily.phone_contacts           IS 'Phone contacts answered.';
COMMENT ON COLUMN cc.agent_daily.chat_contacts            IS 'Chats answered.';
COMMENT ON COLUMN cc.agent_daily.email_contacts           IS 'Emails handled.';
COMMENT ON COLUMN cc.agent_daily.callback_contacts        IS 'Callbacks made.';
COMMENT ON COLUMN cc.agent_daily.secure_msg_contacts      IS 'Secure messages handled.';
COMMENT ON COLUMN cc.agent_daily.avg_queue_wait_sec       IS 'Average queue wait of the contacts the agent answered.';
COMMENT ON COLUMN cc.agent_daily.avg_talk_sec             IS 'Average talk seconds.';
COMMENT ON COLUMN cc.agent_daily.avg_hold_sec             IS 'Average hold seconds.';
COMMENT ON COLUMN cc.agent_daily.avg_wrap_sec             IS 'Average wrap-up seconds.';
COMMENT ON COLUMN cc.agent_daily.avg_handle_sec           IS 'Average handle seconds (talk + hold + wrap).';
COMMENT ON COLUMN cc.agent_daily.fcr_rate                 IS 'First contact resolution % of contacts answered.';
COMMENT ON COLUMN cc.agent_daily.quality_score            IS 'Quality evaluation score 50-100 (sampled ~1 day in 5); null when not evaluated.';
