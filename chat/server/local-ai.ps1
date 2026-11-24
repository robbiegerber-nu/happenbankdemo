# Runs the chat server on this computer with the real AI. The key is typed into a hidden prompt, kept only in this
# window's memory, and gone when the window closes. It is never written to a file or put on a command line.
#   powershell -ExecutionPolicy Bypass -File chat\server\local-ai.ps1 [-MonthlyUsd 1]
param([double]$MonthlyUsd = 1, [int]$Port = 8787, [switch]$Pretend)
$ErrorActionPreference = 'Stop'
$work = if ($env:HAPPEN_CHAT) { $env:HAPPEN_CHAT } else { Join-Path $HOME 'happen-chat' }
$node = 'C:\Program Files\nodejs\node.exe'
& $node (Join-Path $PSScriptRoot 'sync.mjs')
if (Get-ChildItem $work -Filter '.dev.vars*' -Force) { throw "Remove the .dev.vars file in $work first: secrets must not be kept in files." }
if ($Pretend) { $env:FAKE_AI = '1' } else {
    Write-Host ''
    Write-Host 'Paste the Claude API key here and press Enter. Nothing will show as you paste.' -ForegroundColor Cyan
    $s = Read-Host -AsSecureString 'Key'
    $p = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    $k = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($p).Trim()
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p)
    if ($k -notmatch '^sk-ant-') { Write-Host 'That does not look like a Claude API key (it should start with sk-ant-). Nothing was sent.' -ForegroundColor Yellow; exit 1 }
    $env:ANTHROPIC_API_KEY = $k; $k = $null
    Write-Host 'Key received. Starting the server; close this window to stop it and forget the key.' -ForegroundColor Green
}
$env:CLOUDFLARE_INCLUDE_PROCESS_ENV = 'true'; $env:WRANGLER_SEND_METRICS = 'false'
$env:ACCESS_CODE = 'local-test'; $env:SESSION_SECRET = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')
$state = Join-Path $work "local-ai-state-$Port"; if (Test-Path $state) { Remove-Item $state -Recurse -Force }
Set-Location $work
& $node node_modules\wrangler\bin\wrangler.js dev --port $Port --ip 127.0.0.1 --persist-to $state --show-interactive-dev-session=false --log-level error --var ALLOWED_ORIGINS:http://localhost:8768 --var "MONTHLY_USD:$MonthlyUsd" --var QUESTIONS_PER_DAY:200 --var VISITOR_QUESTIONS_PER_DAY:200
