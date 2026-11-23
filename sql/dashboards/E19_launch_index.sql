-- Everything Product Launch Impact reads, in one file (rows as arrays in the order of keys).
SELECT json_build_object(
  'data_through', (SELECT max(d.full_date) FROM cc.contact JOIN cc.dim_date d USING (date_key)),
  'used_through', DATE '2026-10-31',
  'generated_at', to_char(now() AT TIME ZONE 'America/Chicago', 'YYYY-MM-DD"T"HH24:MI:SS'),
  'launches', (SELECT json_agg(json_build_object('id', l.launch_id, 'name', l.launch_name, 'date', l.launch_date, 'type', l.launch_type, 'targets', l.target_personas,
                 'planned', l.expected_contact_impact, 'spend', l.marketing_spend_band, 'about', l.description,
                 'reasons', (SELECT json_agg(i.reason_id ORDER BY i.reason_id) FROM cc.launch_reason_impact i WHERE i.launch_id = l.launch_id)) ORDER BY l.launch_date)
               FROM cc.product_launch l),
  'reasons', (SELECT json_agg(json_build_array(reason_id, reason, reason_group) ORDER BY reason_id) FROM cc.dim_contact_reason),
  'channels', (SELECT json_agg(json_build_array(channel_id, channel_name) ORDER BY channel_id) FROM cc.dim_channel),
  'personas', (SELECT json_agg(json_build_array(persona_id, persona_name) ORDER BY persona_id) FROM cc.dim_persona),
  'keys', json_build_array('l','w','r','o','a','h','f','g','met','i','e','sv','sat','t'),
  'rows', (SELECT json_agg(json_build_array(l, w, r, o, a, h, f, g, met, i, e, sv, sat, t) ORDER BY l, w, r) FROM dash.launch_week),
  'who', (SELECT json_agg(json_build_array(l, w, k, id, n) ORDER BY l, k, w, id) FROM dash.launch_who),
  'comp', (SELECT json_agg(json_build_array(l, w, category, n, hi) ORDER BY l, w, category) FROM dash.launch_comp));
