param([switch]$StopDatabase)
$ErrorActionPreference='Stop'
$serverRoot=Split-Path -Parent $PSScriptRoot
$statePath=Join-Path $serverRoot '.local\server-state.json'
if(Test-Path -LiteralPath $statePath){
    $state=Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $process=Get-CimInstance Win32_Process -Filter "ProcessId=$($state.pid)" -ErrorAction SilentlyContinue
    if($process){
        if($process.Name -ne 'dotnet.exe' -or -not $process.CommandLine.Contains($state.dll)){throw 'PID identity changed; refusing to stop an unrelated process.'}
        Stop-Process -Id $state.pid
        Wait-Process -Id $state.pid -Timeout 10 -ErrorAction SilentlyContinue
    }
    $state | Add-Member -NotePropertyName stoppedUtc -NotePropertyValue ([DateTimeOffset]::UtcNow.ToString('o')) -Force
    $state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding utf8
}
if($StopDatabase){
    & (Join-Path $serverRoot '.tools\postgresql\bin\pg_ctl.exe') 'stop' '-D' (Join-Path $serverRoot '.local\postgres-data') '-m' 'fast' '-w' '-t' '30'
    if($LASTEXITCODE -ne 0){throw 'Private database did not stop normally.'}
}
