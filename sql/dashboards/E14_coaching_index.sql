-- Agents, teams and the monthly table for Agent & Team Coaching (rows as arrays in the order of keys).
SELECT json_build_object(
  'data_through', (SELECT max(d.full_date) FROM cc.interval_volume v JOIN cc.dim_date d USING (date_key)),
  'generated_at', to_char(now() AT TIME ZONE 'America/Chicago', 'YYYY-MM-DD"T"HH24:MI:SS'),
  'months', (SELECT json_agg(m ORDER BY m) FROM (SELECT DISTINCT (mk / 100) || '-' || lpad((mk % 100)::text, 2, '0') AS m FROM dash.coaching) x),
  'teams', (SELECT json_agg(json_build_object('id', t.team_id, 'name', t.team_name, 'ch', t.primary_channel_id, 'site', s.site_name, 'sup', g.display_name) ORDER BY t.team_id)
            FROM cc.dim_team t JOIN cc.dim_site s USING (site_id) LEFT JOIN cc.dim_agent g ON g.agent_id = t.supervisor_id),
  'agents', (SELECT json_agg(json_build_array(a.agent_id, a.display_name, a.employee_number, a.team_id, a.primary_channel_id, a.hire_date, a.term_date) ORDER BY a.agent_id)
             FROM cc.dim_agent a WHERE a.agent_id IN (SELECT g FROM dash.coaching)),
  'keys', json_build_array('m','g','n','sch','adh','aa','ab','bb','late','early','ext','aux','coa','trn','qn','qs','qq','ans','h','eh','vh','tk','etk','hd','ehd','wr','ewr','res','eres','vres','tr','etr','vtr','sv','sat','esat','vsat'),
  'rows', (SELECT json_agg(json_build_array((mk / 100) || '-' || lpad((mk % 100)::text, 2, '0'), g, n, sch, round(adh, 1), round(aa), round(ab), round(bb), late, early, ext, aux, coa, trn, qn, qs, qq,
             ans, h, round(eh), round(vh), tk, round(etk), hd, round(ehd), wr, round(ewr), res, round(eres, 2), round(vres, 2), tr, round(etr, 2), round(vtr, 2), sv, sat, round(esat, 2), round(vsat, 2)) ORDER BY mk, g) FROM dash.coaching));
