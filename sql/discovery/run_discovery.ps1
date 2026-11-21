# Runs a full data discovery / data quality pass as a new run, then exports JSON for the health dashboard.
#   powershell -File sql\discovery\run_discovery.ps1 [-Notes "why this run"]
#   -ResumeRunId N   finish an interrupted run from the rule-check step (keeps its catalog, profiles and volume)
param([string]$Notes = 'Scheduled discovery run', [int]$ResumeRunId = 0)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PGCLIENTENCODING = 'UTF8'
$psql = 'C:\Program Files\PostgreSQL\18\bin\psql.exe'
$conn = @('-w', '-h', 'localhost', '-U', 'postgres', '-d', 'happen_demo')
$dir  = $PSScriptRoot
$out  = Join-Path $PSScriptRoot '..\..\docs\data'
New-Item -ItemType Directory -Force $out | Out-Null

function Invoke-File([string]$f) {
    & $psql @conn -q -v ON_ERROR_STOP=1 -f (Join-Path $dir $f) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "$f failed" }
}
function Invoke-Scalar([string]$sql) {
    $r = & $psql @conn -q -At -v ON_ERROR_STOP=1 -c $sql
    if ($LASTEXITCODE -ne 0) { throw "SQL failed: $sql" }
    return ($r | Select-Object -Last 1)
}
function Step([string]$name, [scriptblock]$body) {
    $t = Get-Date; & $body; "{0,-34} {1,6:N0}s" -f $name, ((Get-Date) - $t).TotalSeconds
}

Step 'setup, engine, rules' { Invoke-File 'D00_setup.sql'; Invoke-File 'D01_functions.sql'; Invoke-File 'D02_rules.sql' }
if ($ResumeRunId -gt 0) {
    $run = $ResumeRunId
    "resuming run_id = $run"
    Invoke-Scalar "DELETE FROM discovery.dq_check_result WHERE run_id = $run; DELETE FROM discovery.dq_scorecard WHERE run_id = $run;" | Out-Null
} else {
    $notesSql = $Notes.Replace("'", "''")
    $run = [int](Invoke-Scalar "INSERT INTO discovery.dq_run (notes) VALUES ('$notesSql') RETURNING run_id;")
    "run_id = $run"
    Step 'table catalog'  { Invoke-Scalar "SELECT discovery.build_catalog($run);" | Out-Null }
    Step 'column profiles' {
        $tables = & $psql @conn -At -c "SELECT relname FROM pg_class WHERE relnamespace = 'cc'::regnamespace AND relkind = 'r' ORDER BY relname;"
        foreach ($t in $tables) { Invoke-Scalar "SELECT discovery.profile_table($run, '$t');" | Out-Null }
    }
    Step 'daily volume'   { Invoke-Scalar "SELECT discovery.build_daily_volume($run);" | Out-Null }
}
Step 'rule checks'    { Invoke-Scalar "SELECT discovery.run_checks($run);" | Out-Null }
Step 'scorecard'      { Invoke-Scalar "SELECT discovery.build_scorecard($run);" | Out-Null }
Invoke-Scalar "UPDATE discovery.dq_run SET finished_at = now() WHERE run_id = $run;" | Out-Null

# ---------------- JSON export for the dashboard ----------------
function Export-Json([string]$name, [string]$sql) {
    $json = (& $psql @conn -At -v ON_ERROR_STOP=1 -c $sql) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "export $name failed" }
    $path = Join-Path $out $name
    [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
    "{0,-26} {1,8:N0} bytes" -f $name, (Get-Item $path).Length
}

Export-Json 'summary.json' @"
SELECT json_build_object(
  'run', (SELECT json_build_object('run_id', run_id, 'started_at', started_at, 'finished_at', finished_at, 'notes', notes) FROM discovery.dq_run WHERE run_id = $run),
  'overall', (SELECT json_build_object('score', score, 'status', status, 'checks', checks, 'passed', passed, 'warned', warned, 'failed', failed)
              FROM discovery.dq_scorecard WHERE run_id = $run AND table_name = '(all tables)' AND dimension = '(all dimensions)'),
  'tables_monitored', (SELECT count(*) FROM discovery.dq_table_catalog WHERE run_id = $run),
  'rows_monitored', (SELECT sum(row_count) FROM discovery.dq_table_catalog WHERE run_id = $run),
  'columns_profiled', (SELECT count(*) FROM discovery.dq_column_profile WHERE run_id = $run),
  'period', json_build_object('start', '2024-01-01', 'end', '2026-10-31'),
  'history', (SELECT json_agg(json_build_object('run_id', r.run_id, 'started_at', r.started_at, 'score', s.score, 'failed', s.failed, 'warned', s.warned) ORDER BY r.run_id)
              FROM discovery.dq_run r JOIN discovery.dq_scorecard s ON s.run_id = r.run_id AND s.table_name = '(all tables)' AND s.dimension = '(all dimensions)'));
"@

Export-Json 'scorecard.json' @"
SELECT json_agg(json_build_object('table', s.table_name, 'table_type', c.table_type, 'rows', c.row_count, 'dimension', s.dimension,
       'checks', s.checks, 'passed', s.passed, 'warned', s.warned, 'failed', s.failed, 'score', s.score, 'status', s.status)
       ORDER BY s.table_name, s.dimension)
FROM discovery.dq_scorecard s LEFT JOIN discovery.dq_table_catalog c ON c.run_id = s.run_id AND c.table_name = s.table_name
WHERE s.run_id = $run;
"@

Export-Json 'checks.json' @"
SELECT json_agg(json_build_object('rule_id', rule_id, 'table', table_name, 'column', column_name, 'dimension', dimension, 'rule', rule_name,
       'severity', severity, 'value', measured_value, 'unit', unit, 'warn_above', warn_above, 'fail_above', fail_above, 'status', status,
       'description', description, 'expected_note', expected_note, 'error', error_message, 'duration_ms', duration_ms)
       ORDER BY CASE status WHEN 'Fail' THEN 0 WHEN 'Error' THEN 0 WHEN 'Warn' THEN 1 ELSE 2 END, rule_id)
FROM discovery.dq_check_result WHERE run_id = $run;
"@

Export-Json 'catalog.json' @"
SELECT json_agg(json_build_object('table', table_name, 'table_type', table_type, 'description', description, 'rows', row_count,
       'size_bytes', size_bytes, 'columns', column_count, 'primary_key', pk_columns, 'foreign_keys', fk_count,
       'date_column', date_column, 'min_date', min_date, 'max_date', max_date) ORDER BY row_count DESC)
FROM discovery.dq_table_catalog WHERE run_id = $run;
"@

Export-Json 'column_profile.json' @"
SELECT json_agg(json_build_object('table', table_name, 'column', column_name, 'ordinal', ordinal, 'type', data_type, 'family', type_family,
       'rows', row_count, 'nulls', null_count, 'null_pct', null_pct, 'distinct', distinct_count, 'distinct_pct', distinct_pct,
       'min', min_value, 'max', max_value, 'mean', mean_value, 'stddev', stddev_value,
       'p01', p01, 'p25', p25, 'p50', p50, 'p75', p75, 'p99', p99,
       'zeros', zero_count, 'negatives', negative_count, 'empty_strings', empty_string_count, 'true_pct', true_pct)
       ORDER BY table_name, ordinal)
FROM discovery.dq_column_profile WHERE run_id = $run;
"@

Export-Json 'distribution.json' @"
SELECT json_agg(json_build_object('table', table_name, 'column', column_name, 'rank', rank, 'value', value, 'rows', row_count, 'pct', pct)
       ORDER BY table_name, column_name, rank)
FROM discovery.dq_distribution WHERE run_id = $run;
"@

Export-Json 'daily_volume.json' @"
SELECT json_agg(json_build_object('table', table_name, 'day', day, 'rows', row_count, 'baseline', round(baseline), 'ratio', round(ratio, 3),
       'outlier', is_outlier, 'closed', is_center_closed) ORDER BY table_name, day)
FROM discovery.dq_daily_volume WHERE run_id = $run;
"@
"done: run $run"
