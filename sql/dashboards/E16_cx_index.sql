-- Months and names for Customer Experience.
SELECT json_build_object(
  'data_through', (SELECT max(d.full_date) FROM cc.contact JOIN cc.dim_date d USING (date_key)),
  'generated_at', to_char(now() AT TIME ZONE 'America/Chicago', 'YYYY-MM-DD"T"HH24:MI:SS'),
  'months', (SELECT json_agg(m ORDER BY m) FROM (SELECT DISTINCT (mk / 100) || '-' || lpad((mk % 100)::text, 2, '0') AS m FROM dash.cx_contact) x),
  'channels', (SELECT json_agg(json_build_array(channel_id, channel_name) ORDER BY channel_id) FROM cc.dim_channel),
  'queues', (SELECT json_agg(json_build_array(queue_id, queue_name, channel_id) ORDER BY queue_id) FROM cc.dim_queue),
  'reasons', (SELECT json_agg(json_build_array(reason_id, reason, reason_group) ORDER BY reason_id) FROM cc.dim_contact_reason),
  'personas', (SELECT json_agg(json_build_array(persona_id, persona_name) ORDER BY persona_id) FROM cc.dim_persona),
  'names', (SELECT json_object_agg(k, v) FROM (SELECT k, json_object_agg(id, name) AS v FROM dash.cx_name GROUP BY k) x));
