# Copies the chat's log, checks new answers, adds new tickets to the private repository, and shows a message if there is anything to review.
#   powershell -ExecutionPolicy Bypass -File chat\qa\daily_check.ps1            run once
#   powershell -ExecutionPolicy Bypass -File chat\qa\daily_check.ps1 -Install   run every day at 9 a.m. (a Windows scheduled task)
#   powershell -ExecutionPolicy Bypass -File chat\qa\daily_check.ps1 -Remove    stop running it
param([switch]$Install, [switch]$Remove, [switch]$Quiet)
$name = 'Happen chat QA check'
if ($Remove) { Unregister-ScheduledTask -TaskName $name -Confirm:$false; "Removed the scheduled task '$name'."; exit 0 }
if ($Install) {
    $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $s = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
    Register-ScheduledTask -TaskName $name -Action $a -Trigger (New-ScheduledTaskTrigger -Daily -At 9am) -Settings $s -Description 'Copies and checks the questions asked of Ask the data.' -Force | Out-Null
    "Installed the scheduled task '$name': every day at 9 a.m., or when the computer is next on."; exit 0
}
$node = 'C:\Program Files\nodejs\node.exe'; $psql = 'C:\Program Files\PostgreSQL\18\bin\psql.exe'
$db = if ($env:HAPPEN_DB) { $env:HAPPEN_DB } else { 'happen_demo' }
function Show-Note([string]$text) { $text; if (-not $Quiet) { (New-Object -ComObject WScript.Shell).Popup($text, 120, 'Ask the data: QA check', 64) | Out-Null } }
& $node (Join-Path $PSScriptRoot 'sync_log.mjs'); if ($LASTEXITCODE -ne 0) { Show-Note 'The question log could not be copied. Run chat\qa\sync_log.mjs to see why.'; exit 1 }
& $node (Join-Path $PSScriptRoot 'verify_log.mjs'); if ($LASTEXITCODE -ne 0) { Show-Note 'The answers could not be checked. Run chat\qa\verify_log.mjs to see why.'; exit 1 }
& $node (Join-Path $PSScriptRoot 'private_tickets.mjs') --publish --quiet-if-missing; if ($LASTEXITCODE -ne 0) { Show-Note 'New tickets could not be added to the private repository. Run: node chat/qa/private_tickets.mjs --publish'; exit 1 }
$row = & $psql -w -h localhost -U postgres -d $db -At -F '|' -v ON_ERROR_STOP=1 -c "SELECT (SELECT count(*) FROM qa.chat_ticket WHERE status = 'new'), (SELECT count(*) FROM qa.v_chat_ticket WHERE response_owed AND due <= (now() AT TIME ZONE 'America/Chicago')::date), (SELECT count(*) FROM qa.v_chat_verdict WHERE verdict IN ('mismatch', 'error') AND asked_central > now() AT TIME ZONE 'America/Chicago' - interval '7 days'), (SELECT count(*) FROM qa.v_chat_verdict WHERE label = 'Check the figures' AND asked_central > now() AT TIME ZONE 'America/Chicago' - interval '7 days')"
if ($LASTEXITCODE -ne 0) { Show-Note 'The results could not be read from Postgres.'; exit 1 }
$n = $row -split '\|'
if (($n | Measure-Object -Sum).Sum -gt 0) { Show-Note "New tickets: $($n[0])`nResponses due today or overdue: $($n[1])`nFigures that differ from the database (7 days): $($n[2])`nAnswers with a figure not in the results (7 days): $($n[3])`n`nRun: node chat/qa/ticket.mjs" } else { 'Nothing to review.' }
