-- Happen Bank contact center DEMO dataset - schema
-- 100% synthetic data for dashboard demonstrations. Not real Happen Bank data.
\set ON_ERROR_STOP on
SET client_min_messages = warning;
DROP SCHEMA IF EXISTS cc CASCADE;
DROP SCHEMA IF EXISTS gen CASCADE;
CREATE SCHEMA cc;
CREATE SCHEMA gen;
COMMENT ON SCHEMA cc  IS 'Happen Bank contact center DEMO dataset. 100% synthetic, generated for dashboard demonstrations. Not real Happen Bank data.';
COMMENT ON SCHEMA gen IS 'Scratch/parameter tables used while generating the synthetic data. Safe to drop.';

-- ============ Lookup / dimension tables ============
CREATE TABLE cc.dataset_info (info_key text PRIMARY KEY, info_value text NOT NULL);

CREATE TABLE cc.dim_date (
  date_key              int PRIMARY KEY,           -- yyyymmdd
  full_date             date NOT NULL UNIQUE,
  day_name              text NOT NULL,
  day_of_week           smallint NOT NULL,         -- ISO: 1=Mon .. 7=Sun
  is_weekend            boolean NOT NULL,
  is_holiday            boolean NOT NULL,
  holiday_name          text,
  is_center_closed      boolean NOT NULL,
  week_start            date NOT NULL,
  month_num             smallint NOT NULL,
  month_name            text NOT NULL,
  quarter_num           smallint NOT NULL,
  year_num              smallint NOT NULL,
  year_month            text NOT NULL,
  fiscal_period         text NOT NULL,
  is_month_start_window boolean NOT NULL,
  is_payday             boolean NOT NULL
);

CREATE TABLE cc.dim_time_interval (
  interval_id    smallint PRIMARY KEY,             -- 0..95 (15-minute slots)
  interval_start time NOT NULL,
  interval_end   time NOT NULL,
  hour_of_day    smallint NOT NULL,
  daypart        text NOT NULL,
  interval_label text NOT NULL
);

CREATE TABLE cc.dim_channel (
  channel_id       smallint PRIMARY KEY,
  channel_name     text NOT NULL UNIQUE,
  is_real_time     boolean NOT NULL,
  sl_target_pct    numeric(5,2) NOT NULL,
  sl_threshold_sec int NOT NULL,
  sl_label         text NOT NULL
);

CREATE TABLE cc.dim_queue (
  queue_id         smallint PRIMARY KEY,
  queue_name       text NOT NULL UNIQUE,
  channel_id       smallint NOT NULL,
  skill            text NOT NULL,
  priority         smallint NOT NULL,
  sl_target_pct    numeric(5,2) NOT NULL,
  sl_threshold_sec int NOT NULL
);

CREATE TABLE cc.dim_site (
  site_id       smallint PRIMARY KEY,
  site_name     text NOT NULL,
  city          text NOT NULL,
  state_code    char(2) NOT NULL,
  is_outsourced boolean NOT NULL,
  timezone      text NOT NULL
);

CREATE TABLE cc.dim_team (
  team_id            smallint PRIMARY KEY,
  team_name          text NOT NULL,
  site_id            smallint NOT NULL,
  supervisor_id      int,
  primary_channel_id smallint NOT NULL
);

CREATE TABLE cc.dim_agent (
  agent_id             int PRIMARY KEY,
  employee_number      text NOT NULL UNIQUE,
  first_name           text NOT NULL,
  last_name            text NOT NULL,
  display_name         text NOT NULL,
  team_id              smallint NOT NULL,
  role                 text NOT NULL,
  hire_date            date NOT NULL,
  term_date            date,
  hire_class_id        int,
  primary_channel_id   smallint NOT NULL,
  channels_certified   text NOT NULL,
  employment_type      text NOT NULL,
  shift_pattern        text,
  shift_start          time,
  max_concurrent_chats smallint
);

CREATE TABLE cc.dim_region (
  region_id  smallint PRIMARY KEY,
  state_code char(2) NOT NULL,
  state_name text NOT NULL,
  metro      text NOT NULL,
  area_type  text NOT NULL
);

CREATE TABLE cc.dim_persona (
  persona_id        smallint PRIMARY KEY,
  persona_name      text NOT NULL UNIQUE,
  description       text NOT NULL,
  preferred_channel text NOT NULL,
  digital_affinity  smallint NOT NULL,
  price_sensitivity text NOT NULL,
  typical_age_band  text NOT NULL
);

CREATE TABLE cc.dim_product (
  product_id       smallint PRIMARY KEY,
  product_name     text NOT NULL UNIQUE,
  category         text NOT NULL,
  launch_id        smallint,
  is_new_in_period boolean NOT NULL,
  introduced_date  date
);

CREATE TABLE cc.product_launch (
  launch_id               smallint PRIMARY KEY,
  launch_name             text NOT NULL,
  launch_date             date NOT NULL,
  product_id              smallint NOT NULL,
  launch_type             text NOT NULL,
  target_personas         text NOT NULL,
  expected_contact_impact text NOT NULL,
  marketing_spend_band    text NOT NULL,
  description             text NOT NULL
);

CREATE TABLE cc.dim_contact_reason (
  reason_id                  smallint PRIMARY KEY,
  reason                     text NOT NULL UNIQUE,
  reason_group               text NOT NULL,
  is_launch_related_possible boolean NOT NULL DEFAULT false
);

CREATE TABLE cc.launch_reason_impact (
  launch_id smallint NOT NULL,
  reason_id smallint NOT NULL,
  peak_lift numeric(5,2) NOT NULL,
  PRIMARY KEY (launch_id, reason_id)
);

-- ============ Customer tables ============
CREATE TABLE cc.customer (
  customer_id           int PRIMARY KEY,
  persona_id            smallint NOT NULL,
  region_id             smallint NOT NULL,
  age                   smallint NOT NULL,
  age_band              text NOT NULL,
  gender                text,
  income_band           text,
  customer_since        date NOT NULL,
  segment               text NOT NULL,
  digital_enrolled      boolean NOT NULL,
  digital_enrolled_date date,
  preferred_language    text NOT NULL,
  household_size        smallint NOT NULL
);

CREATE TABLE cc.customer_product (
  customer_product_id  bigint PRIMARY KEY,
  customer_id          int NOT NULL,
  product_id           smallint NOT NULL,
  open_date            date NOT NULL,
  close_date           date,
  status               text NOT NULL,
  opened_via_launch_id smallint
);

-- ============ Contact center fact tables ============
CREATE TABLE cc.contact (
  contact_id             bigint PRIMARY KEY,
  customer_id            int,
  channel_id             smallint NOT NULL,
  queue_id               smallint NOT NULL,
  agent_id               int,
  reason_id              smallint NOT NULL,
  launch_id              smallint,
  date_key               int NOT NULL,
  interval_id            smallint NOT NULL,
  offered_ts             timestamptz NOT NULL,
  answered_ts            timestamptz,
  abandoned_ts           timestamptz,
  customer_end_ts        timestamptz,
  wrap_end_ts            timestamptz,
  queue_wait_sec         int NOT NULL,
  talk_sec               int NOT NULL DEFAULT 0,
  hold_sec               int NOT NULL DEFAULT 0,
  hold_count             smallint NOT NULL DEFAULT 0,
  wrap_sec               int NOT NULL DEFAULT 0,
  handle_sec             int NOT NULL DEFAULT 0,
  answered               boolean NOT NULL,
  abandoned              boolean NOT NULL,
  short_abandon          boolean NOT NULL DEFAULT false,
  met_service_level      boolean NOT NULL,
  transferred            boolean NOT NULL DEFAULT false,
  transfer_count         smallint NOT NULL DEFAULT 0,
  first_contact_resolved boolean,
  repeat_within_7d       boolean NOT NULL DEFAULT false,
  escalated              boolean NOT NULL DEFAULT false,
  sentiment_score        numeric(4,3),
  concurrent_chats       smallint,
  reply_count            smallint
);

CREATE TABLE cc.ivr_session (
  session_id        bigint PRIMARY KEY,
  customer_id       int,
  start_ts          timestamptz NOT NULL,
  end_ts            timestamptz NOT NULL,
  duration_sec      int NOT NULL,
  date_key          int NOT NULL,
  menu_path         text NOT NULL,
  self_service_task text,
  contained         boolean NOT NULL,
  opt_out_to_agent  boolean NOT NULL,
  contact_id        bigint
);

CREATE TABLE cc.survey_response (
  survey_id      bigint PRIMARY KEY,
  contact_id     bigint NOT NULL UNIQUE,
  agent_id       int NOT NULL,
  customer_id    int NOT NULL,
  survey_ts      timestamptz NOT NULL,
  date_key       int NOT NULL,
  csat           smallint NOT NULL CHECK (csat BETWEEN 1 AND 5),
  nps            smallint NOT NULL CHECK (nps BETWEEN 0 AND 10),
  ces            smallint NOT NULL CHECK (ces BETWEEN 1 AND 7),
  verbatim_theme text NOT NULL
);

CREATE TABLE cc.complaint (
  complaint_id     bigint PRIMARY KEY,
  customer_id      int NOT NULL,
  contact_id       bigint,
  opened_ts        timestamptz NOT NULL,
  closed_ts        timestamptz,
  date_key         int NOT NULL,
  days_to_close    numeric(6,1),
  channel_received text NOT NULL,
  category         text NOT NULL,
  severity         text NOT NULL,
  regulatory_flag  boolean NOT NULL,
  root_cause       text NOT NULL,
  launch_id        smallint,
  status           text NOT NULL
);

CREATE TABLE cc.interval_volume (
  interval_ts        timestamptz NOT NULL,
  date_key           int NOT NULL,
  interval_id        smallint NOT NULL,
  queue_id           smallint NOT NULL,
  forecast_contacts  numeric(8,2) NOT NULL,
  offered            int NOT NULL,
  answered           int NOT NULL,
  answered_within_sl int NOT NULL,
  abandoned          int NOT NULL,
  short_abandoned    int NOT NULL,
  forecast_aht_sec   numeric(8,1),
  actual_aht_sec     numeric(8,1),
  asa_sec            numeric(10,1),
  scheduled_fte      numeric(7,2) NOT NULL,
  required_fte       numeric(7,2) NOT NULL,
  service_level_pct  numeric(5,2),
  abandon_rate       numeric(5,2),
  PRIMARY KEY (interval_ts, queue_id)
);

CREATE TABLE cc.agent_schedule (
  schedule_id        bigint PRIMARY KEY,
  agent_id           int NOT NULL,
  date_key           int NOT NULL,
  activity           text NOT NULL,
  scheduled_start_ts timestamptz NOT NULL,
  scheduled_end_ts   timestamptz NOT NULL,
  scheduled_min      int NOT NULL,
  is_productive      boolean NOT NULL
);

CREATE TABLE cc.agent_activity (
  activity_id    bigint PRIMARY KEY,
  agent_id       int NOT NULL,
  date_key       int NOT NULL,
  state          text NOT NULL,
  state_start_ts timestamptz NOT NULL,
  state_end_ts   timestamptz NOT NULL,
  duration_sec   int NOT NULL
);

CREATE TABLE cc.agent_daily (
  agent_id                 int NOT NULL,
  date_key                 int NOT NULL,
  is_pto                   boolean NOT NULL,
  is_absent                boolean NOT NULL,
  is_training_day          boolean NOT NULL,
  scheduled_min            int NOT NULL,
  scheduled_productive_min int NOT NULL,
  logged_in_min            numeric(7,1) NOT NULL,
  in_adherence_min         numeric(7,1) NOT NULL,
  adherence_pct            numeric(5,2),
  conformance_pct          numeric(6,2),
  late_login_min           numeric(6,1) NOT NULL,
  early_logout_min         numeric(6,1) NOT NULL,
  extended_break_min       numeric(6,1) NOT NULL,
  unplanned_aux_min        numeric(6,1) NOT NULL,
  available_min            numeric(7,1) NOT NULL,
  handle_min               numeric(7,1) NOT NULL,
  occupancy_pct            numeric(5,2),
  shrinkage_break_min      numeric(6,1) NOT NULL,
  shrinkage_lunch_min      numeric(6,1) NOT NULL,
  shrinkage_training_min   numeric(6,1) NOT NULL,
  shrinkage_coaching_min   numeric(6,1) NOT NULL,
  shrinkage_meeting_min    numeric(6,1) NOT NULL,
  shrinkage_absence_min    numeric(6,1) NOT NULL,
  contacts_handled         int NOT NULL,
  phone_contacts           int NOT NULL,
  chat_contacts            int NOT NULL,
  email_contacts           int NOT NULL,
  callback_contacts        int NOT NULL,
  secure_msg_contacts      int NOT NULL,
  avg_queue_wait_sec       numeric(10,1),
  avg_talk_sec             numeric(8,1),
  avg_hold_sec             numeric(8,1),
  avg_wrap_sec             numeric(8,1),
  avg_handle_sec           numeric(8,1),
  fcr_rate                 numeric(5,2),
  quality_score            smallint,
  PRIMARY KEY (agent_id, date_key)
);

-- ============ Helper functions ============
-- Weighted pick: returns the 1-based index of w chosen by uniform r in [0,1).
CREATE FUNCTION gen.pick(w numeric[], r double precision) RETURNS int
LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce((
    SELECT i FROM (
      SELECT i, sum(w[i]) OVER (ORDER BY i) AS cs, sum(w[i]) OVER () AS tot
      FROM generate_subscripts(w, 1) AS i) s
    WHERE cs / tot > r ORDER BY i LIMIT 1), array_length(w, 1));
$$;

-- 15-minute interval id (0..95) of a timestamp, in the session time zone (America/Chicago).
CREATE FUNCTION gen.iv(ts timestamptz) RETURNS smallint
LANGUAGE sql STABLE AS $$
  SELECT (extract(hour FROM ts) * 4 + floor(extract(minute FROM ts) / 15))::smallint;
$$;

CREATE FUNCTION gen.dk(ts timestamptz) RETURNS int
LANGUAGE sql STABLE AS $$ SELECT to_char(ts, 'YYYYMMDD')::int; $$;
