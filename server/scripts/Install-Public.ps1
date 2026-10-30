$ErrorActionPreference='Stop'
$serverRoot=Split-Path -Parent $PSScriptRoot
$record=Get-Content -LiteralPath (Join-Path $serverRoot 'docs\cloudflared-provenance.json') -Raw | ConvertFrom-Json
$folder=Join-Path $serverRoot '.tools\cloudflared'
New-Item -ItemType Directory -Path $folder -Force | Out-Null
$exe=Join-Path $folder 'cloudflared.exe'
if(-not(Test-Path -LiteralPath $exe)){Invoke-WebRequest $record.url -OutFile $exe -TimeoutSec 180}
if((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant() -ne $record.sha256){throw 'Tunnel binary differs from pinned official asset digest. Do not execute.'}
& $exe '--version'
if($LASTEXITCODE -ne 0){throw 'Tunnel runtime verification failed.'}
Write-Output 'Pinned project-private tunnel binary ready. No service or firewall was changed.'
