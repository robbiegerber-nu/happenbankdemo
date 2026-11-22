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
