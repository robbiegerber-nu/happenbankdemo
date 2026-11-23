-- Business events for time charts (dash.v_events, defined in E00_dash_schema.sql), plus the data date.
SELECT json_build_object(
  'data_through', (SELECT max(d.full_date) FROM cc.interval_volume v JOIN cc.dim_date d USING (date_key)),
  'generated_at', to_char(now() AT TIME ZONE 'America/Chicago', 'YYYY-MM-DD"T"HH24:MI:SS'),
  'events', (SELECT json_agg(json_build_object('start', start_date, 'end', end_date, 'name', name, 'kind', kind,
                                               'span', span, 'description', description) ORDER BY start_date) FROM dash.v_events));
