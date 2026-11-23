# Exports the JSON files the operational dashboards read (docs/data/dashboards/).
#   powershell -File sql\dashboards\export_dashboards.ps1 [-Only executive|stability|drivers|service]
# Env overrides (same as the discovery toolkit): HAPPEN_DB = database, HAPPEN_EXPORT = output folder.
param([ValidateSet('all', 'executive', 'stability', 'drivers', 'service')][string]$Only = 'all')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PGCLIENTENCODING = 'UTF8'
$psql = 'C:\Program Files\PostgreSQL\18\bin\psql.exe'
$db   = if ($env:HAPPEN_DB) { $env:HAPPEN_DB } else { 'happen_demo' }
$conn = @('-w', '-h', 'localhost', '-U', 'postgres', '-d', $db)
$out  = if ($env:HAPPEN_EXPORT) { $env:HAPPEN_EXPORT } else { Join-Path $PSScriptRoot '..\..\docs\data\dashboards' }
New-Item -ItemType Directory -Force $out | Out-Null

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
