$ErrorActionPreference='Stop'
$serverRoot=Split-Path -Parent $PSScriptRoot
$statePath=Join-Path $serverRoot '.local\tunnel-state.json'
if(-not(Test-Path -LiteralPath $statePath)){Write-Output 'No owned tunnel state.';return}
$state=Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
$process=Get-CimInstance Win32_Process -Filter "ProcessId=$($state.pid)" -ErrorAction SilentlyContinue
if($process){if($process.Name -ne 'cloudflared.exe' -or $process.ExecutablePath -ne $state.executable){throw 'Tunnel PID identity changed; no unrelated process will be stopped.'};Stop-Process -Id $state.pid}
$state | Add-Member -NotePropertyName stoppedUtc -NotePropertyValue ([DateTimeOffset]::UtcNow.ToString('o')) -Force
$state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding utf8
Write-Output 'Owned HTTPS tunnel stopped. API and database are unchanged.'
