param([int]$Port = 55432)
$ErrorActionPreference = 'Stop'
$serverRoot = Split-Path -Parent $PSScriptRoot
$privateRoot = Join-Path $serverRoot '.local'
$bin = Join-Path $serverRoot '.tools\postgresql\bin'
if (-not (Test-Path -LiteralPath (Join-Path $bin 'initdb.exe'))) { throw 'Stage the pinned official PostgreSQL binaries first; see README.' }
New-Item -ItemType Directory -Path $privateRoot -Force | Out-Null
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
& icacls.exe $privateRoot '/inheritance:r' '/grant:r' "${identity}:(OI)(CI)F" 'SYSTEM:(OI)(CI)F' | Out-Null
if($LASTEXITCODE -ne 0) {throw 'Could not restrict private configuration permissions.'}
$settingsPath = Join-Path $privateRoot 'runtime.json'
if (-not (Test-Path -LiteralPath $settingsPath)) {
    function New-Secret { 'Fv9!' + [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24)) }
    $ownerPassword = New-Secret
    $apiPassword = New-Secret
    $settings = [ordered]@{
        ConnectionStrings = @{Database="Host=127.0.0.1;Port=$Port;Database=fruitvision;Username=fv_api;Password=$apiPassword;Maximum Pool Size=20;Timeout=5;Command Timeout=15"}
        LocalAdminConnection="Host=127.0.0.1;Port=$Port;Database=postgres;Username=fv_owner;Password=$ownerPassword;Timeout=5"
        MigrationConnection="Host=127.0.0.1;Port=$Port;Database=fruitvision;Username=fv_owner;Password=$ownerPassword;Timeout=5"
        Demo=@{Enabled=$true;Password=(New-Secret)}
        Database=@{AutoMigrate=$false}
        Cors=@{Origins=@('http://localhost:5173')}
    }
    $settings | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $settingsPath -Encoding utf8
    @('admin','producer','trader','consumer') | ForEach-Object {
        [pscustomobject]@{Email="$_@fruitvision.test";Password=$settings.Demo.Password;IsSyntheticDemo=$true}
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $privateRoot 'demo-accounts.json') -Encoding utf8
}
$settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
$pgdata = Join-Path $privateRoot 'postgres-data'
if (-not (Test-Path -LiteralPath (Join-Path $pgdata 'PG_VERSION'))) {
    $ownerPassword = ($settings.LocalAdminConnection -split 'Password=')[1].Split(';')[0]
    $pwfile = Join-Path $privateRoot 'postgres-init.pw'
    Set-Content -LiteralPath $pwfile -Value $ownerPassword -NoNewline -Encoding utf8
    & (Join-Path $bin 'initdb.exe') '-D' $pgdata '-U' 'fv_owner' '-A' 'scram-sha-256' "--pwfile=$pwfile" '-E' 'UTF8' '--locale=C' | Out-Null
    if($LASTEXITCODE -ne 0) {throw 'initdb failed; do not overwrite the retained cluster.'}
    Add-Content -LiteralPath (Join-Path $pgdata 'postgresql.conf') -Value "`nlisten_addresses='127.0.0.1'`nport=$Port`nshared_buffers='128MB'`nmax_connections=40`nwork_mem='4MB'`njit=off`nlog_statement='none'"
}
& (Join-Path $bin 'pg_ctl.exe') 'status' '-D' $pgdata | Out-Null
if($LASTEXITCODE -ne 0) {
    $pgArguments=@('start','-D',('"'+$pgdata+'"'),'-l',('"'+(Join-Path $privateRoot 'postgres.log')+'"'),'-w','-t','30')
    # Redirect to files: pg_ctl's detached Windows child must not inherit a pipe
    # whose open handle would keep PowerShell's native pipeline waiting forever.
    $launcher=Start-Process -FilePath (Join-Path $bin 'pg_ctl.exe') -ArgumentList $pgArguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $privateRoot 'pg-start.stdout.log') -RedirectStandardError (Join-Path $privateRoot 'pg-start.stderr.log')
    if(-not $launcher.WaitForExit(35000)) {throw 'PostgreSQL launcher timed out; inspect retained logs before retrying.'}
    if($launcher.ExitCode -ne 0) {throw 'PostgreSQL did not start; inspect .local/postgres.log.'}
}
$ownerPassword = ($settings.LocalAdminConnection -split 'Password=')[1].Split(';')[0]
$apiPassword = ($settings.ConnectionStrings.Database -split 'Password=')[1].Split(';')[0]
$previousPgPassword = $env:PGPASSWORD
try {
    $env:PGPASSWORD = $ownerPassword
    $existing = & (Join-Path $bin 'psql.exe') '-h' '127.0.0.1' '-p' $Port '-U' 'fv_owner' '-d' 'postgres' '-At' '-c' "SELECT count(*) FROM pg_roles WHERE rolname='fv_api'"
    if($LASTEXITCODE -ne 0) {throw 'Could not authenticate the private PostgreSQL cluster.'}
    if($existing.Trim() -eq '0') {
        "CREATE ROLE fv_api LOGIN PASSWORD '$apiPassword' NOSUPERUSER NOCREATEDB NOCREATEROLE;" | & (Join-Path $bin 'psql.exe') '-h' '127.0.0.1' '-p' $Port '-U' 'fv_owner' '-d' 'postgres' '-v' 'ON_ERROR_STOP=1' | Out-Null
        if($LASTEXITCODE -ne 0) {throw 'Runtime role creation failed.'}
    }
    $db = & (Join-Path $bin 'psql.exe') '-h' '127.0.0.1' '-p' $Port '-U' 'fv_owner' '-d' 'postgres' '-At' '-c' "SELECT count(*) FROM pg_database WHERE datname='fruitvision'"
    if($db.Trim() -eq '0') {
        & (Join-Path $bin 'createdb.exe') '-h' '127.0.0.1' '-p' $Port '-U' 'fv_owner' '-O' 'fv_owner' 'fruitvision'
        if($LASTEXITCODE -ne 0) {throw 'Database creation failed.'}
    }
} finally { $env:PGPASSWORD = $previousPgPassword }
Write-Output 'Private PostgreSQL cluster is ready. Credentials are restricted in server/.local; no passwords printed.'
