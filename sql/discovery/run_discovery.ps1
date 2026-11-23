# Runs a full data discovery / data quality pass as a new run, then exports JSON for the health dashboard.
#   powershell -File sql\discovery\run_discovery.ps1 [-Notes "why this run"]
#   -ResumeRunId N   finish an interrupted run from the rule-check step (keeps its catalog, profiles and volume)
#   -ExportOnly      skip all checks; re-export JSON for the latest run (or -ResumeRunId N)
#   -AllRuns         also re-export every earlier run's folder (docs/data/runs/<run_id>/)
#   -Summary "..."   what changed in this run, in plain words for business users (shown on the dashboard)
#   -BusinessDate d  (v3.1, set by load_day.ps1) the business day this run checks; links the day's loads to the run
#   -SkipExport      run the checks only (load_day.ps1 exports after tracking incidents)
param([string]$Notes = 'Scheduled discovery run', [string]$Summary = '', [int]$ResumeRunId = 0, [switch]$ExportOnly, [switch]$AllRuns,
      [string]$BusinessDate = '', [switch]$SkipExport)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PGCLIENTENCODING = 'UTF8'
$psql = 'C:\Program Files\PostgreSQL\18\bin\psql.exe'
$db   = if ($env:HAPPEN_DB) { $env:HAPPEN_DB } else { 'happen_demo' }   # set HAPPEN_DB to work on a copy (rehearsals)
$conn = @('-w', '-h', 'localhost', '-U', 'postgres', '-d', $db)
$dir  = $PSScriptRoot
$out  = if ($env:HAPPEN_EXPORT) { $env:HAPPEN_EXPORT } else { Join-Path $PSScriptRoot '..\..\docs\data' }   # set HAPPEN_EXPORT to keep rehearsal output away from the dashboard
New-Item -ItemType Directory -Force $out | Out-Null

function Invoke-File([string]$f) {
    & $psql @conn -q -v ON_ERROR_STOP=1 -f (Join-Path $dir $f) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "$f failed" }
}
function Invoke-Scalar([string]$sql) {
    # more sort memory for this session only: profiling counts distinct values over millions of rows
    $r = & $psql @conn -q -At -v ON_ERROR_STOP=1 -c "SET work_mem = '256MB'; $sql"
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
Step 'setup, engine, rules' { foreach ($f in 'D00_setup.sql', 'D01_functions.sql', 'D02_rules.sql', 'D04_events.sql', 'D05_evidence.sql', 'D06_incidents.sql', 'D07_refinements.sql') { Invoke-File $f } }
if ($ResumeRunId -gt 0) {
    $run = $ResumeRunId
    "resuming run_id = $run"
    Invoke-Scalar "DELETE FROM discovery.dq_check_result WHERE run_id = $run; DELETE FROM discovery.dq_scorecard WHERE run_id = $run;" | Out-Null
} else {
    $notesSql = $Notes.Replace("'", "''"); $summarySql = if ($Summary) { "'" + $Summary.Replace("'", "''") + "'" } else { 'NULL' }
    $bdSql = if ($BusinessDate) { "'$BusinessDate'" } else { 'NULL' }
    $run = [int](Invoke-Scalar "INSERT INTO discovery.dq_run (notes, summary, business_date, period_end) VALUES ('$notesSql', $summarySql, $bdSql, discovery.period_end()) RETURNING run_id;")
    if ($BusinessDate) { Invoke-Scalar "UPDATE discovery.dq_load SET run_id = $run WHERE run_id IS NULL;" | Out-Null }
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
if ($SkipExport) { "checked: run $run"; return }
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
  'run', (SELECT json_build_object('run_id', run_id, 'started_at', started_at, 'finished_at', finished_at, 'notes', notes, 'summary', summary,
                                   'business_date', business_date) FROM discovery.dq_run WHERE run_id = $run),
  -- v3.1: the files this run checked
  'loads', (SELECT json_agg(json_build_object('load_id', load_id, 'arrived_on', arrived_on, 'business_date', business_date, 'feed', feed,
                  'file', file_name, 'kind', load_kind, 'action', action, 'status', status, 'expected', expected_rows, 'received', rows_received,
                  'inserted', rows_inserted, 'replaced', rows_replaced, 'deleted', rows_deleted, 'held', rows_held, 'released', rows_released,
                  'reason', reason, 'fix', fix) ORDER BY CASE load_kind WHEN 'Daily' THEN 1 ELSE 0 END, load_id)
            FROM discovery.dq_load WHERE run_id = $run),
  'overall', (SELECT json_build_object('score', score, 'status', status, 'checks', checks, 'passed', passed, 'warned', warned, 'failed', failed)
              FROM discovery.dq_scorecard WHERE run_id = $run AND table_name = '(all tables)' AND dimension = '(all dimensions)'),
  'tables_monitored', (SELECT count(*) FROM discovery.dq_table_catalog WHERE run_id = $run),
  'rows_monitored', (SELECT sum(row_count) FROM discovery.dq_table_catalog WHERE run_id = $run),
  'columns_profiled', (SELECT count(*) FROM discovery.dq_column_profile WHERE run_id = $run),
  'period', json_build_object('start', '2024-01-01', 'end', (SELECT coalesce(period_end, date '2026-10-31') FROM discovery.dq_run WHERE run_id = $run)),
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
  (SELECT json_agg(json_build_object('run_id', r.run_id, 'started_at', r.started_at, 'business_date', r.business_date,
          'data_to', coalesce(r.period_end, date '2026-10-31'), 'notes', r.notes, 'summary', r.summary, 'score', s.score, 'status', s.status,
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

# ---------- v3.1: data incidents as they stood at each run (status, daily updates, cause, fix, fixing file, alert) ----------
function Export-Incidents([int]$run, [string]$dir) {
Export-Json 'incidents.json' -dir $dir -sql @"
SELECT coalesce(json_agg(json_build_object(
    'id', i.incident_id, 'title', i.title, 'business_date', i.business_date, 'rule_id', i.rule_id, 'impact', i.impact,
    'status', (SELECT u.status FROM discovery.dq_incident_update u WHERE u.incident_id = i.incident_id AND u.run_id <= $run ORDER BY u.run_id DESC LIMIT 1),
    'opened_run', i.opened_run_id,
    'resolved_run', CASE WHEN i.resolved_run_id <= $run THEN i.resolved_run_id END,
    'cause', CASE WHEN i.resolved_run_id <= $run THEN i.cause END,
    'fix', CASE WHEN i.resolved_run_id <= $run THEN i.fix END,
    'fix_file', CASE WHEN i.resolved_run_id <= $run THEN (SELECT json_build_object('file', l.file_name, 'kind', l.load_kind, 'arrived_on', l.arrived_on,
                      'replaced', l.rows_replaced, 'deleted', l.rows_deleted, 'inserted', l.rows_inserted, 'released', l.rows_released)
                      FROM discovery.dq_load l WHERE l.load_id = i.fix_load_id) END,
    'github_issue', i.github_issue,
    'checks', (SELECT json_agg(json_build_object('rule_id', k, 'problem', discovery.problem_of(k), 'unit', i.checks->k->>'unit')) FROM jsonb_object_keys(i.checks) k),
    'updates', (SELECT json_agg(json_build_object('run', u.run_id, 'business_date', r.business_date, 'status', u.status, 'note', u.note, 'checks', u.checks) ORDER BY u.run_id)
                FROM discovery.dq_incident_update u JOIN discovery.dq_run r USING (run_id) WHERE u.incident_id = i.incident_id AND u.run_id <= $run))
  ORDER BY i.incident_id DESC), '[]')
FROM discovery.dq_incident i WHERE i.opened_run_id <= $run;
"@
}
Export-Incidents -run $run -dir (Join-Path $out "runs\$run")
if ($AllRuns) {
    $ids = & $psql @conn -At -c "SELECT DISTINCT run_id FROM discovery.dq_scorecard WHERE run_id < $run ORDER BY 1;"
    foreach ($id in $ids) { Export-Incidents -run ([int]$id) -dir (Join-Path $out "runs\$id") }
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
