# Generates the column-level Data Dictionary wiki pages from the PostgreSQL catalog
# (table/column comments, types, keys, row counts), so the wiki always matches the database.
#   powershell -File tools\generate_data_dictionary.ps1 [-OutDir wiki-drafts]
param([string]$OutDir = (Join-Path $PSScriptRoot '..\wiki-drafts'))
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8   # psql emits UTF-8
$env:PGCLIENTENCODING = 'UTF8'
$ARROW = [char]0x2192; $DASH = [char]0x2014; $UP = [char]0x2191; $LEFT = [char]0x2190; $DOT = [char]0x00B7
$psql = 'C:\Program Files\PostgreSQL\18\bin\psql.exe'
$conn = @('-w', '-h', 'localhost', '-U', 'postgres', '-d', 'happen_demo', '-At', '-F', "`t")

function Invoke-Sql([string]$sql) {
    $out = & $psql @conn -c $sql
    if ($LASTEXITCODE -ne 0) { throw "psql failed: $sql" }
    return $out
}
function Format-Cell([string]$s) { if ($null -eq $s) { '' } else { $s.Replace('|', '\|').Replace("`n", ' ') } }

$lookup = 'dataset_info','dim_date','dim_time_interval','dim_channel','dim_queue','dim_site','dim_team','dim_agent',
          'dim_region','dim_persona','dim_product','product_launch','launch_reason_impact','dim_contact_reason'

# ---- table metadata ----
$tables = @{}
foreach ($line in Invoke-Sql @"
SELECT c.relname, coalesce(obj_description(c.oid, 'pg_class'), ''), c.relkind
FROM pg_class c WHERE c.relnamespace = 'cc'::regnamespace AND c.relkind IN ('r', 'v') ORDER BY c.relname;
"@) {
    $f = $line -split "`t"
    $tables[$f[0]] = [pscustomobject]@{ Name = $f[0]; Comment = $f[1]; Kind = $f[2]; Rows = $null }
}
foreach ($t in $tables.Values | Where-Object Kind -eq 'r') {
    $t.Rows = [int64](Invoke-Sql "SELECT count(*) FROM cc.$($t.Name);")
}

# ---- column metadata ----
$cols = foreach ($line in Invoke-Sql @"
SELECT c.relname, a.attnum, a.attname, format_type(a.atttypid, a.atttypmod), (NOT a.attnotnull)::text,
       coalesce((SELECT 'PK' FROM pg_constraint k WHERE k.conrelid = c.oid AND k.contype = 'p' AND a.attnum = ANY (k.conkey)), ''),
       coalesce((SELECT string_agg(ft.relname, ', ') FROM pg_constraint k JOIN pg_class ft ON ft.oid = k.confrelid
                 WHERE k.conrelid = c.oid AND k.contype = 'f' AND a.attnum = ANY (k.conkey)), ''),
       coalesce(col_description(c.oid, a.attnum), '')
FROM pg_class c JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
WHERE c.relnamespace = 'cc'::regnamespace AND c.relkind IN ('r', 'v')
ORDER BY c.relname, a.attnum;
"@) {
    $f = $line -split "`t"
    [pscustomobject]@{ Table = $f[0]; Pos = [int]$f[1]; Column = $f[2]; Type = $f[3]; Nullable = ($f[4] -eq 'true');
                       PK = $f[5]; FK = $f[6]; Comment = $f[7] }
}

function New-TableSection($t) {
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("### ``$($t.Name)``")
    [void]$sb.AppendLine()
    if ($t.Comment) { [void]$sb.AppendLine((Format-Cell $t.Comment)); [void]$sb.AppendLine() }
    if ($null -ne $t.Rows) { [void]$sb.AppendLine("**Rows:** $('{0:N0}' -f $t.Rows)"); [void]$sb.AppendLine() }
    [void]$sb.AppendLine('| Column | Type | Key | Nulls | Description |')
    [void]$sb.AppendLine('|---|---|---|---|---|')
    foreach ($c in $cols | Where-Object Table -eq $t.Name | Sort-Object Pos) {
        $key = @(); if ($c.PK) { $key += 'PK' }; if ($c.FK) { $key += "FK $ARROW ``$($c.FK)``" }
        $nulls = if ($t.Kind -eq 'v') { '' } elseif ($c.Nullable) { 'Yes' } else { 'No' }
        [void]$sb.AppendLine("| ``$($c.Column)`` | $($c.Type) | $($key -join " $DOT ") | $nulls | $(Format-Cell $c.Comment) |")
    }
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("[$UP Back to top](#)")
    [void]$sb.AppendLine()
    return $sb.ToString()
}

function Write-Page([string]$file, [string]$title, [string]$intro, $tableNames) {
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("# $title"); [void]$sb.AppendLine()
    [void]$sb.AppendLine($intro); [void]$sb.AppendLine()
    [void]$sb.AppendLine('> *Generated from the database catalog by `tools/generate_data_dictionary.ps1` on ' + (Get-Date -Format 'yyyy-MM-dd') + '. Edit descriptions in `sql/12_column_comments.sql`, not here.*')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('**Tables on this page:** ' + (($tableNames | ForEach-Object { "[$_](#$_)" }) -join " $DOT "))
    [void]$sb.AppendLine()
    foreach ($n in $tableNames) { [void]$sb.Append((New-TableSection $tables[$n])) }
    [void]$sb.AppendLine('---')
    [void]$sb.AppendLine("$LEFT [Data Dictionary overview](Data-Dictionary)")
    $path = Join-Path $OutDir $file
    [System.IO.File]::WriteAllText($path, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
    "wrote $path"
}

$factNames = $tables.Values | Where-Object { $_.Kind -eq 'r' -and $_.Name -notin $lookup } | Sort-Object { -$_.Rows } | ForEach-Object Name
$viewNames = $tables.Values | Where-Object Kind -eq 'v' | Sort-Object Name | ForEach-Object Name

Write-Page 'Data-Dictionary-Lookup-Tables.md' "Data Dictionary $DASH Lookup Tables" `
  'Descriptive tables that facts join to: calendar, time of day, channels, queues, sites, teams, agents, regions, personas, products, launches and contact reasons.' $lookup
Write-Page 'Data-Dictionary-Fact-Tables.md' "Data Dictionary $DASH Fact & Customer Tables" `
  'Event and measurement tables (largest first). Every one has more than 100,000 rows.' $factNames
Write-Page 'Data-Dictionary-Views.md' "Data Dictionary $DASH Dashboard Views" `
  'Ready-to-use views that join the facts to their descriptions. Point a BI tool at these instead of the raw tables.' $viewNames
