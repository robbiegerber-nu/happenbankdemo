# Writes the daily feed folders for the v3.1 demo from feedgen.plan (built by P01_generate_feeds.sql):
#   data/daily_loads/<day>/manifest.json + one CSV per feed
#   data/daily_loads/<day>/late/ and /corrections/   files that arrive that day for an earlier day, with the sender's explanation
#   powershell -File sql\pipeline\generate_feeds.ps1 [-Rebuild]     (-Rebuild re-runs P00 and P01 first)
param([switch]$Rebuild)
$ErrorActionPreference = 'Stop'
$env:PGCLIENTENCODING = 'UTF8'
$psql = 'C:\Program Files\PostgreSQL\18\bin\psql.exe'
$db   = if ($env:HAPPEN_DB) { $env:HAPPEN_DB } else { 'happen_demo' }   # set HAPPEN_DB to work on a copy (rehearsals)
$conn = @('-w', '-h', 'localhost', '-U', 'postgres', '-d', $db)
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$base = Join-Path $root 'data\daily_loads'

if ($Rebuild) {
    foreach ($f in 'P00_setup.sql', 'P01_generate_feeds.sql') {
        & $psql @conn -q -v ON_ERROR_STOP=1 -f (Join-Path $PSScriptRoot $f) | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "$f failed" }
    }
}

$planJson = (& $psql @conn -At -v ON_ERROR_STOP=1 -c @"
SELECT json_agg(json_build_object('arrived', arrived, 'kind', kind, 'fixes', fixes, 'feed', feed, 'file', file_name, 'action', action,
       'query', query, 'expected', expected, 'missing', missing, 'reason', reason, 'cause', cause, 'fix', fix)
       ORDER BY arrived, kind, feed, file_name) FROM feedgen.plan;
"@) -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'could not read feedgen.plan' }
$plan = $planJson | ConvertFrom-Json

if (Test-Path $base) { Remove-Item $base -Recurse -Force }
$utf8 = New-Object System.Text.UTF8Encoding $false
$tmp = Join-Path $env:TEMP 'happen_feed_copy.sql'

foreach ($group in ($plan | Group-Object arrived, kind)) {
    $first = $group.Group[0]
    $sub = switch ($first.kind) { 'Daily' { '' } 'Late' { 'late' } 'Correction' { 'corrections' } }
    $dir = Join-Path (Join-Path $base $first.arrived) $sub
    New-Item -ItemType Directory -Force $dir | Out-Null
    $files = @()
    foreach ($p in $group.Group) {
        $path = Join-Path $dir $p.file
        $rows = 0
        if (-not $p.missing) {
            # \copy must be on one line; a script file avoids PowerShell 5.1 stripping double quotes from arguments
            $copy = "\copy ($($p.query -replace '\s+', ' ')) TO '$($path.Replace('\', '/'))' WITH (FORMAT csv, HEADER)"
            [System.IO.File]::WriteAllText($tmp, $copy, $utf8)
            & $psql @conn -q -v ON_ERROR_STOP=1 -f $tmp | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "writing $path failed" }
            $rows = [System.IO.File]::ReadAllLines($path).Count - 1
        }
        $expected = if ($p.expected) { [int](& $psql @conn -At -c $p.expected) }
                    elseif ($p.missing) { [int](& $psql @conn -At -c "SELECT count(*) FROM ($($p.query)) q") }
                    else { $rows }
        $files += [ordered]@{ feed = $p.feed; file = $p.file; action = $p.action; rows = $expected }
    }
    $manifest = [ordered]@{ kind = $first.kind; arrived_on = $first.arrived }
    $manifest.business_date = if ($first.fixes) { $first.fixes } else { $first.arrived }
    foreach ($k in 'reason', 'cause', 'fix') {
        $v = ($group.Group | Where-Object { $_.$k } | Select-Object -First 1).$k
        if ($v) { $manifest[$k] = $v }
    }
    $manifest.files = $files
    [System.IO.File]::WriteAllText((Join-Path $dir 'manifest.json'), ($manifest | ConvertTo-Json -Depth 5), $utf8)
    "{0} {1,-10} {2} file(s)" -f $first.arrived, $first.kind, $files.Count
}
