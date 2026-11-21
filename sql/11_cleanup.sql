-- Remove generation scratch tables (keeps helper functions used by validation: gen.dk, gen.iv).
\set ON_ERROR_STOP on
SET client_min_messages = warning;
DO $$
DECLARE t record;
BEGIN
  FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'gen' LOOP
    EXECUTE format('DROP TABLE gen.%I CASCADE', t.tablename);
  END LOOP;
END $$;
VACUUM ANALYZE;
