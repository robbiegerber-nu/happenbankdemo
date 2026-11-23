-- Queues, channels and months for Service & Access Operations.
SELECT json_build_object(
  'data_through', (SELECT max(d.full_date) FROM cc.interval_volume v JOIN cc.dim_date d USING (date_key)),
  'generated_at', to_char(now() AT TIME ZONE 'America/Chicago', 'YYYY-MM-DD"T"HH24:MI:SS'),
  'months', (SELECT json_agg(m ORDER BY m) FROM (SELECT DISTINCT to_char(d.full_date, 'YYYY-MM') AS m FROM cc.dim_date d
             WHERE d.date_key IN (SELECT DISTINCT date_key FROM cc.interval_volume)) x),
  'channels', (SELECT json_agg(json_build_object('id', channel_id, 'name', channel_name, 'live', is_real_time) ORDER BY channel_id) FROM cc.dim_channel),
  'queues', (SELECT json_agg(json_build_object('id', queue_id, 'name', queue_name, 'channel', channel_id, 'sec', sl_threshold_sec) ORDER BY queue_id) FROM cc.dim_queue));
