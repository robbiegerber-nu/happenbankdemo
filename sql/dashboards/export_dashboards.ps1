# Exports the JSON files the operational dashboards read (docs/data/dashboards/).
#   powershell -File sql\dashboards\export_dashboards.ps1 [-Only executive|stability|drivers|service|workforce|coaching|cx|launch|personas|selfservice]
# Run after each daily load by sql\pipeline\load_day.ps1 (only when no check failed), or by hand at any time.
# Everything is written to a temporary folder first and copied across only when every export has worked.
# Env overrides (same as the discovery toolkit): HAPPEN_DB = database, HAPPEN_EXPORT = data folder (files go in its dashboards subfolder).
param([ValidateSet('all', 'executive', 'stability', 'drivers', 'service', 'workforce', 'coaching', 'cx', 'launch', 'personas', 'selfservice')][string]$Only = 'all')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PGCLIENTENCODING = 'UTF8'
$psql = 'C:\Program Files\PostgreSQL\18\bin\psql.exe'
$db   = if ($env:HAPPEN_DB) { $env:HAPPEN_DB } else { 'happen_demo' }
$conn = @('-w', '-h', 'localhost', '-U', 'postgres', '-d', $db)
$final = if ($env:HAPPEN_EXPORT) { Join-Path $env:HAPPEN_EXPORT 'dashboards' } else { Join-Path $PSScriptRoot '..\..\docs\data\dashboards' }
New-Item -ItemType Directory -Force $final | Out-Null
$final = (Resolve-Path $final).Path
$out   = Join-Path $env:TEMP "happen_dashboards_$PID"
New-Item -ItemType Directory -Force $out | Out-Null
try {

function Invoke-SqlFile([string]$f) {
    $t = Get-Date
    & $psql @conn -q -v ON_ERROR_STOP=1 -f (Join-Path $PSScriptRoot $f) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "$f failed" }
    "{0,-36} {1,17:N0}s" -f $f, ((Get-Date) - $t).TotalSeconds
}
function Export-Json([string]$name, [string]$sqlFile, [string[]]$vars = @()) {
    $t = Get-Date
    $v = @(); foreach ($x in $vars) { $v += '-v'; $v += $x }
    $json = (& $psql @conn -q -At -v ON_ERROR_STOP=1 @v -f (Join-Path $PSScriptRoot $sqlFile) | Where-Object { $_ -ne 'SET' }) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "export $name failed" }
    $path = Join-Path $out $name
    New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
    [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
    "{0,-36} {1,10:N0} bytes {2,4:N0}s" -f $name, (Get-Item $path).Length, ((Get-Date) - $t).TotalSeconds
}

# Compressed, because the explorer loads up to 13 months. The browser unpacks it.
function Export-Gzip([string]$name, [string]$sqlFile, [string[]]$vars) {
    $v = @(); foreach ($x in $vars) { $v += '-v'; $v += $x }
    $json = (& $psql @conn -q -At -v ON_ERROR_STOP=1 @v -f (Join-Path $PSScriptRoot $sqlFile)) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "export $name failed" }
    $path = Join-Path $out $name
    New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json)
    $ms = New-Object System.IO.MemoryStream
    $gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionLevel]::Optimal, $true)
    $gz.Write($bytes, 0, $bytes.Length); $gz.Dispose()
    [System.IO.File]::WriteAllBytes($path, $ms.ToArray())
}

Invoke-SqlFile 'E00_dash_schema.sql'
if ($Only -in 'all', 'executive') { Export-Json 'executive.json' 'E01_executive_scorecard.sql' }
if ($Only -in 'all', 'stability') {
    Invoke-SqlFile 'E02_stability_cube.sql'
    $metrics = & $psql @conn -At -c "SELECT DISTINCT metric FROM dash.stability ORDER BY 1;"
    foreach ($m in $metrics) { Export-Json "stability/$m.json" 'E03_stability_metric.sql' @("m=$m") }
    Export-Json 'events.json' 'E04_events.sql'
}
if ($Only -in 'all', 'drivers') {
    Invoke-SqlFile 'E05_driver_cube.sql'
    Export-Json 'drivers/index.json' 'E06_driver_index.sql'
    $t = Get-Date
    $months = (Get-Content (Join-Path $out 'drivers\index.json') -Raw -Encoding UTF8 | ConvertFrom-Json).months
    foreach ($m in $months) {
        Export-Gzip "drivers/$m.json.gz" 'E07_driver_month.sql' @("m=$m", 't=driver')
        Export-Gzip "drivers/agents/$m.json.gz" 'E07_driver_month.sql' @("m=$m", 't=driver_agent')
    }
    "{0,-36} {1,10:N0} bytes {2,4:N0}s" -f "drivers: $($months.Count) months", (Get-ChildItem (Join-Path $out 'drivers') -Recurse -File | Measure-Object Length -Sum).Sum, ((Get-Date) - $t).TotalSeconds
}
if ($Only -in 'all', 'service') {
    Export-Json 'service/index.json' 'E08_service_index.sql'
    $t = Get-Date
    $months = (Get-Content (Join-Path $out 'service\index.json') -Raw -Encoding UTF8 | ConvertFrom-Json).months
    foreach ($m in $months) { Export-Gzip "service/$m.json.gz" 'E09_service_month.sql' @("m=$m") }
    "{0,-36} {1,10:N0} bytes {2,4:N0}s" -f "service: $($months.Count) months", (Get-ChildItem (Join-Path $out 'service') -File | Measure-Object Length -Sum).Sum, ((Get-Date) - $t).TotalSeconds
}

if ($Only -in 'all', 'workforce') {
    Invoke-SqlFile 'E10_workforce_cube.sql'
    Export-Gzip 'workforce/index.json.gz' 'E11_workforce_index.sql' @()
    $t = Get-Date
    $months = & $psql @conn -At -v ON_ERROR_STOP=1 -c "SELECT DISTINCT to_char(d, 'YYYY-MM') FROM dash.wf_interval ORDER BY 1;"
    if ($LASTEXITCODE -ne 0) { throw 'workforce months failed' }
    foreach ($m in $months) { Export-Gzip "workforce/$m.json.gz" 'E12_workforce_month.sql' @("m=$m") }
    "{0,-36} {1,10:N0} bytes {2,4:N0}s" -f "workforce: $($months.Count) months", (Get-ChildItem (Join-Path $out 'workforce') -File | Measure-Object Length -Sum).Sum, ((Get-Date) - $t).TotalSeconds
}

if ($Only -in 'all', 'coaching') {
    Invoke-SqlFile 'E13_coaching_cube.sql'
    Export-Gzip 'coaching/index.json.gz' 'E14_coaching_index.sql' @()
    "{0,-36} {1,10:N0} bytes" -f 'coaching/index.json.gz', (Get-Item (Join-Path $out 'coaching\index.json.gz')).Length
}

if ($Only -in 'all', 'cx') {
    Invoke-SqlFile 'E15_cx_cube.sql'
    Export-Json 'cx/index.json' 'E16_cx_index.sql'
    $t = Get-Date
    $months = (Get-Content (Join-Path $out 'cx\index.json') -Raw -Encoding UTF8 | ConvertFrom-Json).months
    foreach ($m in $months) { Export-Gzip "cx/$m.json.gz" 'E17_cx_month.sql' @("m=$m") }
    "{0,-36} {1,10:N0} bytes {2,4:N0}s" -f "cx: $($months.Count) months", (Get-ChildItem (Join-Path $out 'cx') -File | Measure-Object Length -Sum).Sum, ((Get-Date) - $t).TotalSeconds
}

if ($Only -in 'all', 'launch') {
    Invoke-SqlFile 'E18_launch_cube.sql'
    Export-Gzip 'launch/index.json.gz' 'E19_launch_index.sql' @()
    "{0,-36} {1,10:N0} bytes" -f 'launch/index.json.gz', (Get-Item (Join-Path $out 'launch\index.json.gz')).Length
}

if ($Only -in 'all', 'personas') {
    Invoke-SqlFile 'E20_persona_cube.sql'
    Export-Json 'personas/index.json' 'E21_persona_index.sql'
    $t = Get-Date
    $months = (Get-Content (Join-Path $out 'personas\index.json') -Raw -Encoding UTF8 | ConvertFrom-Json).months
    foreach ($m in $months) { Export-Gzip "personas/$m.json.gz" 'E22_persona_month.sql' @("m=$m") }
    "{0,-36} {1,10:N0} bytes {2,4:N0}s" -f "personas: $($months.Count) months", (Get-ChildItem (Join-Path $out 'personas') -File | Measure-Object Length -Sum).Sum, ((Get-Date) - $t).TotalSeconds
}

if ($Only -in 'all', 'selfservice') {
    Invoke-SqlFile 'E23_selfservice_cube.sql'
    Export-Json 'selfservice/index.json' 'E24_selfservice_index.sql'
    $t = Get-Date
    $months = (Get-Content (Join-Path $out 'selfservice\index.json') -Raw -Encoding UTF8 | ConvertFrom-Json).months
    foreach ($m in $months) { Export-Gzip "selfservice/$m.json.gz" 'E25_selfservice_month.sql' @("m=$m") }
    "{0,-36} {1,10:N0} bytes {2,4:N0}s" -f "selfservice: $($months.Count) months", (Get-ChildItem (Join-Path $out 'selfservice') -File | Measure-Object Length -Sum).Sum, ((Get-Date) - $t).TotalSeconds
}

# ---------- Publish the finished set to the data folder ----------
# kpis.json is written by hand and is never touched. Month files that no longer exist in the data (after a reset) are removed.
$changed = 0; $removed = 0
$new = Get-ChildItem $out -Recurse -File
foreach ($f in $new) {
    $rel = $f.FullName.Substring($out.Length + 1); $dest = Join-Path $final $rel
    if ((Test-Path $dest) -and (Get-FileHash $dest).Hash -eq (Get-FileHash $f.FullName).Hash) { continue }
    New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
    Copy-Item $f.FullName $dest -Force; $changed++
}
foreach ($sub in 'stability', 'drivers', 'service', 'workforce', 'coaching', 'cx', 'launch', 'personas', 'selfservice') {
    if (-not (Test-Path (Join-Path $out $sub)) -or -not (Test-Path (Join-Path $final $sub))) { continue }
    Get-ChildItem (Join-Path $final $sub) -Recurse -File | Where-Object { -not (Test-Path (Join-Path $out $_.FullName.Substring($final.Length + 1))) } |
        ForEach-Object { Remove-Item $_.FullName; $removed++ }
}
"dashboards: $changed of $($new.Count) files changed, $removed removed"
} finally { Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue }
