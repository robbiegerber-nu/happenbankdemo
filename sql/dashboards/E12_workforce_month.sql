-- One month of dash.wf_interval as column arrays (psql -v m=YYYY-MM). d is the day of the month; the rest are agent minutes.
SELECT json_build_object('m', :'m', 'cols', json_build_object(
  'd', json_agg(extract(day FROM d)::int ORDER BY d, t, i), 'i', json_agg(i ORDER BY d, t, i), 't', json_agg(t ORDER BY d, t, i),
  'open', json_agg(open ORDER BY d, t, i), 'sbrk', json_agg(sbrk ORDER BY d, t, i), 'slun', json_agg(slun ORDER BY d, t, i),
  'smtg', json_agg(smtg ORDER BY d, t, i), 'absent', json_agg(absent ORDER BY d, t, i), 'avail', json_agg(avail ORDER BY d, t, i),
  'aux', json_agg(aux ORDER BY d, t, i), 'abrk', json_agg(abrk ORDER BY d, t, i), 'alun', json_agg(alun ORDER BY d, t, i), 'amtg', json_agg(amtg ORDER BY d, t, i)))
FROM dash.wf_interval
WHERE d >= to_date(:'m', 'YYYY-MM') AND d < to_date(:'m', 'YYYY-MM') + interval '1 month';
