# Runs a full data discovery / data quality pass as a new run, then exports JSON for the health dashboard.
#   powershell -File sql\discovery\run_discovery.ps1 [-Notes "why this run"]
#   -ResumeRunId N   finish an interrupted run from the rule-check step (keeps its catalog, profiles and volume)
#   -ExportOnly      skip all checks; re-export JSON for the latest run (or -ResumeRunId N)
#   -AllRuns         also re-export every earlier run's folder (docs/data/runs/<run_id>/)
#   -Summary "..."   what changed in this run, in plain words for business users (shown on the dashboard)
param([string]$Notes = 'Scheduled discovery run', [string]$Summary = '', [int]$ResumeRunId = 0, [switch]$ExportOnly, [switch]$AllRuns)
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

if ($ExportOnly) {
    $run = if ($ResumeRunId -gt 0) { $ResumeRunId } else { [int](Invoke-Scalar "SELECT max(run_id) FROM discovery.dq_run;") }
    "export only: run_id = $run"
} else {
Step 'setup, engine, rules' { Invoke-File 'D00_setup.sql'; Invoke-File 'D01_functions.sql'; Invoke-File 'D02_rules.sql'; Invoke-File 'D04_events.sql' }
if ($ResumeRunId -gt 0) {
    $run = $ResumeRunId
    "resuming run_id = $run"
    Invoke-Scalar "DELETE FROM discovery.dq_check_result WHERE run_id = $run; DELETE FROM discovery.dq_scorecard WHERE run_id = $run;" | Out-Null
} else {
    $notesSql = $Notes.Replace("'", "''"); $summarySql = if ($Summary) { "'" + $Summary.Replace("'", "''") + "'" } else { 'NULL' }
    $run = [int](Invoke-Scalar "INSERT INTO discovery.dq_run (notes, summary) VALUES ('$notesSql', $summarySql) RETURNING run_id;")
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
}

# ---------------- JSON export for the dashboard ----------------
# Latest run -> docs/data/*.json ; every run -> docs/data/runs/<run_id>/ ; list of runs -> docs/data/runs/index.json
function Export-Json([string]$name, [string]$sql, [string]$dir = $out) {
    New-Item -ItemType Directory -Force $dir | Out-Null
    $json = (& $psql @conn -At -v ON_ERROR_STOP=1 -c $sql) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "export $name failed" }
    $path = Join-Path $dir $name
    [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
    "{0,-34} {1,8:N0} bytes" -f ((Split-Path $dir -Leaf) + '/' + $name), (Get-Item $path).Length
}

# The four files the dashboard needs to show one run (written for the latest run and for every run's folder)
function Export-RunFiles([int]$run, [string]$dir) {
Export-Json 'summary.json' -dir $dir -sql @"
SELECT json_build_object(
  'run', (SELECT json_build_object('run_id', run_id, 'started_at', started_at, 'finished_at', finished_at, 'notes', notes, 'summary', summary) FROM discovery.dq_run WHERE run_id = $run),
  'overall', (SELECT json_build_object('score', score, 'status', status, 'checks', checks, 'passed', passed, 'warned', warned, 'failed', failed)
              FROM discovery.dq_scorecard WHERE run_id = $run AND table_name = '(all tables)' AND dimension = '(all dimensions)'),
  'tables_monitored', (SELECT count(*) FROM discovery.dq_table_catalog WHERE run_id = $run),
  'rows_monitored', (SELECT sum(row_count) FROM discovery.dq_table_catalog WHERE run_id = $run),
  'columns_profiled', (SELECT count(*) FROM discovery.dq_column_profile WHERE run_id = $run),
  'period', json_build_object('start', '2024-01-01', 'end', '2026-10-31'),
  'previous_run_id', (SELECT max(run_id) FROM discovery.dq_scorecard WHERE run_id < $run),
  'history', (SELECT json_agg(json_build_object('run_id', r.run_id, 'started_at', r.started_at, 'notes', r.notes, 'score', s.score, 'status', s.status,
                     'checks', s.checks, 'passed', s.passed, 'warned', s.warned, 'failed', s.failed) ORDER BY r.run_id)
              FROM discovery.dq_run r JOIN discovery.dq_scorecard s ON s.run_id = r.run_id AND s.table_name = '(all tables)' AND s.dimension = '(all dimensions)'
              WHERE r.run_id <= $run));
"@

Export-Json 'scorecard.json' -dir $dir -sql @"
SELECT json_agg(json_build_object('table', s.table_name, 'table_type', c.table_type, 'rows', c.row_count, 'dimension', s.dimension,
       'checks', s.checks, 'passed', s.passed, 'warned', s.warned, 'failed', s.failed, 'score', s.score, 'status', s.status)
       ORDER BY s.table_name, s.dimension)
FROM discovery.dq_scorecard s LEFT JOIN discovery.dq_table_catalog c ON c.run_id = s.run_id AND c.table_name = s.table_name
WHERE s.run_id = $run;
"@

Export-Json 'checks.json' -dir $dir -sql @"
SELECT json_agg(json_build_object('rule_id', c.rule_id, 'table', c.table_name, 'column', c.column_name, 'dimension', c.dimension, 'rule', c.rule_name,
       'severity', c.severity, 'value', c.measured_value, 'unit', c.unit, 'warn_above', c.warn_above, 'fail_above', c.fail_above, 'status', c.status,
       'description', c.description, 'expected_note', c.expected_note, 'error', c.error_message, 'duration_ms', c.duration_ms,
       'prev_status', p.status, 'prev_value', p.measured_value, 'prev_rule', p.rule_name,
       'problem', q.problem_plain, 'evidence', c.evidence, 'prev_evidence', p.evidence,
       -- for data fields flagged last run: how they look in this run (filled count, distinct values, top values)
       'followup', (SELECT json_agg(json_build_object('t', e->>'t', 'c', e->>'c', 'rows', cp.row_count, 'filled', cp.row_count - cp.null_count,
                           'distinct', cp.distinct_count,
                           'top', (SELECT json_agg(json_build_object('v', d.value, 'n', d.row_count) ORDER BY d.rank)
                                   FROM discovery.dq_distribution d WHERE d.run_id = $run AND d.table_name = e->>'t' AND d.column_name = e->>'c' AND d.rank <= 4)))
                    FROM jsonb_array_elements(p.evidence) e
                    JOIN discovery.dq_column_profile cp ON cp.run_id = $run AND cp.table_name = e->>'t' AND cp.column_name = e->>'c'
                    WHERE e ? 'c'))
       ORDER BY CASE c.status WHEN 'Fail' THEN 0 WHEN 'Error' THEN 0 WHEN 'Warn' THEN 1 ELSE 2 END, c.rule_id)
FROM discovery.dq_check_result c
LEFT JOIN discovery.dq_rule q ON q.rule_id = c.rule_id
LEFT JOIN discovery.dq_check_result p ON p.rule_id = c.rule_id
      AND p.run_id = (SELECT max(run_id) FROM discovery.dq_check_result WHERE run_id < $run)
WHERE c.run_id = $run;
"@

# Per-run, per-table scores for history drill-down
Export-Json 'scorecard_history.json' -dir $dir -sql @"
SELECT json_agg(json_build_object('run_id', run_id, 'table', table_name, 'dimension', dimension, 'score', score, 'status', status,
       'passed', passed, 'warned', warned, 'failed', failed) ORDER BY run_id, table_name, dimension)
FROM discovery.dq_scorecard WHERE run_id <= $run AND dimension = '(all dimensions)';
"@
}

# Latest run at the top level (what the dashboard opens by default), plus its own run folder
Export-RunFiles -run $run -dir $out
Export-RunFiles -run $run -dir (Join-Path $out "runs\$run")

# -AllRuns: (re)write every earlier run's folder too (used to backfill runs recorded before per-run export existed)
if ($AllRuns) {
    $ids = & $psql @conn -At -c "SELECT DISTINCT run_id FROM discovery.dq_scorecard WHERE run_id < $run ORDER BY 1;"
    foreach ($id in $ids) { Export-RunFiles -run ([int]$id) -dir (Join-Path $out "runs\$id") }
}

# Index of all runs for the dashboard's run picker and trend chart
Export-Json 'index.json' -dir (Join-Path $out 'runs') -sql @"
SELECT json_build_object('latest_run_id', (SELECT max(run_id) FROM discovery.dq_scorecard), 'runs',
  (SELECT json_agg(json_build_object('run_id', r.run_id, 'started_at', r.started_at, 'notes', r.notes, 'summary', r.summary, 'score', s.score, 'status', s.status,
          'checks', s.checks, 'passed', s.passed, 'warned', s.warned, 'failed', s.failed) ORDER BY r.run_id)
   FROM discovery.dq_run r JOIN discovery.dq_scorecard s ON s.run_id = r.run_id AND s.table_name = '(all tables)' AND s.dimension = '(all dimensions)'));
"@

# ---------- Explorer data (dashboard v3 tabs): per run, so the Columns and Daily volume tabs follow the run picker ----------
function Export-Explorer([int]$run, [string]$dir) {
Export-Json 'profile.json' -dir $dir -sql @"
SELECT json_build_object('tables', json_agg(t ORDER BY (t->>'rows')::bigint DESC)) FROM (
  SELECT json_build_object('table', c.table_name, 'type', c.table_type, 'description', c.description, 'rows', c.row_count,
    'columns', (SELECT json_agg(json_build_object('column', p.column_name, 'ordinal', p.ordinal, 'type', p.data_type, 'family', p.type_family,
        'description', col_description(format('cc.%I', p.table_name)::regclass, p.ordinal),
        'rows', p.row_count, 'nulls', p.null_count, 'null_pct', p.null_pct, 'distinct', p.distinct_count,
        'min', p.min_value, 'max', p.max_value, 'p01', p.p01, 'p50', p.p50, 'p99', p.p99, 'mean', round(p.mean_value, 2), 'true_pct', p.true_pct,
        'top', (SELECT json_agg(json_build_object('v', d.value, 'n', d.row_count, 'pct', d.pct) ORDER BY d.rank)
                FROM discovery.dq_distribution d WHERE d.run_id = p.run_id AND d.table_name = p.table_name AND d.column_name = p.column_name))
      ORDER BY p.ordinal)
      FROM discovery.dq_column_profile p WHERE p.run_id = c.run_id AND p.table_name = c.table_name)) AS t
  FROM discovery.dq_table_catalog c WHERE c.run_id = $run) x;
"@
Export-Json 'volume.json' -dir $dir -sql @"
SELECT json_build_object(
  'days', (SELECT json_agg(day ORDER BY day) FROM discovery.dq_daily_volume WHERE run_id = $run AND table_name = 'contact'),
  'tables', (SELECT json_object_agg(table_name, json_build_object('rows', r, 'base', b, 'out', o, 'closed', cl)) FROM (
     SELECT table_name, json_agg(row_count ORDER BY day) AS r, json_agg(round(baseline) ORDER BY day) AS b,
            json_agg(is_outlier::int ORDER BY day) AS o, json_agg(is_center_closed::int ORDER BY day) AS cl
     FROM discovery.dq_daily_volume WHERE run_id = $run GROUP BY table_name) x));
"@
}
Export-Explorer -run $run -dir (Join-Path $out "runs\$run")
if ($AllRuns) {
    $ids = & $psql @conn -At -c "SELECT DISTINCT run_id FROM discovery.dq_scorecard WHERE run_id < $run ORDER BY 1;"
    foreach ($id in $ids) { Export-Explorer -run ([int]$id) -dir (Join-Path $out "runs\$id") }
}

# ---------- Rule catalogue: every rule with its result in every run ----------
Export-Json 'rules.json' -sql @"
SELECT json_agg(json_build_object('rule_id', r.rule_id, 'table', r.table_name, 'column', r.column_name, 'dimension', r.dimension,
       'rule', r.rule_name, 'description', r.description, 'problem', r.problem_plain, 'severity', r.severity, 'unit', r.unit,
       'warn_above', r.warn_above, 'fail_above', r.fail_above, 'expected_note', r.expected_note, 'sql', btrim(r.check_sql),
       'history', (SELECT json_agg(json_build_object('run', c.run_id, 'status', c.status, 'value', c.measured_value, 'rule', c.rule_name) ORDER BY c.run_id)
                   FROM discovery.dq_check_result c WHERE c.rule_id = r.rule_id))
       ORDER BY r.rule_id)
FROM discovery.dq_rule r WHERE r.is_active;
"@

# ---------- Events that annotate the daily volume timeline ----------
Export-Json 'events.json' -sql @"
SELECT json_build_object(
  'events', (SELECT json_agg(json_build_object('start', start_date, 'end', end_date, 'kind', kind, 'title', title, 'description', description) ORDER BY start_date) FROM discovery.dq_event),
  'launches', (SELECT json_agg(json_build_object('date', launch_date, 'title', launch_name, 'type', launch_type, 'description', description) ORDER BY launch_date) FROM cc.product_launch),
  'holidays', (SELECT json_agg(json_build_object('date', full_date, 'title', holiday_name, 'closed', is_center_closed) ORDER BY full_date) FROM cc.dim_date WHERE is_holiday));
"@
"done: run $run"
