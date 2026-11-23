-- Data discovery & data quality: storage for results.
-- Results are APPENDED per run (run_id), so the health dashboard can show history. Re-running this file is safe.
\set ON_ERROR_STOP on
SET client_min_messages = warning;
CREATE SCHEMA IF NOT EXISTS discovery;
COMMENT ON SCHEMA discovery IS 'Data discovery and data quality results for the cc schema (one set of rows per run).';

-- One row per discovery run
CREATE TABLE IF NOT EXISTS discovery.dq_run (
  run_id       serial PRIMARY KEY,
  started_at   timestamptz NOT NULL DEFAULT now(),
  finished_at  timestamptz,
  notes        text
);

-- Table catalog: what's in the data product
CREATE TABLE IF NOT EXISTS discovery.dq_table_catalog (
  run_id        int NOT NULL REFERENCES discovery.dq_run,
  table_name    text NOT NULL,
  table_type    text NOT NULL,          -- Lookup | Fact | Customer | Summary | Metadata
  description   text,
  row_count     bigint NOT NULL,
  size_bytes    bigint NOT NULL,
  column_count  int NOT NULL,
  pk_columns    text,
  fk_count      int NOT NULL,
  date_column   text,                   -- column used for time coverage
  min_date      date,
  max_date      date,
  PRIMARY KEY (run_id, table_name)
);

-- Column profile: one row per column
CREATE TABLE IF NOT EXISTS discovery.dq_column_profile (
  run_id         int NOT NULL REFERENCES discovery.dq_run,
  table_name     text NOT NULL,
  column_name    text NOT NULL,
  ordinal        int NOT NULL,
  data_type      text NOT NULL,
  type_family    text NOT NULL,         -- number | text | boolean | date | time | other
  row_count      bigint NOT NULL,
  null_count     bigint NOT NULL,
  null_pct       numeric(7,3) NOT NULL,
  distinct_count bigint,
  distinct_pct   numeric(7,3),
  min_value      text,
  max_value      text,
  mean_value     numeric,
  stddev_value   numeric,
  p01 numeric, p25 numeric, p50 numeric, p75 numeric, p99 numeric,
  zero_count     bigint,
  negative_count bigint,
  empty_string_count bigint,
  true_pct       numeric(7,3),
  PRIMARY KEY (run_id, table_name, column_name)
);

-- Top values of categorical columns
CREATE TABLE IF NOT EXISTS discovery.dq_distribution (
  run_id      int NOT NULL REFERENCES discovery.dq_run,
  table_name  text NOT NULL,
  column_name text NOT NULL,
  rank        int NOT NULL,
  value       text,
  row_count   bigint NOT NULL,
  pct         numeric(7,3) NOT NULL,
  PRIMARY KEY (run_id, table_name, column_name, rank)
);

-- Rules are data: each rule is one SQL expression returning a single number (the measured value)
CREATE TABLE IF NOT EXISTS discovery.dq_rule (
  rule_id         text PRIMARY KEY,     -- e.g. CMP-001
  table_name      text NOT NULL,
  column_name     text,
  dimension       text NOT NULL CHECK (dimension IN ('Completeness','Uniqueness','Validity','Consistency','Volume','Timeliness')),
  rule_name       text NOT NULL,
  description     text NOT NULL,        -- plain English: what and why
  check_sql       text NOT NULL,        -- SELECT returning one numeric value
  unit            text NOT NULL,        -- rows | % | days | ratio
  warn_above      numeric NOT NULL,     -- measured value > warn_above  => Warn
  fail_above      numeric NOT NULL,     -- measured value > fail_above  => Fail
  severity        text NOT NULL CHECK (severity IN ('Critical','High','Medium','Low')),
  expected_note   text,                 -- known/explained exceptions
  is_active       boolean NOT NULL DEFAULT true
);

-- One row per rule per run
CREATE TABLE IF NOT EXISTS discovery.dq_check_result (
  run_id          int NOT NULL REFERENCES discovery.dq_run,
  rule_id         text NOT NULL,
  table_name      text NOT NULL,
  column_name     text,
  dimension       text NOT NULL,
  rule_name       text NOT NULL,
  severity        text NOT NULL,
  measured_value  numeric,
  unit            text NOT NULL,
  warn_above      numeric NOT NULL,
  fail_above      numeric NOT NULL,
  status          text NOT NULL CHECK (status IN ('Pass','Warn','Fail','Error')),
  description     text NOT NULL,
  expected_note   text,
  error_message   text,
  duration_ms     int,
  checked_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (run_id, rule_id)
);

-- Daily record counts per table, with outlier flags
CREATE TABLE IF NOT EXISTS discovery.dq_daily_volume (
  run_id        int NOT NULL REFERENCES discovery.dq_run,
  table_name    text NOT NULL,
  day           date NOT NULL,
  row_count     bigint NOT NULL,
  baseline      numeric,                -- median of the same weekday over the previous 4 weeks
  ratio         numeric,                -- row_count / baseline
  is_outlier    boolean NOT NULL DEFAULT false,
  is_center_closed boolean NOT NULL,
  PRIMARY KEY (run_id, table_name, day)
);

-- Context for business users (added for dashboard v2.4):
--   dq_rule.problem_plain   what the problem is, in plain words ("a data field that was never filled in")
--   dq_rule.evidence_sql    optional SELECT returning a JSON list of the specific items behind a result
--   dq_check_result.evidence  that list, captured at check time
--   dq_run.summary          what changed in the run, in plain words
ALTER TABLE discovery.dq_rule         ADD COLUMN IF NOT EXISTS problem_plain text;
ALTER TABLE discovery.dq_rule         ADD COLUMN IF NOT EXISTS evidence_sql text;
ALTER TABLE discovery.dq_check_result ADD COLUMN IF NOT EXISTS evidence jsonb;
ALTER TABLE discovery.dq_run          ADD COLUMN IF NOT EXISTS summary text;

-- ======================= v3.1: daily loads, incidents and alerts =======================
-- Settings: the latest business day loaded moves forward with every daily load.
CREATE TABLE IF NOT EXISTS discovery.dq_setting (
  key   text PRIMARY KEY,
  value text NOT NULL
);
COMMENT ON TABLE discovery.dq_setting IS 'Pipeline settings, e.g. period_end = the latest business day loaded.';

-- The end of the reporting period: latest business day loaded (31 Oct 2026 before daily loads began)
CREATE OR REPLACE FUNCTION discovery.period_end() RETURNS date LANGUAGE sql STABLE AS
$$ SELECT coalesce((SELECT value::date FROM discovery.dq_setting WHERE key = 'period_end'), date '2026-10-31') $$;
-- Customer and product data are a monthly snapshot, not a daily feed: their freshness is measured against the snapshot date
CREATE OR REPLACE FUNCTION discovery.snapshot_date() RETURNS date LANGUAGE sql STABLE AS
$$ SELECT coalesce((SELECT value::date FROM discovery.dq_setting WHERE key = 'snapshot_date'), date '2026-10-31') $$;

ALTER TABLE discovery.dq_run ADD COLUMN IF NOT EXISTS business_date date;   -- the business day this run checked (daily loads)
ALTER TABLE discovery.dq_run ADD COLUMN IF NOT EXISTS period_end date;      -- period end used by the rules in this run

-- One row per file received (or expected and missing)
CREATE TABLE IF NOT EXISTS discovery.dq_load (
  load_id        serial PRIMARY KEY,
  run_id         int REFERENCES discovery.dq_run,      -- the run that checked this load (set when the run starts)
  arrived_on     date NOT NULL,                        -- the day's folder the file arrived in
  business_date  date NOT NULL,                        -- the day the data is for (earlier than arrived_on for late and correction files)
  feed           text NOT NULL,                        -- contact, ivr_session, survey_response, ...
  file_name      text NOT NULL,
  load_kind      text NOT NULL CHECK (load_kind IN ('Daily', 'Late', 'Correction')),
  action         text NOT NULL CHECK (action IN ('insert', 'upsert', 'delete')),
  status         text NOT NULL CHECK (status IN ('Loaded', 'Count mismatch', 'Missing')),
  expected_rows  int,                                  -- from the sender's manifest
  rows_received  int NOT NULL DEFAULT 0,
  rows_inserted  int NOT NULL DEFAULT 0,
  rows_replaced  int NOT NULL DEFAULT 0,
  rows_deleted   int NOT NULL DEFAULT 0,
  rows_held      int NOT NULL DEFAULT 0,               -- waiting for a record they refer to (e.g. a survey whose contact hasn't arrived)
  rows_released  int NOT NULL DEFAULT 0,               -- earlier held rows loaded once their record arrived
  fixes_date     date,                                 -- corrections and late files: the business day they fix
  reason         text,                                 -- sender's note: why the file is late or what went wrong
  fix            text,                                 -- sender's note: what the correction does
  loaded_at      timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE discovery.dq_load IS 'Every daily, late and correction file received, or expected and missing, with row counts.';

-- One row per data problem, from the run that found it to the run that confirmed the fix
CREATE TABLE IF NOT EXISTS discovery.dq_incident (
  incident_id     serial PRIMARY KEY,
  rule_id         text NOT NULL,                       -- the most important check affected
  checks          jsonb NOT NULL,                      -- every check affected: {rule_id: {before_status, before_value, unit}}
  business_date   date NOT NULL,                       -- the day the problem arrived
  title           text NOT NULL,
  status          text NOT NULL CHECK (status IN ('Open', 'Resolved', 'Accepted')),
  opened_run_id   int NOT NULL REFERENCES discovery.dq_run,
  resolved_run_id int REFERENCES discovery.dq_run,
  impact          text,                                -- e.g. "7,530 rows: the same contact recorded twice"
  cause           text,                                -- why it happened (from the sender's correction notice)
  fix             text,                                -- what was done
  fix_load_id     int REFERENCES discovery.dq_load,    -- the correction or late file that fixed it
  github_issue    int,                                 -- the alert raised for it
  opened_at       timestamptz NOT NULL DEFAULT now(),
  resolved_at     timestamptz
);
COMMENT ON TABLE discovery.dq_incident IS 'Data problems found by the checks, with impact, cause, fix and the alert raised.';

-- One row per incident per run while it is open (including the opening and resolving runs)
CREATE TABLE IF NOT EXISTS discovery.dq_incident_update (
  incident_id int NOT NULL REFERENCES discovery.dq_incident,
  run_id      int NOT NULL REFERENCES discovery.dq_run,
  status      text NOT NULL,
  checks      jsonb NOT NULL,                          -- [{rule_id, status, value, unit}] in this run
  note        text NOT NULL,
  PRIMARY KEY (incident_id, run_id)
);
COMMENT ON TABLE discovery.dq_incident_update IS 'How each incident looked in every run while it was open.';

-- ======================= v3.2: checks flag only what needs recording =======================
-- Evidence is collected even when a check passes, for checks whose explained findings should stay visible
ALTER TABLE discovery.dq_rule ADD COLUMN IF NOT EXISTS evidence_always boolean NOT NULL DEFAULT false;

-- Findings a person reviewed and accepted: they stay listed in the evidence but no longer warn
CREATE TABLE IF NOT EXISTS discovery.dq_reviewed_finding (
  rule_id      text NOT NULL,
  item_key     text NOT NULL,          -- a day (yyyy-mm-dd) or a record id, depending on the check
  reason       text NOT NULL,
  reviewed_on  date NOT NULL,
  PRIMARY KEY (rule_id, item_key)
);
COMMENT ON TABLE discovery.dq_reviewed_finding IS 'Findings reviewed by a person and accepted, with the reason; they no longer raise warnings.';

-- Rows waiting for a record they refer to (child feeds whose contact has not arrived yet)
CREATE SCHEMA IF NOT EXISTS pipeline;
COMMENT ON SCHEMA pipeline IS 'Daily load staging: files are copied here, checked, then merged into cc.';

-- Health score per table x dimension
CREATE TABLE IF NOT EXISTS discovery.dq_scorecard (
  run_id      int NOT NULL REFERENCES discovery.dq_run,
  table_name  text NOT NULL,            -- '(all tables)' for the overall row
  dimension   text NOT NULL,            -- '(all dimensions)' for the table total
  checks      int NOT NULL,
  passed      int NOT NULL,
  warned      int NOT NULL,
  failed      int NOT NULL,
  score       numeric(5,1),             -- weighted: Pass = 1, Warn = 0.5, Fail = 0; weights Critical 4, High 3, Medium 2, Low 1
  status      text NOT NULL,
  PRIMARY KEY (run_id, table_name, dimension)
);
