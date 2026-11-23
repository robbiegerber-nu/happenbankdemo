# Loads one business day of feeds, runs the data quality checks, tracks incidents and raises GitHub Issue alerts.
#   powershell -File sql\pipeline\load_day.ps1 -Date 2026-11-02 [-NoAlerts] [-LoadOnly]
#     -NoAlerts   record incidents but don't create, comment on or close GitHub Issues (for testing)
#     -LoadOnly   load the files and stop (no checks)
# Order within a day: late files, then corrections (both fix earlier days), then the day's own files.
# Nothing is published: review the exported dashboard data locally, then commit and push by hand.
param([Parameter(Mandatory)][string]$Date, [switch]$NoAlerts, [switch]$LoadOnly)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PGCLIENTENCODING = 'UTF8'
$psql = 'C:\Program Files\PostgreSQL\18\bin\psql.exe'
$db   = if ($env:HAPPEN_DB) { $env:HAPPEN_DB } else { 'happen_demo' }   # set HAPPEN_DB to work on a copy (rehearsals)
$conn = @('-w', '-h', 'localhost', '-U', 'postgres', '-d', $db)
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$day  = Join-Path $root "data\daily_loads\$Date"
$utf8 = New-Object System.Text.UTF8Encoding $false
$tmp  = Join-Path $env:TEMP 'happen_load_step.sql'
$repo = 'robbiegerber-nu/happenbankdemo'
if (-not (Test-Path (Join-Path $day 'manifest.json'))) { throw "No feed folder for $Date ($day)" }

# Runs SQL from a temp file (PowerShell 5.1 strips double quotes from native-command arguments); returns the last line
function Invoke-Sql([string]$sql) {
    [System.IO.File]::WriteAllText($tmp, "SET TimeZone = 'America/Chicago'; SET client_min_messages = warning;`n" + $sql, $utf8)
    $r = & $psql @conn -q -At -v ON_ERROR_STOP=1 -f $tmp
    if ($LASTEXITCODE -ne 0) { throw "SQL failed: $sql" }
    return ($r | Select-Object -Last 1)
}
function Lit([object]$v) { if ($null -eq $v -or "$v" -eq '') { 'NULL' } else { "'" + "$v".Replace("'", "''") + "'" } }

$already = Invoke-Sql "SELECT count(*) FROM discovery.dq_load WHERE arrived_on = '$Date';"
if ([int]$already -gt 0) { throw "$Date has already been loaded ($already files). Use reset_pipeline.ps1 to start the demo again." }

& $psql @conn -q -v ON_ERROR_STOP=1 -f (Join-Path $PSScriptRoot 'P00_setup.sql') | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'P00_setup.sql failed' }
Invoke-Sql "SELECT pipeline.ensure_date('$Date');" | Out-Null

$t0 = Get-Date
"=== Loading $Date ==="
foreach ($sub in 'late', 'corrections', '') {
    $dir = if ($sub) { Join-Path $day $sub } else { $day }
    $mf = Join-Path $dir 'manifest.json'
    if (-not (Test-Path $mf)) { continue }
    $m = [System.IO.File]::ReadAllText($mf) | ConvertFrom-Json
    $reason = if ($m.cause) { $m.cause } else { $m.reason }
    $fixes = if ($m.kind -ne 'Daily') { $m.business_date } else { $null }
    # contacts first, so the IVR calls, surveys and complaints that refer to them don't need holding
    $order = @{ contact = 0; ivr_session = 1; survey_response = 2; complaint = 3; agent_activity = 4; agent_schedule = 5; agent_daily = 6; interval_volume = 7 }
    foreach ($f in ($m.files | Sort-Object { $order[$_.feed] })) {
        $path = Join-Path $dir $f.file
        $args10 = "'$Date', '$($m.business_date)', '$($f.feed)', $(Lit $f.file), '$($m.kind)', '$($f.action)', $($f.rows), $(Lit $fixes), $(Lit $reason), $(Lit $m.fix)"
        if (-not (Test-Path $path)) {
            Invoke-Sql "SELECT pipeline.record_missing($args10);" | Out-Null
            "  {0,-11} {1,-30} MISSING (sender declared {2:N0} rows)" -f $m.kind, $f.file, $f.rows
            continue
        }
        $id = Invoke-Sql @"
SELECT pipeline.prepare_stage('$($f.feed)', '$($f.action)');
\copy pipeline.stage FROM '$($path.Replace('\', '/'))' WITH (FORMAT csv, HEADER)
SELECT pipeline.apply_stage($args10);
"@
        $l = (Invoke-Sql "SELECT row_to_json(l) FROM discovery.dq_load l WHERE load_id = $id;") | ConvertFrom-Json
        $extra = @()
        if ($l.rows_replaced) { $extra += "replaced $($l.rows_replaced)" }
        if ($l.rows_deleted)  { $extra += "deleted $($l.rows_deleted)" }
        if ($l.rows_held)     { $extra += "held $($l.rows_held)" }
        if ($l.rows_released) { $extra += "released $($l.rows_released) held" }
        "  {0,-11} {1,-30} {2,-14} {3,7:N0} rows {4}" -f $m.kind, $f.file, $l.status, $l.rows_received, ($extra -join ', ')
    }
}
Invoke-Sql "INSERT INTO discovery.dq_setting VALUES ('period_end', '$Date') ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;" | Out-Null
"loaded in {0:N0}s; data now runs to {1}" -f ((Get-Date) - $t0).TotalSeconds, $Date
if ($LoadOnly) { return }

# ---------- Checks (about 6 minutes) ----------
$label = ([datetime]$Date).ToString('ddd d MMM yyyy', [Globalization.CultureInfo]::InvariantCulture)
& powershell -NoProfile -File (Join-Path $root 'sql\discovery\run_discovery.ps1') -Notes "Daily load: $label" -BusinessDate $Date -SkipExport
if ($LASTEXITCODE -ne 0) { throw 'run_discovery failed' }
$run = [int](Invoke-Sql "SELECT max(run_id) FROM discovery.dq_run WHERE business_date = '$Date';")

# ---------- Incidents and summary ----------
$acts = (Invoke-Sql "SELECT discovery.track_incidents($run);") | ConvertFrom-Json
Invoke-Sql "UPDATE discovery.dq_run SET summary = discovery.summarize_run($run) WHERE run_id = $run;" | Out-Null
"--- Run #$run summary ---"
Invoke-Sql "SELECT summary FROM discovery.dq_run WHERE run_id = $run;"

# ---------- Alerts: one GitHub Issue per incident ----------
foreach ($a in $acts) {
    $inc = (Invoke-Sql "SELECT row_to_json(i) FROM discovery.dq_incident i WHERE incident_id = $($a.incident_id);") | ConvertFrom-Json
    "incident #{0} {1}: {2}" -f $inc.incident_id, $a.action, $inc.title
    if ($NoAlerts -or $a.action -eq 'accepted') { continue }
    $gh = 'C:\Program Files\GitHub CLI\gh.exe'
    $bodyFile = Join-Path $env:TEMP 'happen_issue_body.md'
    if ($a.action -eq 'opened') {
        & $gh label create data-quality --repo $repo --color D93F0B --description 'Automated data quality alert' --force 2>$null | Out-Null
        $body = (& $psql @conn -At -c "SELECT discovery.issue_text($($inc.incident_id), 'open', $run);") -join "`n"
        [System.IO.File]::WriteAllText($bodyFile, $body, $utf8)
        $url = & $gh issue create --repo $repo --title "[Data quality] $($inc.title)" --body-file $bodyFile --label data-quality
        if ($LASTEXITCODE -ne 0) { Write-Warning "could not open an issue for incident #$($inc.incident_id)"; continue }
        $num = [int]($url -replace '.*/', '')
        Invoke-Sql "UPDATE discovery.dq_incident SET github_issue = $num WHERE incident_id = $($inc.incident_id);" | Out-Null
        "  opened issue #$num"
    } elseif ($inc.github_issue) {
        $kind = if ($a.action -eq 'resolved') { 'resolve' } else { 'update' }
        $body = (& $psql @conn -At -c "SELECT discovery.issue_text($($inc.incident_id), '$kind', $run);") -join "`n"
        [System.IO.File]::WriteAllText($bodyFile, $body, $utf8)
        & $gh issue comment $inc.github_issue --repo $repo --body-file $bodyFile | Out-Null
        if ($a.action -eq 'resolved') { & $gh issue close $inc.github_issue --repo $repo --reason completed | Out-Null; "  closed issue #$($inc.github_issue)" }
        else { "  commented on issue #$($inc.github_issue)" }
    }
}

# ---------- Export for the dashboard (review locally; publishing is a separate, manual step) ----------
& powershell -NoProfile -File (Join-Path $root 'sql\discovery\run_discovery.ps1') -ExportOnly -ResumeRunId $run | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'export failed' }
"done: $Date checked in run #$run, total {0:N1} min" -f ((Get-Date) - $t0).TotalMinutes
