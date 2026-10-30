param([int]$Port = 5098)
$ErrorActionPreference='Stop'
$serverRoot=Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'Initialize-Local.ps1')
$privateRoot=Join-Path $serverRoot '.local'
$configPath=Join-Path $privateRoot 'runtime.json'
$settings=Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$dotnet=Join-Path $serverRoot '.tools\dotnet-runtime\staged\dotnet.exe'
if(-not(Test-Path -LiteralPath $dotnet)){throw 'Stage the pinned 10.0.14 runtime first; see docs/runtime-provenance.json.'}
$dll=Join-Path $serverRoot 'src\FruitVision.Api\bin\Release\net10.0\FruitVision.Api.dll'
if(-not (Test-Path -LiteralPath $dll)){throw 'Build Release first: dotnet build src/FruitVision.Api -c Release'}
$statePath=Join-Path $privateRoot 'server-state.json'
if(Test-Path -LiteralPath $statePath){
    $state=Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $existing=Get-CimInstance Win32_Process -Filter "ProcessId=$($state.pid)" -ErrorAction SilentlyContinue
    if($existing -and $existing.CommandLine.Contains($dll)){Write-Output "FruitVision already owns PID $($state.pid); no duplicate started.";return}
}
if(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue){throw "Port $Port is already owned; no process will be stopped."}
$oldConfig=$env:FRUITVISION_CONFIG;$oldEnvironment=$env:ASPNETCORE_ENVIRONMENT;$oldConnection=$env:ConnectionStrings__Database;$oldUrls=$env:ASPNETCORE_URLS
try {
    $env:FRUITVISION_CONFIG=$configPath;$env:ASPNETCORE_ENVIRONMENT='Development'
    $env:ConnectionStrings__Database=$settings.MigrationConnection
    & $dotnet $dll '--migrate' *> (Join-Path $privateRoot 'migration.log')
    if($LASTEXITCODE -ne 0){throw 'Migration failed; inspect private migration.log.'}
    $previousPgPassword=$env:PGPASSWORD
    try {
        $env:PGPASSWORD=($settings.LocalAdminConnection -split 'Password=')[1].Split(';')[0]
        $sql=@'
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO fv_api;
GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO fv_api;
GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA public TO fv_api;
ALTER DEFAULT PRIVILEGES FOR ROLE fv_owner IN SCHEMA public GRANT SELECT,INSERT,UPDATE,DELETE ON TABLES TO fv_api;
ALTER DEFAULT PRIVILEGES FOR ROLE fv_owner IN SCHEMA public GRANT USAGE,SELECT ON SEQUENCES TO fv_api;
'@
        $sql | & (Join-Path $serverRoot '.tools\postgresql\bin\psql.exe') '-w' '-h' '127.0.0.1' '-p' '55432' '-U' 'fv_owner' '-d' 'fruitvision' '-v' 'ON_ERROR_STOP=1' *> (Join-Path $privateRoot 'database-grants.log')
        if($LASTEXITCODE -ne 0){throw 'Runtime DB grants failed.'}
    } finally {$env:PGPASSWORD=$previousPgPassword}
    $env:ConnectionStrings__Database=$settings.ConnectionStrings.Database
    $env:ASPNETCORE_URLS="http://127.0.0.1:$Port"
    $process=Start-Process -FilePath $dotnet -ArgumentList ('"'+$dll+'"') -WorkingDirectory $serverRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $privateRoot 'api.stdout.log') -RedirectStandardError (Join-Path $privateRoot 'api.stderr.log')
    [ordered]@{pid=$process.Id;dll=$dll;url=$env:ASPNETCORE_URLS;startedUtc=[DateTimeOffset]::UtcNow.ToString('o');scope='accounts-and-interactions';databaseRole='fv_api';publicInternet=$false} | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding utf8
    $ready=$false
    for($i=0;$i -lt 30;$i++){
        if($process.HasExited){throw 'API worker exited; inspect api.stderr.log.'}
        try {$r=Invoke-RestMethod "$($env:ASPNETCORE_URLS)/health/ready" -TimeoutSec 2;if($r.status -eq 'ready'){$ready=$true;break}} catch {}
        Start-Sleep -Milliseconds 500
    }
    if(-not $ready){throw 'API readiness deadline exceeded; retained PID and logs require diagnosis, no auto-retry.'}
    Write-Output "FruitVision ready at $($env:ASPNETCORE_URLS). Demo accounts: .local/demo-accounts.json (private)."
} finally {
    $env:FRUITVISION_CONFIG=$oldConfig;$env:ASPNETCORE_ENVIRONMENT=$oldEnvironment;$env:ConnectionStrings__Database=$oldConnection;$env:ASPNETCORE_URLS=$oldUrls
}
