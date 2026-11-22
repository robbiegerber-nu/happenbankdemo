-- Business events used to annotate the daily volume timeline (dashboard v3).
-- Holidays and product launches come from the data itself; the rows below are known operational events.
\set ON_ERROR_STOP on
SET client_min_messages = warning;
CREATE TABLE IF NOT EXISTS discovery.dq_event (
  event_id    serial PRIMARY KEY,
  start_date  date NOT NULL,
  end_date    date NOT NULL,
  kind        text NOT NULL CHECK (kind IN ('Incident', 'Staffing', 'Launch', 'Holiday', 'Data')),
  title       text NOT NULL,
  description text NOT NULL
);
COMMENT ON TABLE discovery.dq_event IS 'Known business and operational events shown on the daily volume timeline.';

DELETE FROM discovery.dq_event WHERE kind IN ('Incident', 'Staffing');
INSERT INTO discovery.dq_event (start_date, end_date, kind, title, description) VALUES
 ('2026-04-07', '2026-04-08', 'Incident', 'Online banking outage', 'Two-day online banking outage: digital access contacts spiked and service level fell to about 32%.'),
 ('2025-06-01', '2025-08-31', 'Staffing', 'Summer staffing crunch', 'Higher attrition and a hiring freeze cut phone headcount from about 117 to 85; waits and abandons rose.'),
 ('2025-09-03', '2025-09-12', 'Staffing', 'Hiring surge', 'Post-freeze hiring classes finished training; agents logged in jumped 35-47% above recent weeks.');
