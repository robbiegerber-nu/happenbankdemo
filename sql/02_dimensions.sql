-- Lookup tables + generation parameters
\set ON_ERROR_STOP on
SET client_min_messages = warning;

INSERT INTO cc.dataset_info VALUES
 ('dataset',      'Happen Bank contact center demo dataset'),
 ('nature',       '100% SYNTHETIC. Generated for dashboard demonstrations. Not real Happen Bank data; names of people are fictional.'),
 ('period',       '2024-01-01 to 2026-10-31'),
 ('timezone',     'America/Chicago'),
 ('generated_at', now()::text),
 ('generator',    'SQL scripts in HappenBankDemo/sql (seeded with setseed(0.42))');

-- ---------- Dates ----------
WITH hol(dt, name, closed) AS (VALUES
 ('2024-01-01'::date,'New Year''s Day',true),('2024-01-15','Martin Luther King Jr. Day',false),('2024-02-19','Presidents Day',false),
 ('2024-05-27','Memorial Day',true),('2024-06-19','Juneteenth',false),('2024-07-04','Independence Day',true),('2024-09-02','Labor Day',true),
 ('2024-10-14','Columbus / Indigenous Peoples Day',false),('2024-11-11','Veterans Day',false),('2024-11-28','Thanksgiving Day',true),('2024-12-25','Christmas Day',true),
 ('2025-01-01','New Year''s Day',true),('2025-01-20','Martin Luther King Jr. Day',false),('2025-02-17','Presidents Day',false),
 ('2025-05-26','Memorial Day',true),('2025-06-19','Juneteenth',false),('2025-07-04','Independence Day',true),('2025-09-01','Labor Day',true),
 ('2025-10-13','Columbus / Indigenous Peoples Day',false),('2025-11-11','Veterans Day',false),('2025-11-27','Thanksgiving Day',true),('2025-12-25','Christmas Day',true),
 ('2026-01-01','New Year''s Day',true),('2026-01-19','Martin Luther King Jr. Day',false),('2026-02-16','Presidents Day',false),
 ('2026-05-25','Memorial Day',true),('2026-06-19','Juneteenth',false),('2026-07-03','Independence Day (observed)',true),('2026-07-04','Independence Day',true),
 ('2026-09-07','Labor Day',true),('2026-10-12','Columbus / Indigenous Peoples Day',false)
), days AS (
  SELECT d::date AS d FROM generate_series('2024-01-01'::date, '2026-10-31'::date, '1 day') d
), pay AS (  -- 1st and 15th, moved back to the previous weekday
  SELECT DISTINCT (c - CASE extract(isodow FROM c) WHEN 6 THEN 1 WHEN 7 THEN 2 ELSE 0 END)::date AS pd
  FROM (SELECT make_date(y, m, dd) c FROM generate_series(2024,2026) y, generate_series(1,12) m, unnest(ARRAY[1,15]) dd) x
)
INSERT INTO cc.dim_date
SELECT to_char(d,'YYYYMMDD')::int, d, trim(to_char(d,'Day')), extract(isodow FROM d), extract(isodow FROM d) IN (6,7),
       h.name IS NOT NULL, h.name, coalesce(h.closed,false) OR extract(isodow FROM d) = 7,
       date_trunc('week', d)::date, extract(month FROM d), trim(to_char(d,'Month')), extract(quarter FROM d), extract(year FROM d),
       to_char(d,'YYYY-MM'), 'FY' || extract(year FROM d) || '-P' || to_char(d,'MM'),
       extract(day FROM d) <= 3, d IN (SELECT pd FROM pay)
FROM days LEFT JOIN hol h ON h.dt = days.d;

-- ---------- 15-minute intervals ----------
INSERT INTO cc.dim_time_interval
SELECT i, (time '00:00' + i * interval '15 min'), (time '00:00' + (i+1) * interval '15 min'), i / 4,
       CASE WHEN i < 28 OR i >= 84 THEN 'After hours' WHEN i < 40 THEN 'Morning' WHEN i < 56 THEN 'Midday'
            WHEN i < 68 THEN 'Afternoon' ELSE 'Evening' END,
       to_char(time '00:00' + i * interval '15 min', 'HH24:MI')
FROM generate_series(0, 95) i;

-- ---------- Channels, sites, queues ----------
INSERT INTO cc.dim_channel VALUES
 (1,'Phone',true, 80,30,   '80% answered in 30 seconds'),
 (2,'Chat', true, 85,60,   '85% answered in 60 seconds'),
 (3,'Email',false,90,86400,'90% responded to within 24 hours'),
 (4,'Callback',false,80,7200,'80% called back within 2 hours of request'),
 (5,'Secure Message',false,90,86400,'90% responded to within 24 hours');

INSERT INTO cc.dim_site VALUES
 (1,'Central Campus','Kansas City','MO',false,'America/Chicago'),
 (2,'Lakeside Center','Madison','WI',false,'America/Chicago'),
 (3,'Partner Site (Outsourced)','San Antonio','TX',true,'America/Chicago');

INSERT INTO cc.dim_queue VALUES
 (1,'Phone - General Servicing',1,'General Servicing',3,80,30),
 (2,'Phone - Fraud & Disputes',1,'Fraud & Disputes',1,80,20),
 (3,'Phone - Digital Support',1,'Digital Support',3,80,30),
 (4,'Phone - Lending & Mortgage',1,'Lending',3,80,30),
 (5,'Phone - Business Banking',1,'Business Banking',2,80,30),
 (6,'Phone - Sales & New Accounts',1,'Sales',2,80,30),
 (7,'Callback - Scheduled Callbacks',4,'General Servicing',4,80,7200),
 (8,'Chat - General Servicing',2,'General Servicing',3,85,60),
 (9,'Chat - Digital Support',2,'Digital Support',3,85,60),
 (10,'Chat - Sales',2,'Sales',2,85,60),
 (11,'Email - Servicing',3,'General Servicing',3,90,86400),
 (12,'Email - Disputes & Complaints',3,'Fraud & Disputes',2,90,86400),
 (13,'Email - Business Banking',3,'Business Banking',3,90,86400),
 (14,'Secure Message - Servicing',5,'General Servicing',3,90,86400);

-- ---------- Regions ----------
CREATE TABLE gen.region_param (region_id smallint, w numeric);
WITH r(id, st, stn, metro, area, w) AS (VALUES
 (1,'MO','Missouri','Kansas City','Urban',6),(2,'MO','Missouri','Kansas City','Suburban',5),(3,'MO','Missouri','St. Louis','Urban',5),
 (4,'MO','Missouri','St. Louis','Suburban',5),(5,'MO','Missouri','Springfield','Suburban',2),(6,'MO','Missouri','Rural Missouri','Rural',3),
 (7,'KS','Kansas','Wichita','Urban',3),(8,'KS','Kansas','Johnson County','Suburban',4),(9,'KS','Kansas','Rural Kansas','Rural',2),
 (10,'KS','Kansas','Topeka','Suburban',1.5),(11,'NE','Nebraska','Omaha','Urban',3),(12,'NE','Nebraska','Lincoln','Suburban',2),
 (13,'NE','Nebraska','Rural Nebraska','Rural',1.5),(14,'IA','Iowa','Des Moines','Urban',3),(15,'IA','Iowa','Des Moines','Suburban',2),
 (16,'IA','Iowa','Cedar Rapids','Suburban',1.5),(17,'IA','Iowa','Rural Iowa','Rural',2),(18,'WI','Wisconsin','Madison','Urban',3),
 (19,'WI','Wisconsin','Milwaukee','Urban',4),(20,'WI','Wisconsin','Milwaukee','Suburban',3),(21,'WI','Wisconsin','Rural Wisconsin','Rural',2),
 (22,'MN','Minnesota','Minneapolis-St. Paul','Urban',4),(23,'MN','Minnesota','Minneapolis-St. Paul','Suburban',4),(24,'MN','Minnesota','Rural Minnesota','Rural',1.5),
 (25,'IL','Illinois','Chicago','Urban',5),(26,'IL','Illinois','Chicago','Suburban',5),(27,'IL','Illinois','Springfield','Suburban',1),
 (28,'IL','Illinois','Rural Illinois','Rural',1.5),(29,'OK','Oklahoma','Oklahoma City','Urban',2.5),(30,'OK','Oklahoma','Tulsa','Urban',2),
 (31,'OK','Oklahoma','Rural Oklahoma','Rural',1.5),(32,'TX','Texas','Dallas-Fort Worth','Urban',4),(33,'TX','Texas','Dallas-Fort Worth','Suburban',4),
 (34,'TX','Texas','San Antonio','Urban',3),(35,'TX','Texas','Austin','Urban',3),(36,'TX','Texas','Rural Texas','Rural',2),
 (37,'AR','Arkansas','Little Rock','Suburban',1.5),(38,'AR','Arkansas','Rural Arkansas','Rural',1.5),(39,'CO','Colorado','Denver','Urban',2.5),
 (40,'CO','Colorado','Denver','Suburban',2.5)
), ins AS (INSERT INTO cc.dim_region SELECT id, st, stn, metro, area FROM r RETURNING region_id)
INSERT INTO gen.region_param SELECT id, w FROM r;

-- ---------- Personas ----------
INSERT INTO cc.dim_persona VALUES
 (1,'Digital Native Starter','Early-career and mobile-first. Prefers chat and self-service; little patience for app problems.','Chat',5,'High','18-29'),
 (2,'Busy Young Family','Two incomes and kids, juggling payments and transfers. Values speed and convenience.','Chat',4,'High','30-44'),
 (3,'Small Business Owner','Runs a small business: wires, business accounts, complex needs. Time-poor.','Email',3,'Medium','35-59'),
 (4,'Established Professional','Mid-career, stable income, several products. Uses the app but calls for complex issues.','Phone',4,'Low','35-54'),
 (5,'Pre-Retiree Planner','Focused on savings, CDs and retirement. Detail-oriented.','Phone',3,'Medium','55-64'),
 (6,'Retiree Traditionalist','Prefers the phone and personal service; longer conversations; highly loyal.','Phone',1,'Medium','65+'),
 (7,'Credit Builder','Thin or rebuilding credit. Fee-sensitive; frequent dispute and fee contacts.','Phone',3,'High','18-39'),
 (8,'Affluent Investor','High balances and wealth needs. Expects fast, expert service.','Phone',3,'Low','45-74');

CREATE TABLE gen.persona_param AS
SELECT * FROM (VALUES
 (1,.15,.45,2.6,.7, .9,.85,-.10,.75,.97,18,29,1.0,ARRAY[30,35,25,8,2,0]::numeric[],1,2, 8),
 (2,.16,.85,1.7,.8,1.0,.95, .00,1.0,.93,28,46,1.0,ARRAY[8,25,40,20,6,1]::numeric[],3,6,15),
 (3,.08,1.15,.6,2.2,1.4,1.25,-.05,1.0,.85,28,68,1.0,ARRAY[5,15,30,25,17,8]::numeric[],1,5,20),
 (4,.18,1.0,.9,1.0,1.0,1.0, .00,1.0,.90,33,56,1.0,ARRAY[2,10,33,32,18,5]::numeric[],2,4,22),
 (5,.12,1.15,.5,1.1,1.0,1.12,.10,1.2,.75,53,64,1.0,ARRAY[8,20,32,22,13,5]::numeric[],1,3,30),
 (6,.12,1.7,.15,.6,1.2,1.30,.25,1.4,.42,65,90,1.6,ARRAY[22,33,27,12,5,1]::numeric[],1,2,45),
 (7,.11,1.1,1.2,.7,1.3,1.05,-.20,.9,.82,18,42,1.4,ARRAY[45,38,14,3,0,0]::numeric[],1,4, 6),
 (8,.08,1.1,.5,1.4, .9,1.10,-.05,1.1,.85,40,78,1.0,ARRAY[0,2,8,20,40,30]::numeric[],2,4,30)
) v(persona_id, share, aff_phone, aff_chat, aff_email, contact_rate, talk_mult, csat_adj, survey_mult, digital_prob,
    age_lo, age_hi, age_skew, income_w, hh_lo, hh_hi, tenure_max_years);

-- ---------- Contact reasons ----------
INSERT INTO cc.dim_contact_reason (reason_id, reason, reason_group) VALUES
 (1,'Balance & Transaction Inquiry','Account Servicing'),(2,'Address & Profile Update','Account Servicing'),
 (3,'Statement & Tax Document Request','Account Servicing'),(4,'Deposit Hold Question','Account Servicing'),
 (5,'Wire Transfer Request','Account Servicing'),(6,'Account Closure','Account Servicing'),
 (7,'Overdraft & Fee Question','Account Servicing'),(8,'Direct Deposit Setup','Account Servicing'),(9,'Stop Payment','Account Servicing'),
 (10,'Card Activation','Card'),(11,'Lost or Stolen Card','Card'),(12,'Card Declined','Card'),(13,'Credit Limit Request','Card'),
 (14,'Card Replacement Status','Card'),(15,'Rewards Question','Card'),
 (16,'Fraud Alert Verification','Fraud/Dispute'),(17,'Unauthorized Transaction','Fraud/Dispute'),(18,'Dispute a Charge','Fraud/Dispute'),
 (19,'Scam or P2P Payment Issue','Fraud/Dispute'),(20,'Identity Theft','Fraud/Dispute'),
 (21,'Password Reset / Locked Out','Digital Access'),(22,'Verification Code (2FA) Issue','Digital Access'),(23,'Mobile App Error','Digital Access'),
 (24,'Online Banking Navigation','Digital Access'),(25,'Mobile Deposit Issue','Digital Access'),(26,'P2P Payments Help','Digital Access'),
 (27,'Paperless & eStatement Setup','Digital Access'),
 (28,'Loan Payment Question','Lending'),(29,'Mortgage Escrow & Payment','Lending'),(30,'Loan Application Status','Lending'),(31,'Payoff Request','Lending'),
 (32,'New Account Inquiry','Product Inquiry'),(33,'Savings & CD Rate Inquiry','Product Inquiry'),(34,'Credit Card Product Inquiry','Product Inquiry'),
 (35,'Business Banking Inquiry','Product Inquiry'),
 (36,'Fee Complaint','Complaint'),(37,'Service Complaint','Complaint'),(38,'Digital Experience Complaint','Complaint');

-- base contact weights by channel + base talk seconds
CREATE TABLE gen.reason_param AS
SELECT * FROM (VALUES
 (1,9,8,3,240),(2,3,3,4,260),(3,3,2,5,230),(4,3,2,2,300),(5,2.5,.6,3,420),(6,1.2,.5,1.5,420),(7,4,3.5,2.5,330),(8,1.5,1.5,1.5,280),(9,1,.5,1,300),
 (10,4,1.5,.3,180),(11,3.5,1.2,.4,300),(12,4,2.5,.6,320),(13,1.5,1,1,330),(14,2,1.5,1,220),(15,1.5,1.5,1.2,280),
 (16,4,.8,.3,260),(17,3,1,1.5,560),(18,3,2,3,520),(19,1,.6,.6,640),(20,.5,.2,.4,780),
 (21,5,4,1,300),(22,2,2,.5,330),(23,2.5,3.5,1.2,380),(24,2,3,1,340),(25,1.5,1.5,.8,320),(26,.5,.6,.3,300),(27,.8,1,1,220),
 (28,3,1.5,2,320),(29,2,.6,2,480),(30,1.5,1,1.5,360),(31,1,.5,2,300),
 (32,2,3,1,420),(33,1.5,1.5,.8,360),(34,1.2,1.5,.5,380),(35,.8,.4,1.5,480),
 (36,1,.8,1.2,480),(37,.8,.5,1.5,560),(38,.6,.8,.8,460)
) v(reason_id, w_phone, w_chat, w_email, talk_base);

CREATE TABLE gen.group_param AS
SELECT * FROM (VALUES
 ('Account Servicing',.06,.05, .05, .10,1.0),
 ('Card',             .05,.00, .04, .05,0.9),
 ('Fraud/Dispute',    .10,.20,-.06,-.15,1.6),
 ('Digital Access',   .08,.05,-.03,-.10,1.0),
 ('Lending',          .14,.15,-.05, .00,1.3),
 ('Product Inquiry',  .12,.05, .03, .20,1.2),
 ('Complaint',        .12,.10,-.20,-.55,1.8)
) v(reason_group, transfer_p, hold_adj, fcr_adj, sent_adj, wrap_mult);

CREATE TABLE gen.persona_group_aff AS
SELECT p.persona_id, g.reason_group, coalesce(a.m, 1.0) AS m
FROM gen.persona_param p CROSS JOIN gen.group_param g
LEFT JOIN (VALUES
 (1,'Digital Access',1.4),(1,'Card',1.1),(1,'Lending',.6),(1,'Product Inquiry',1.1),(1,'Account Servicing',.9),(1,'Complaint',.9),
 (2,'Digital Access',1.1),(2,'Card',1.1),(2,'Lending',1.1),
 (3,'Account Servicing',1.2),(3,'Product Inquiry',1.4),(3,'Lending',1.1),(3,'Digital Access',.9),
 (4,'Lending',1.3),(4,'Product Inquiry',1.1),
 (5,'Product Inquiry',1.3),(5,'Account Servicing',1.1),(5,'Digital Access',.8),
 (6,'Account Servicing',1.3),(6,'Fraud/Dispute',1.3),(6,'Lending',.6),(6,'Product Inquiry',.8),
 (7,'Fraud/Dispute',1.5),(7,'Account Servicing',1.2),(7,'Complaint',1.6),(7,'Card',1.2),(7,'Product Inquiry',.7),(7,'Lending',.8),
 (8,'Product Inquiry',1.3),(8,'Account Servicing',1.1),(8,'Fraud/Dispute',.9),(8,'Complaint',.8)
) a(persona_id, reason_group, m) ON a.persona_id = p.persona_id AND a.reason_group = g.reason_group;

-- ---------- Products & launches ----------
INSERT INTO cc.dim_product (product_id, product_name, category, is_new_in_period, introduced_date) VALUES
 (1,'Everyday Checking','Deposit',false,'2005-01-01'),(2,'Premier Checking','Deposit',false,'2012-01-01'),
 (3,'Basic Savings','Deposit',false,'2005-01-01'),(4,'High-Yield Savings','Deposit',true,'2025-01-13'),
 (5,'Money Market','Deposit',false,'2008-01-01'),(6,'12-Month CD','Deposit',false,'2005-01-01'),
 (7,'CD Ladder Bundle','Deposit',true,'2026-06-01'),(8,'Youth Savings','Deposit',false,'2010-01-01'),
 (9,'Debit Card','Card',false,'2005-01-01'),(10,'Cash Back Credit Card','Card',false,'2014-01-01'),
 (11,'Rewards Plus Credit Card','Card',true,'2024-04-15'),(12,'Secured Credit Card','Card',false,'2016-01-01'),
 (13,'Business Rewards Credit Card','Business',true,'2026-08-17'),(14,'Personal Loan','Lending',false,'2005-01-01'),
 (15,'Auto Loan','Lending',false,'2005-01-01'),(16,'Home Equity Line of Credit','Lending',false,'2006-01-01'),
 (17,'30-Year Fixed Mortgage','Mortgage',false,'2005-01-01'),(18,'Adjustable-Rate Mortgage','Mortgage',false,'2005-01-01'),
 (19,'Online Banking','Digital',false,'2006-01-01'),(20,'Mobile Banking App','Digital',false,'2013-01-01'),
 (21,'Mobile Check Deposit','Digital',false,'2015-01-01'),(22,'P2P Payments','Digital',true,'2025-05-05'),
 (23,'Paperless Statements','Digital',false,'2012-01-01'),(24,'Business Checking','Business',false,'2005-01-01'),
 (25,'Business Savings','Business',false,'2005-01-01'),(26,'Business Digital Onboarding','Business',true,'2025-06-16'),
 (27,'Merchant Services','Business',false,'2011-01-01'),(28,'Overdraft Protection','Deposit',false,'2005-01-01');

CREATE TABLE gen.launch_param AS
SELECT * FROM (VALUES
 (1,'Online Banking 2FA Enforcement','2024-03-04'::date,19,'Migration',ARRAY[6,5,8],6,.05,-.10,'Low','High','Two-factor authentication becomes mandatory for online banking sign-in.'),
 (2,'Rewards Plus Credit Card','2024-04-15',11,'New Product',ARRAY[4,2,1],10,.30,.10,'High','Medium','New rewards credit card with a sign-up bonus.'),
 (3,'Mobile Deposit Limit Increase','2024-06-03',21,'Feature',ARRAY[1,2,3],5,.05,.00,'Low','Low','Higher daily limits for mobile check deposit.'),
 (4,'Debit Card Reissue (Contactless Upgrade)','2024-08-19',9,'Migration',ARRAY[]::int[],12,.05,-.05,'Medium','High','All debit cards reissued with contactless chips.'),
 (5,'Budgeting Insights (In-App)','2024-10-07',20,'Feature',ARRAY[1,2],6,.05,.05,'Low','Low','Spending insights and budgets added to the mobile app.'),
 (6,'High-Yield Savings Account','2025-01-13',4,'New Product',ARRAY[8,5,4],10,.30,.20,'High','Medium','New high-yield savings account with a promotional rate.'),
 (7,'Fee Schedule Change','2025-03-10',28,'Pricing Change',ARRAY[7,2,1],7,.15,-.35,'None','High','Overdraft and monthly maintenance fees revised.'),
 (8,'P2P Payments (Send & Request)','2025-05-05',22,'New Product',ARRAY[1,2],9,.35,.00,'Medium','Medium','Person-to-person payments in the app.'),
 (9,'Small Business Digital Onboarding','2025-06-16',26,'Feature',ARRAY[3],8,.15,-.05,'Medium','Medium','Small businesses can open accounts fully online.'),
 (10,'Premier Checking Relaunch','2025-09-08',2,'New Product',ARRAY[8,4],9,.20,.10,'High','Low','Premier Checking relaunched with new relationship benefits.'),
 (11,'Card Controls & Travel Notices','2025-11-03',20,'Feature',ARRAY[4,8,1],6,.05,.05,'Low','Low','Lock/unlock cards and set travel notices in the app.'),
 (12,'Mobile App Re-platform','2026-02-09',20,'Migration',ARRAY[1,2,6],12,.05,-.20,'Medium','Very High','Mobile app rebuilt on a new platform; all users must re-register.'),
 (13,'Digital HELOC Application','2026-04-20',16,'Feature',ARRAY[4,5],10,.20,.05,'Medium','Low','Home equity line applications fully online.'),
 (14,'CD Ladder Promotion','2026-06-01',7,'Pricing Change',ARRAY[6,5,8],7,.10,.10,'Medium','Low','Promotional rates on a bundled CD ladder.'),
 (15,'Business Rewards Credit Card','2026-08-17',13,'New Product',ARRAY[3],9,.25,.05,'Medium','Low','Rewards credit card for small businesses.'),
 (16,'AI Chat Assistant (In-App)','2026-09-28',20,'Feature',ARRAY[1,2],6,.05,.00,'Low','Low','Virtual assistant answers common questions inside the app.')
) v(launch_id, launch_name, launch_date, product_id, launch_type, targets, tp, persist, sent_adj, spend, impact, description);

INSERT INTO cc.product_launch
SELECT l.launch_id, l.launch_name, l.launch_date, l.product_id, l.launch_type,
       CASE WHEN cardinality(l.targets) = 0 THEN 'All customers'
            ELSE (SELECT string_agg(p.persona_name, ', ' ORDER BY p.persona_id) FROM cc.dim_persona p WHERE p.persona_id = ANY(l.targets)) END,
       l.impact, l.spend, l.description
FROM gen.launch_param l;

INSERT INTO cc.launch_reason_impact VALUES
 (1,22,4.0),(1,21,1.2),(1,24,0.8),(1,38,0.8),
 (2,34,2.5),(2,15,2.0),(2,10,0.6),(2,13,0.6),
 (3,25,1.0),(3,4,0.4),
 (4,10,3.0),(4,14,2.5),(4,12,0.6),
 (5,23,0.4),(5,24,0.4),
 (6,33,3.0),(6,32,1.2),(6,5,0.3),
 (7,7,2.5),(7,36,3.5),(7,6,0.8),
 (8,26,3.0),(8,19,1.5),(8,17,0.3),
 (9,35,2.5),(9,24,0.5),(9,22,0.4),
 (10,32,1.0),(10,7,0.3),
 (11,12,0.5),(11,23,0.3),
 (12,23,4.5),(12,21,1.8),(12,22,1.0),(12,24,1.5),(12,38,2.5),(12,25,1.0),(12,26,0.8),
 (13,30,1.5),(13,32,0.3),
 (14,33,1.5),(14,32,0.4),
 (15,35,1.5),(15,34,0.5),
 (16,23,0.6),(16,24,0.4);

UPDATE cc.dim_contact_reason r SET is_launch_related_possible = true
WHERE EXISTS (SELECT 1 FROM cc.launch_reason_impact i WHERE i.reason_id = r.reason_id);

UPDATE cc.dim_product p SET launch_id = x.launch_id
FROM (SELECT DISTINCT ON (product_id) product_id, launch_id FROM gen.launch_param
      ORDER BY product_id, CASE impact WHEN 'Very High' THEN 0 WHEN 'High' THEN 1 WHEN 'Medium' THEN 2 ELSE 3 END, launch_id) x
WHERE p.product_id = x.product_id;

-- Queue routing: channel + reason group + persona -> queue
CREATE FUNCTION gen.pick_queue(ch int, grp text, persona int) RETURNS smallint
LANGUAGE sql IMMUTABLE AS $$
  SELECT (CASE ch
    WHEN 1 THEN CASE WHEN grp = 'Fraud/Dispute' THEN 2
                     WHEN persona = 3 THEN 5
                     WHEN grp = 'Digital Access' THEN 3
                     WHEN grp = 'Lending' THEN 4
                     WHEN grp = 'Product Inquiry' THEN 6
                     ELSE 1 END
    WHEN 4 THEN 7
    WHEN 2 THEN CASE WHEN grp = 'Digital Access' THEN 9 WHEN grp = 'Product Inquiry' THEN 10 ELSE 8 END
    WHEN 3 THEN CASE WHEN grp IN ('Fraud/Dispute','Complaint') THEN 12 WHEN persona = 3 THEN 13 ELSE 11 END
    ELSE 14 END)::smallint;
$$;
