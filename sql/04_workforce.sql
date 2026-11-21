-- Workforce: roster (hiring classes + attrition), teams, agents, planned schedule, actual activity.
\set ON_ERROR_STOP on
SET client_min_messages = warning;
SET max_parallel_workers_per_gather = 0;
SELECT setseed(0.43);

-- Target headcount by channel group (1=Phone/Callback, 2=Chat, 3=Email/Secure Message)
CREATE TABLE gen.target_hc AS
SELECT x.d, g.grp,
       round(CASE g.grp WHEN 1 THEN 118 - 22 * x.f WHEN 2 THEN 30 + 28 * x.f ELSE 27 - 3 * x.f END)::int AS target
FROM (SELECT d::date AS d, (d::date - date '2024-01-01') / 1034.0 AS f
      FROM generate_series('2024-01-01'::date, '2026-10-31'::date, '1 day') d) x
CROSS JOIN generate_series(1, 3) g(grp);

CREATE TABLE gen.roster (agent_id serial PRIMARY KEY, grp int, site_id int, hire_date date, term_date date,
                         hire_class_id int, emp_type text);

CREATE FUNCTION gen.pick_site(g int) RETURNS int LANGUAGE plpgsql VOLATILE AS $$
DECLARE r double precision := random();
BEGIN
  IF g = 3 THEN RETURN CASE WHEN r < .6 THEN 1 ELSE 2 END; END IF;
  RETURN CASE WHEN r < .45 THEN 1 WHEN r < .75 THEN 2 ELSE 3 END;
END $$;

-- Monthly attrition hazard; elevated Mar-Jul 2025 (the staffing crunch) and at the outsourced site.
CREATE FUNCTION gen.draw_term(p_hire date, p_site int) RETURNS date LANGUAGE plpgsql VOLATILE AS $$
DECLARE m date := greatest(date_trunc('month', p_hire)::date, date '2024-01-01'); h numeric; t date;
BEGIN
  WHILE m <= date '2026-10-01' LOOP
    h := CASE WHEN m - p_hire < 180 THEN 0.045 ELSE 0.021 END;
    IF m BETWEEN date '2025-03-01' AND date '2025-07-01' THEN h := h * 2.4; END IF;
    IF p_site = 3 THEN h := h * 1.4; END IF;
    IF random() < h THEN
      t := m + floor(random() * 28)::int;
      IF t > p_hire + 20 AND t <= date '2026-10-31' THEN RETURN t; END IF;
    END IF;
    m := (m + interval '1 month')::date;
  END LOOP;
  RETURN NULL;
END $$;

DO $$
DECLARE g int; i int; tgt int; act int; sz int; cls date; s int; hd date;
BEGIN
  FOR g IN 1..3 LOOP
    SELECT target INTO tgt FROM gen.target_hc WHERE d = date '2024-01-01' AND grp = g;
    FOR i IN 1..tgt LOOP
      s := gen.pick_site(g);
      hd := date '2023-12-15' - floor(random() ^ 1.7 * 3300)::int;
      INSERT INTO gen.roster(grp, site_id, hire_date, term_date, hire_class_id, emp_type)
      VALUES (g, s, hd, gen.draw_term(hd, s), NULL, CASE WHEN random() < .15 THEN 'Part-time' ELSE 'Full-time' END);
    END LOOP;
  END LOOP;
  -- hiring classes every 6 weeks; hiring freeze mid-Apr to late Jul 2025 (causes the summer staffing gap)
  cls := date '2024-01-22';
  WHILE cls <= date '2026-09-28' LOOP
    IF NOT (cls > date '2025-04-10' AND cls < date '2025-07-28') THEN
      FOR g IN 1..3 LOOP
        SELECT target INTO tgt FROM gen.target_hc WHERE d = least(cls + 42, date '2026-10-31') AND grp = g;
        SELECT count(*) INTO act FROM gen.roster WHERE grp = g AND hire_date <= cls AND (term_date IS NULL OR term_date > cls);
        sz := greatest(0, least(CASE g WHEN 1 THEN 20 ELSE 10 END,
                                tgt - act + round(act * 0.04)::int + floor(random() * 3)::int - 1));
        FOR i IN 1..sz LOOP
          s := gen.pick_site(g);
          INSERT INTO gen.roster(grp, site_id, hire_date, term_date, hire_class_id, emp_type)
          VALUES (g, s, cls, gen.draw_term(cls, s), to_char(cls, 'YYYYMMDD')::int,
                  CASE WHEN random() < .12 THEN 'Part-time' ELSE 'Full-time' END);
        END LOOP;
      END LOOP;
    END IF;
    cls := cls + 42;
  END LOOP;
END $$;

-- ---------- Teams ----------
INSERT INTO cc.dim_team (team_id, team_name, site_id, primary_channel_id) VALUES
 (1,'Phone - Team Atlas',1,1),(2,'Phone - Team Beacon',1,1),(3,'Phone - Team Compass',1,1),(4,'Chat - Team Delta',1,2),(5,'Email - Team Echo',1,3),
 (6,'Phone - Team Falcon',2,1),(7,'Phone - Team Granite',2,1),(8,'Chat - Team Harbor',2,2),(9,'Email - Team Iris',2,3),
 (10,'Phone - Team Juniper (Partner)',3,1),(11,'Phone - Team Keystone (Partner)',3,1),(12,'Chat - Team Lumen (Partner)',3,2);

CREATE TABLE gen.team_slot AS
SELECT team_id, site_id, primary_channel_id AS grp,
       row_number() OVER (PARTITION BY site_id, primary_channel_id ORDER BY team_id) - 1 AS idx,
       count(*) OVER (PARTITION BY site_id, primary_channel_id) AS n
FROM cc.dim_team;

-- ---------- Hidden agent traits + shift pattern ----------
CREATE TABLE gen.agent_trait AS
SELECT agent_id, random_normal(0, 1) AS skill_z, random() < 0.08 AS offender,
       random() AS r_pat, random() AS r_start, random() AS r_chat, random() AS r_cert, random() AS r_role
FROM gen.roster;

CREATE TABLE gen.agent_shift AS
SELECT r.agent_id,
  CASE WHEN r.emp_type = 'Part-time' THEN CASE WHEN t.r_pat < .5 THEN 'Mon-Thu (PT)' ELSE 'Wed-Sat (PT)' END
       ELSE (ARRAY['Mon-Fri','Mon-Thu + Sat','Mon-Wed + Fri-Sat','Mon-Tue + Thu-Sat'])[gen.pick(ARRAY[50,22,16,12]::numeric[], t.r_pat)] END AS pattern,
  CASE WHEN r.emp_type = 'Part-time' THEN (ARRAY[time '09:00', time '11:00', time '15:00'])[1 + floor(t.r_start * 3)::int]
       ELSE (ARRAY[time '07:00',time '07:30',time '08:00',time '08:30',time '09:00',time '10:00',time '11:00',time '12:30'])
            [gen.pick(ARRAY[14,10,18,14,14,10,8,12]::numeric[], t.r_start)] END AS start_time,
  CASE WHEN r.emp_type = 'Part-time' THEN 360 ELSE 510 END AS shift_min,
  CASE WHEN r.grp = 2 THEN CASE WHEN t.r_chat < .6 THEN 3 ELSE 2 END END AS lanes_max
FROM gen.roster r JOIN gen.agent_trait t USING (agent_id);

ALTER TABLE gen.agent_shift ADD COLUMN dows int[];
UPDATE gen.agent_shift SET dows = CASE pattern
  WHEN 'Mon-Fri' THEN ARRAY[1,2,3,4,5] WHEN 'Mon-Thu + Sat' THEN ARRAY[1,2,3,4,6]
  WHEN 'Mon-Wed + Fri-Sat' THEN ARRAY[1,2,3,5,6] WHEN 'Mon-Tue + Thu-Sat' THEN ARRAY[1,2,4,5,6]
  WHEN 'Mon-Thu (PT)' THEN ARRAY[1,2,3,4] ELSE ARRAY[3,4,5,6] END;

-- ---------- Fictional names ----------
CREATE TABLE gen.name_pool AS
SELECT row_number() OVER (ORDER BY random()) AS rn, f AS first_name, l AS last_name
FROM unnest(ARRAY['Aaliyah','Aaron','Abigail','Adrian','Aisha','Alejandro','Alexis','Amara','Amir','Ana','Andre','Angela','Anika','Antonio',
 'Ariana','Arjun','Ashley','Benjamin','Bianca','Brandon','Brianna','Caleb','Camila','Carlos','Carmen','Cedric','Chloe','Christopher','Daniel',
 'Daniela','Darius','David','Deja','Derek','Destiny','Diego','Dominic','Elena','Elijah','Emily','Emmanuel','Erica','Ethan','Fatima','Felix',
 'Gabriel','Gabriela','Grace','Hannah','Hector','Hiroshi','Imani','Isaac','Isabella','Jacob','Jada','Jamal','Jasmine','Javier','Jennifer',
 'Jessica','Joel','Jordan','Jose','Joseph','Joshua','Julia','Justin','Kai','Karen','Keisha','Kevin','Kiara','Kimberly','Laila','Lauren','Leah',
 'Leon','Liam','Lucia','Luis','Maya','Malik','Marcus','Maria','Mariana','Mark','Matthew','Megan','Mei','Michael','Michelle','Miguel','Mohammed',
 'Monica','Nadia','Naomi','Nathan','Nicole','Noah','Olivia','Omar','Priya','Rachel','Rafael','Raj','Rebecca','Ricardo','Rosa','Ryan','Samantha',
 'Samuel','Sara','Sean','Sofia','Stephanie','Steven','Tamara','Tanya','Terrence','Thomas','Tiffany','Tyler','Valeria','Vanessa','Victor',
 'Vivian','Wei','William','Xavier','Yasmin','Yusuf','Zachary','Zoe','Hana','Kwame','Lina','Mateo','Nia','Oscar']) f
CROSS JOIN unnest(ARRAY['Adams','Ahmed','Alvarez','Anderson','Bailey','Baker','Banks','Bennett','Brooks','Brown','Bryant','Campbell','Carter',
 'Castillo','Chen','Clark','Coleman','Collins','Cooper','Cruz','Davis','Diaz','Dixon','Edwards','Ellis','Evans','Fisher','Flores','Foster','Garcia',
 'Gomez','Gonzalez','Graham','Green','Griffin','Gupta','Hall','Harris','Hayes','Henderson','Hernandez','Hill','Holmes','Howard','Hughes','Jackson',
 'James','Jenkins','Johnson','Jones','Kaur','Kelly','Kennedy','Khan','Kim','King','Lee','Lewis','Lopez','Martin','Martinez','Mendoza','Miller',
 'Mitchell','Moore','Morales','Morgan','Murphy','Myers','Nelson','Nguyen','Ortiz','Owens','Park','Patel','Perez','Perry','Peterson','Phillips',
 'Powell','Price','Ramirez','Reed','Reyes','Richardson','Rivera','Roberts','Robinson','Rodriguez','Rogers','Ross','Russell','Sanchez','Sanders',
 'Scott','Shah','Simmons','Singh','Smith','Stewart','Sullivan','Tan','Taylor','Thomas','Thompson','Torres','Tran','Turner','Walker','Wallace',
 'Ward','Washington','Watson','White','Williams','Wilson','Wong','Wood','Wright','Yang','Young','Zhang','Okafor','Mensah','Nakamura','Novak',
 'Kowalski','Haddad','Silva','Santos','Rossi','Murray','Fischer','Olsen','Larsen','Becker','Dubois','Moreau']) l;

-- ---------- Agents ----------
INSERT INTO cc.dim_agent
SELECT r.agent_id, 'E' || (10000 + r.agent_id), n.first_name, n.last_name, n.first_name || ' ' || n.last_name,
       ts.team_id,
       CASE WHEN coalesce(r.term_date, date '2026-10-31') - r.hire_date > 3 * 365 AND t.r_role < .5 THEN 'Senior Agent' ELSE 'Agent' END,
       r.hire_date, r.term_date, r.hire_class_id, r.grp,
       CASE r.grp WHEN 1 THEN CASE WHEN t.r_cert < .3 THEN 'Phone, Callback, Chat' ELSE 'Phone, Callback' END
                  WHEN 2 THEN 'Chat, Email' ELSE 'Email, Secure Message' END,
       r.emp_type, sh.pattern, sh.start_time, sh.lanes_max
FROM gen.roster r
JOIN gen.agent_trait t USING (agent_id)
JOIN gen.agent_shift sh USING (agent_id)
JOIN gen.name_pool n ON n.rn = r.agent_id
JOIN gen.team_slot ts ON ts.site_id = r.site_id AND ts.grp = r.grp AND ts.idx = r.agent_id % ts.n;

-- Supervisors (one per team; do not take contacts)
INSERT INTO cc.dim_agent
SELECT m.mx + t.team_id, 'E' || (10000 + m.mx + t.team_id), n.first_name, n.last_name, n.first_name || ' ' || n.last_name,
       t.team_id, 'Supervisor', date '2015-01-05' + (t.team_id * 97), NULL, NULL, t.primary_channel_id,
       'Phone, Callback, Chat, Email, Secure Message', 'Full-time', 'Mon-Fri', time '08:00', NULL
FROM cc.dim_team t CROSS JOIN (SELECT max(agent_id) AS mx FROM gen.roster) m
JOIN gen.name_pool n ON n.rn = m.mx + t.team_id;

UPDATE cc.dim_team t SET supervisor_id = a.agent_id FROM cc.dim_agent a WHERE a.team_id = t.team_id AND a.role = 'Supervisor';

-- ---------- Agent working days ----------
CREATE TABLE gen.agent_day AS
WITH tr AS (
  SELECT r.agent_id,
         (SELECT d.full_date FROM cc.dim_date d WHERE d.full_date >= r.hire_date AND d.day_of_week <= 5 AND NOT d.is_center_closed
          ORDER BY d.full_date OFFSET 14 LIMIT 1) AS training_end
  FROM gen.roster r WHERE r.hire_date >= date '2024-01-01'
), base AS (
  SELECT r.agent_id, d.date_key, d.full_date AS work_date, d.day_of_week AS dow, r.grp, r.site_id, r.hire_date, r.emp_type,
         sh.start_time, sh.shift_min, sh.lanes_max, t.offender, t.skill_z,
         (tr.training_end IS NOT NULL AND d.full_date < tr.training_end) AS nh_training,
         EXISTS (SELECT 1 FROM cc.dim_date h WHERE h.is_holiday AND h.is_center_closed
                 AND h.full_date BETWEEN d.full_date - 3 AND d.full_date - 1) AS post_holiday,
         d.full_date BETWEEN date '2025-06-01' AND date '2025-08-31' AS crunch,
         EXISTS (SELECT 1 FROM gen.launch_param l WHERE l.impact IN ('Medium','High','Very High')
                 AND d.full_date BETWEEN l.launch_date - 7 AND l.launch_date - 1) AS launch_week,
         extract(doy FROM d.full_date)::int AS doy, extract(week FROM d.full_date)::int AS wk, d.month_num
  FROM gen.roster r
  JOIN gen.agent_shift sh USING (agent_id)
  JOIN gen.agent_trait t USING (agent_id)
  JOIN cc.dim_date d ON d.full_date BETWEEN greatest(r.hire_date, date '2024-01-01') AND coalesce(r.term_date - 1, date '2026-10-31')
  LEFT JOIN tr USING (agent_id)
  WHERE NOT d.is_center_closed
    AND ((tr.training_end IS NOT NULL AND d.full_date < tr.training_end AND d.day_of_week <= 5)
      OR ((tr.training_end IS NULL OR d.full_date >= tr.training_end) AND d.day_of_week = ANY (sh.dows)))
)
SELECT b.*, random() AS r_pto, random() AS r_abs, random() AS r_aux, random() AS r_auxpos, random() AS r_auxdur
FROM base b;

ALTER TABLE gen.agent_day
  ADD COLUMN tenure_days int, ADD COLUMN is_pto boolean, ADD COLUMN is_absent boolean, ADD COLUMN tpl text,
  ADD COLUMN start_ts timestamptz, ADD COLUMN p_late numeric, ADD COLUMN late_mean numeric, ADD COLUMN ext_mean numeric,
  ADD COLUMN p_early numeric, ADD COLUMN aux_day boolean, ADD COLUMN aux_sec numeric;

UPDATE gen.agent_day SET
  tenure_days = work_date - hire_date,
  is_pto = NOT nh_training AND r_pto < (CASE WHEN emp_type = 'Part-time' THEN .045 ELSE .055 END)
                                     * (CASE WHEN month_num IN (6,7,8,12) THEN 1.5 ELSE 0.85 END);
UPDATE gen.agent_day SET
  is_absent = NOT is_pto AND NOT nh_training AND r_abs < 0.03 * (CASE WHEN dow = 1 THEN 1.4 ELSE 1 END)
              * (CASE WHEN crunch THEN 1.6 ELSE 1 END) * (CASE WHEN offender THEN 1.5 ELSE 1 END)
              * (CASE WHEN post_holiday THEN 1.5 ELSE 1 END),
  tpl = CASE WHEN nh_training THEN 'NH_training'
             WHEN is_pto THEN (CASE WHEN emp_type = 'Part-time' THEN 'PT' ELSE 'FT' END) || '_pto'
             ELSE (CASE WHEN emp_type = 'Part-time' THEN 'PT' ELSE 'FT' END) || '_' ||
                  CASE WHEN launch_week AND (agent_id + doy) % 4 = 0 THEN 'launch'
                       WHEN dow = 3 AND wk % 2 = 0 THEN 'meeting'
                       WHEN dow = 1 + agent_id % 5 THEN 'coaching'
                       ELSE 'normal' END END,
  start_ts = (work_date + CASE WHEN nh_training THEN time '08:00'
                               WHEN dow = 6 THEN CASE WHEN emp_type = 'Part-time' OR agent_id % 2 = 0 THEN time '08:00' ELSE time '08:30' END
                               ELSE start_time END)::timestamptz,
  p_late = least(.8, (CASE WHEN offender THEN .35 ELSE .08 END) * (CASE WHEN dow = 1 OR post_holiday THEN 1.5 ELSE 1 END)
                 * (CASE WHEN site_id = 3 THEN 1.4 ELSE 1 END) * (CASE WHEN tenure_days < 90 THEN 1.5 ELSE 1 END)
                 * (CASE WHEN crunch THEN 1.5 ELSE 1 END)),
  late_mean = CASE WHEN offender THEN 480 ELSE 240 END,
  ext_mean = (CASE WHEN offender THEN 300 ELSE 70 END) * (CASE WHEN site_id = 3 THEN 1.3 ELSE 1 END)
             * (CASE WHEN crunch THEN 1.6 ELSE 1 END) * (CASE WHEN tenure_days < 90 THEN 1.4 ELSE 1 END),
  p_early = (CASE WHEN offender THEN .15 ELSE .04 END) * (CASE WHEN crunch THEN 1.5 ELSE 1 END),
  aux_day = r_aux < (CASE WHEN offender THEN .5 ELSE .25 END) * (CASE WHEN crunch THEN 1.3 ELSE 1 END),
  aux_sec = 300 + r_auxdur * 900;

-- ---------- Planned schedule ----------
CREATE TABLE gen.sched_template (tpl text, ord int, activity text, s_off int, e_off int);
INSERT INTO gen.sched_template VALUES
 ('FT_normal',1,'Open Shift',0,120),('FT_normal',2,'Break',120,135),('FT_normal',3,'Open Shift',135,240),('FT_normal',4,'Lunch',240,270),
 ('FT_normal',5,'Open Shift',270,390),('FT_normal',6,'Break',390,405),('FT_normal',7,'Open Shift',405,510),
 ('FT_coaching',1,'Open Shift',0,120),('FT_coaching',2,'Break',120,135),('FT_coaching',3,'Open Shift',135,240),('FT_coaching',4,'Lunch',240,270),
 ('FT_coaching',5,'Open Shift',270,300),('FT_coaching',6,'Coaching',300,330),('FT_coaching',7,'Open Shift',330,390),('FT_coaching',8,'Break',390,405),
 ('FT_coaching',9,'Open Shift',405,510),
 ('FT_meeting',1,'Open Shift',0,60),('FT_meeting',2,'Meeting',60,90),('FT_meeting',3,'Open Shift',90,120),('FT_meeting',4,'Break',120,135),
 ('FT_meeting',5,'Open Shift',135,240),('FT_meeting',6,'Lunch',240,270),('FT_meeting',7,'Open Shift',270,390),('FT_meeting',8,'Break',390,405),
 ('FT_meeting',9,'Open Shift',405,510),
 ('FT_launch',1,'Open Shift',0,60),('FT_launch',2,'Training',60,120),('FT_launch',3,'Break',120,135),('FT_launch',4,'Open Shift',135,240),
 ('FT_launch',5,'Lunch',240,270),('FT_launch',6,'Open Shift',270,390),('FT_launch',7,'Break',390,405),('FT_launch',8,'Open Shift',405,510),
 ('PT_normal',1,'Open Shift',0,120),('PT_normal',2,'Break',120,135),('PT_normal',3,'Open Shift',135,360),
 ('PT_coaching',1,'Open Shift',0,120),('PT_coaching',2,'Break',120,135),('PT_coaching',3,'Open Shift',135,200),('PT_coaching',4,'Coaching',200,230),
 ('PT_coaching',5,'Open Shift',230,360),
 ('PT_meeting',1,'Open Shift',0,60),('PT_meeting',2,'Meeting',60,90),('PT_meeting',3,'Open Shift',90,120),('PT_meeting',4,'Break',120,135),
 ('PT_meeting',5,'Open Shift',135,360),
 ('PT_launch',1,'Open Shift',0,60),('PT_launch',2,'Training',60,120),('PT_launch',3,'Break',120,135),('PT_launch',4,'Open Shift',135,360),
 ('NH_training',1,'Training',0,240),('NH_training',2,'Lunch',240,270),('NH_training',3,'Training',270,510),
 ('FT_pto',1,'PTO',0,510),('PT_pto',1,'PTO',0,360);

INSERT INTO cc.agent_schedule
SELECT row_number() OVER (ORDER BY ad.agent_id, ad.date_key, t.ord), ad.agent_id, ad.date_key, t.activity,
       ad.start_ts + t.s_off * interval '1 min', ad.start_ts + t.e_off * interval '1 min', t.e_off - t.s_off,
       t.activity = 'Open Shift'
FROM gen.agent_day ad JOIN gen.sched_template t ON t.tpl = ad.tpl;

-- ---------- Actual activity (what really happened) ----------
CREATE TABLE gen.act_b AS
SELECT s.agent_id, s.date_key, s.activity, s.scheduled_start_ts AS ss, s.scheduled_end_ts AS se,
       row_number() OVER w AS k, count(*) OVER (PARTITION BY s.agent_id, s.date_key) AS n,
       lead(s.activity) OVER w AS next_act,
       ad.p_late, ad.late_mean, ad.ext_mean, ad.p_early, ad.offender,
       random() AS r1, random() AS r2, random() AS r3, random() AS r4
FROM cc.agent_schedule s JOIN gen.agent_day ad USING (agent_id, date_key)
WHERE s.activity <> 'PTO' AND NOT ad.is_absent
WINDOW w AS (PARTITION BY s.agent_id, s.date_key ORDER BY s.scheduled_start_ts);

CREATE TABLE gen.act_c AS
SELECT b.*,
  b.se + (CASE
     WHEN k = n THEN CASE WHEN r1 < p_early THEN -(300 + r2 * 1200) ELSE r2 * 240 END
     WHEN activity IN ('Break','Lunch') THEN least(1200, -ln(1 - r1) * ext_mean) - 40
     WHEN next_act IN ('Break','Lunch') THEN (r1 - 0.5) * 150 - CASE WHEN offender THEN 60 ELSE 0 END
     WHEN activity IN ('Coaching','Meeting','Training') THEN least(900, -ln(1 - r1) * 90) - 20
     ELSE (r1 - 0.5) * 180 END) * interval '1 sec' AS raw_end,
  CASE WHEN k = 1 THEN b.ss + (CASE WHEN r3 < p_late THEN 30 + least(2400, -ln(1 - r4) * late_mean) ELSE -r4 * 150 END) * interval '1 sec' END AS login_ts
FROM gen.act_b b;

CREATE TABLE gen.act_d AS
SELECT c.agent_id, c.date_key, c.k, c.activity,
       coalesce(c.login_ts, lag(c.raw_end) OVER (PARTITION BY c.agent_id, c.date_key ORDER BY c.k)) AS a_start,
       c.raw_end AS a_end
FROM gen.act_c c;

ALTER TABLE gen.act_d ADD COLUMN aux_rank int;
UPDATE gen.act_d d SET aux_rank = x.rk
FROM (SELECT agent_id, date_key, k,
             row_number() OVER (PARTITION BY agent_id, date_key
                                ORDER BY (activity = 'Open Shift' AND a_end - a_start >= interval '50 min') DESC, random()) AS rk
      FROM gen.act_d) x
WHERE x.agent_id = d.agent_id AND x.date_key = d.date_key AND x.k = d.k;

INSERT INTO cc.agent_activity (activity_id, agent_id, date_key, state, state_start_ts, state_end_ts, duration_sec)
SELECT row_number() OVER (ORDER BY agent_id, st), agent_id, date_key, state, st, en, round(extract(epoch FROM en - st))::int
FROM (
  -- unsplit blocks
  SELECT d.agent_id, d.date_key, CASE d.activity WHEN 'Open Shift' THEN 'Available' ELSE d.activity END AS state, d.a_start AS st, d.a_end AS en
  FROM gen.act_d d JOIN gen.agent_day ad USING (agent_id, date_key)
  WHERE NOT (ad.aux_day AND d.aux_rank = 1 AND d.activity = 'Open Shift' AND d.a_end - d.a_start >= interval '50 min')
  UNION ALL
  -- blocks split by an unplanned 'Unavailable' (aux) period
  SELECT x.agent_id, x.date_key, v.state, v.st, v.en
  FROM (SELECT d.agent_id, d.date_key, d.a_start, d.a_end, ad.aux_sec,
               d.a_start + (0.2 + 0.5 * ad.r_auxpos) * (d.a_end - d.a_start - ad.aux_sec * interval '1 sec') AS m
        FROM gen.act_d d JOIN gen.agent_day ad USING (agent_id, date_key)
        WHERE ad.aux_day AND d.aux_rank = 1 AND d.activity = 'Open Shift' AND d.a_end - d.a_start >= interval '50 min') x
  CROSS JOIN LATERAL (VALUES
     ('Available', x.a_start, x.m),
     ('Unavailable', x.m, x.m + x.aux_sec * interval '1 sec'),
     ('Available', x.m + x.aux_sec * interval '1 sec', x.a_end)) v(state, st, en)
) u;

DROP TABLE gen.act_b, gen.act_c;
