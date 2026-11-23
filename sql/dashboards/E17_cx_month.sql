-- One month of Customer Experience as column arrays (psql -v m=YYYY-MM).
WITH k AS (SELECT replace(:'m', '-', '')::int AS mk)
SELECT json_build_object('m', :'m',
  'c', (SELECT json_build_object('q', json_agg(q ORDER BY q, r, s, p), 'r', json_agg(r ORDER BY q, r, s, p), 's', json_agg(s ORDER BY q, r, s, p), 'p', json_agg(p ORDER BY q, r, s, p),
          'o', json_agg(o ORDER BY q, r, s, p), 'a', json_agg(a ORDER BY q, r, s, p), 'f', json_agg(f ORDER BY q, r, s, p), 'i', json_agg(i ORDER BY q, r, s, p), 'e', json_agg(e ORDER BY q, r, s, p))
        FROM dash.cx_contact JOIN k USING (mk)),
  'v', (SELECT json_build_object('q', json_agg(q ORDER BY n), 'r', json_agg(r ORDER BY n), 's', json_agg(s ORDER BY n), 'p', json_agg(p ORDER BY n),
          'cs', json_agg(cs ORDER BY n), 'np', json_agg(np ORDER BY n), 'ce', json_agg(ce ORDER BY n), 't', json_agg(t ORDER BY n), 'hap', json_agg(hap ORDER BY n))
        FROM (SELECT v.*, row_number() OVER (ORDER BY q, r, s, p, t, hap, cs, np, ce) AS n FROM dash.cx_survey v JOIN k USING (mk)) x),
  'x', (SELECT json_build_object('q', json_agg(q ORDER BY n), 'r', json_agg(r ORDER BY n), 's', json_agg(s ORDER BY n), 'p', json_agg(p ORDER BY n),
          'cat', json_agg(cat ORDER BY n), 'sev', json_agg(sev ORDER BY n), 'cause', json_agg(cause ORDER BY n), 'via', json_agg(via ORDER BY n), 'reg', json_agg(reg ORDER BY n), 'd', json_agg(dtc ORDER BY n))
        FROM (SELECT y.*, row_number() OVER (ORDER BY q, r, s, p, cat, cause, sev, via, reg, dtc) AS n FROM dash.cx_complaint y JOIN k USING (mk)) x));
