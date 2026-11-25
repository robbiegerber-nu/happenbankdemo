-- Cells, quarters and names for Customer & Persona Insights.
SELECT json_build_object(
  'data_through', (SELECT max(d.full_date) FROM cc.contact JOIN cc.dim_date d USING (date_key)),
  'generated_at', to_char(now() AT TIME ZONE 'America/Chicago', 'YYYY-MM-DD"T"HH24:MI:SS'),
  'months', (SELECT json_agg(m ORDER BY m) FROM (SELECT DISTINCT (mk / 100) || '-' || lpad((mk % 100)::text, 2, '0') AS m FROM dash.pi_month) x),
  'quarters', (SELECT json_agg(q ORDER BY q) FROM (SELECT DISTINCT to_char(q, 'YYYY-MM') AS q FROM dash.pi_cell) x),
  'cells', (SELECT json_agg(json_build_array(cell, p, s, a, d) ORDER BY cell) FROM (SELECT DISTINCT cell, p, s, a, d FROM dash.pi_cell) x),
  'customers', (SELECT json_agg(json_build_array(to_char(q, 'YYYY-MM'), cell, n) ORDER BY q, cell) FROM dash.pi_cell),
  'reach', (SELECT json_agg(json_build_array(to_char(q, 'YYYY-MM'), cell, c1, c2, c4, k, coalesce(k4, 0)) ORDER BY q, cell) FROM dash.pi_reach),
  'personas', (SELECT json_agg(json_build_object('id', persona_id, 'name', persona_name, 'about', description, 'channel', preferred_channel, 'digital', digital_affinity, 'price', price_sensitivity, 'ages', typical_age_band) ORDER BY persona_id) FROM cc.dim_persona),
  'names', (SELECT json_object_agg(k, v) FROM (SELECT k, json_object_agg(id, name) AS v FROM dash.pi_name GROUP BY k) x),
  'channels', (SELECT json_agg(json_build_array(channel_id, channel_name) ORDER BY channel_id) FROM cc.dim_channel),
  'reasons', (SELECT json_agg(json_build_array(reason_id, reason, reason_group) ORDER BY reason_id) FROM cc.dim_contact_reason));
