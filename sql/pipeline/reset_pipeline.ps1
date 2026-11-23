# Resets the v3.1 daily-load demo to where it started (data to 31 Oct 2026, discovery runs 1-5).
# Removes November data, runs after #5, loads, incidents and their exported dashboard files.
# Does NOT touch GitHub Issues already raised (close those by hand if needed).
#   powershell -File sql\pipeline\reset_pipeline.ps1
$ErrorActionPreference = 'Stop'
$env:PGCLIENTENCODING = 'UTF8'
$psql = 'C:\Program Files\PostgreSQL\18\bin\psql.exe'
$db   = if ($env:HAPPEN_DB) { $env:HAPPEN_DB } else { 'happen_demo' }   # set HAPPEN_DB to work on a copy (rehearsals)
$conn = @('-w', '-h', 'localhost', '-U', 'postgres', '-d', $db)
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$keep = 5   # last run before daily loads

$sql = @"
BEGIN;
DELETE FROM cc.survey_response WHERE survey_id >= 10000000;
DELETE FROM cc.complaint       WHERE complaint_id >= 10000000;
DELETE FROM cc.ivr_session     WHERE session_id >= 10000000;
DELETE FROM cc.contact         WHERE contact_id >= 10000000;
DELETE FROM cc.agent_activity  WHERE activity_id >= 10000000;
DELETE FROM cc.agent_schedule  WHERE schedule_id >= 10000000;
DELETE FROM cc.agent_daily     WHERE date_key >= 20261101;
DELETE FROM cc.interval_volume WHERE date_key >= 20261101;
DELETE FROM cc.dim_date        WHERE date_key >= 20261101;
TRUNCATE pipeline.held_ivr_session, pipeline.held_survey_response, pipeline.held_complaint;
DELETE FROM discovery.dq_event WHERE incident_id IS NOT NULL;
DELETE FROM discovery.dq_incident_update;
DELETE FROM discovery.dq_incident;
DELETE FROM discovery.dq_load;
DELETE FROM discovery.dq_setting WHERE key = 'period_end';
DELETE FROM discovery.dq_check_result   WHERE run_id > $keep;
DELETE FROM discovery.dq_scorecard      WHERE run_id > $keep;
DELETE FROM discovery.dq_distribution   WHERE run_id > $keep;
DELETE FROM discovery.dq_column_profile WHERE run_id > $keep;
DELETE FROM discovery.dq_daily_volume   WHERE run_id > $keep;
DELETE FROM discovery.dq_table_catalog  WHERE run_id > $keep;
DELETE FROM discovery.dq_run            WHERE run_id > $keep;
SELECT setval('discovery.dq_run_run_id_seq', $keep);
SELECT setval('discovery.dq_load_load_id_seq', 1, false);
SELECT setval('discovery.dq_incident_incident_id_seq', 1, false);
COMMIT;
"@
$tmp = Join-Path $env:TEMP 'happen_reset.sql'
[System.IO.File]::WriteAllText($tmp, $sql, (New-Object System.Text.UTF8Encoding $false))
& $psql @conn -q -v ON_ERROR_STOP=1 -f $tmp | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'reset failed' }

# exported files for runs after #5, then re-export run 5 as the latest
$exportDir = if ($env:HAPPEN_EXPORT) { $env:HAPPEN_EXPORT } else { Join-Path $root 'docs\data' }
if (Test-Path (Join-Path $exportDir 'runs')) {
    Get-ChildItem (Join-Path $exportDir 'runs') -Directory | Where-Object { [int]$_.Name -gt $keep } | Remove-Item -Recurse -Force
}
& powershell -NoProfile -File (Join-Path $root 'sql\discovery\run_discovery.ps1') -ExportOnly -ResumeRunId $keep | Out-Null
"reset: data back to 31 Oct 2026, latest run #$keep"
