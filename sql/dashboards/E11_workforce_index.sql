-- Teams and the daily table for Workforce Management (all days; one row per day x team).
SELECT json_build_object(
  'data_through', (SELECT max(d.full_date) FROM cc.interval_volume v JOIN cc.dim_date d USING (date_key)),
  'generated_at', to_char(now() AT TIME ZONE 'America/Chicago', 'YYYY-MM-DD"T"HH24:MI:SS'),
  'months', (SELECT json_agg(m ORDER BY m) FROM (SELECT DISTINCT to_char(d, 'YYYY-MM') AS m FROM dash.wf_interval) x),
  'teams', (SELECT json_agg(json_build_object('id', t.team_id, 'name', t.team_name, 'ch', t.primary_channel_id, 'site', s.site_name, 'sup', g.display_name) ORDER BY t.team_id)
            FROM cc.dim_team t JOIN cc.dim_site s USING (site_id) LEFT JOIN cc.dim_agent g ON g.agent_id = t.supervisor_id),
  'keys', json_build_array('d','t','n','nabs','npto','sched','worked','li','adh','av','occ','late','early','ext','aux','brk','lun','trn','coa','mtg','abs'),
  'days', (SELECT json_agg(json_build_array(d, t, n, nabs, npto, coalesce(sched, 0), worked, li, adh, av, occ, late, early, ext, aux, brk, lun, trn, coa, mtg, abs) ORDER BY d, t) FROM dash.wf_day));
