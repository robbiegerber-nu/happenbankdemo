-- Months, names and the phone menu table for Self-Service & Channel Shift.
SELECT json_build_object(
  'data_through', (SELECT max(d.full_date) FROM cc.contact JOIN cc.dim_date d USING (date_key)),
  'generated_at', to_char(now() AT TIME ZONE 'America/Chicago', 'YYYY-MM-DD"T"HH24:MI:SS'),
  'months', (SELECT json_agg(m ORDER BY m) FROM (SELECT DISTINCT (mk / 100) || '-' || lpad((mk % 100)::text, 2, '0') AS m FROM dash.ss_contact) x),
  'channels', (SELECT json_agg(json_build_array(channel_id, channel_name) ORDER BY channel_id) FROM cc.dim_channel),
  'reasons', (SELECT json_agg(json_build_array(reason_id, reason, reason_group) ORDER BY reason_id) FROM cc.dim_contact_reason),
  'personas', (SELECT json_agg(json_build_array(persona_id, persona_name) ORDER BY persona_id) FROM cc.dim_persona),
  'tasks', (SELECT json_agg(json_build_array(id, name, r) ORDER BY id) FROM dash.ss_task),
  'ivr_keys', json_build_array('m','p','t','n','d','k','b7','a1','a7'),
  'ivr', (SELECT json_agg(json_build_array((mk / 100) || '-' || lpad((mk % 100)::text, 2, '0'), p, t, n, d, k, b7, a1, a7) ORDER BY mk, p, t) FROM dash.ss_ivr));
