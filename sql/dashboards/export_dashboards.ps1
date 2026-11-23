# Exports the JSON files the operational dashboards read (docs/data/dashboards/).
#   powershell -File sql\dashboards\export_dashboards.ps1
# Env overrides (same as the discovery toolkit): HAPPEN_DB = database, HAPPEN_EXPORT = output folder.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PGCLIENTENCODING = 'UTF8'
$psql = 'C:\Program Files\PostgreSQL\18\bin\psql.exe'
$db   = if ($env:HAPPEN_DB) { $env:HAPPEN_DB } else { 'happen_demo' }
$conn = @('-w', '-h', 'localhost', '-U', 'postgres', '-d', $db)
$out  = if ($env:HAPPEN_EXPORT) { $env:HAPPEN_EXPORT } else { Join-Path $PSScriptRoot '..\..\docs\data\dashboards' }
New-Item -ItemType Directory -Force $out | Out-Null

function Export-Json([string]$name, [string]$sqlFile) {
    $t = Get-Date
    $json = (& $psql @conn -q -At -v ON_ERROR_STOP=1 -f (Join-Path $PSScriptRoot $sqlFile) | Where-Object { $_ -ne 'SET' }) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "export $name failed" }
    $path = Join-Path $out $name
    [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
    "{0,-28} {1,10:N0} bytes {2,6:N0}s" -f $name, (Get-Item $path).Length, ((Get-Date) - $t).TotalSeconds
}

Export-Json 'executive.json' 'E01_executive_scorecard.sql'
