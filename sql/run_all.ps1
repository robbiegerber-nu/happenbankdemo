# Rebuilds the happen_demo database from scratch (about 20-30 minutes).
# Requires the password for user "postgres" in %APPDATA%\postgresql\pgpass.conf
$ErrorActionPreference = 'Stop'
$psql = 'C:\Program Files\PostgreSQL\18\bin\psql.exe'
$dir  = $PSScriptRoot
$conn = @('-w', '-h', 'localhost', '-U', 'postgres')

& $psql @conn -d postgres -q -f "$dir\00_create_database.sql"
if ($LASTEXITCODE -ne 0) { throw "00_create_database.sql failed" }

$scripts = '01_schema.sql','02_dimensions.sql','03_customers.sql','04_workforce.sql','05_demand.sql',
           '06_contacts.sql','06b_contact_final.sql','06c_adherence_refine.sql','06d_schedule_drift.sql','07_ivr_surveys_complaints.sql','07b_customer_products.sql','08_aggregates.sql',
           '09_constraints_indexes.sql','10_views.sql','11_cleanup.sql','12_column_comments.sql'
foreach ($s in $scripts) {
    $t = Get-Date
    & $psql @conn -d happen_demo -q -v ON_ERROR_STOP=1 -f "$dir\$s" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "$s failed" }
    "{0,-45} {1,6:N0}s" -f $s, ((Get-Date) - $t).TotalSeconds
}
& $psql @conn -d happen_demo -f "$dir\99_validate.sql"
