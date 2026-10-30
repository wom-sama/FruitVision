$ErrorActionPreference='Stop'
$serverRoot=Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'Start-Server.ps1')
$privateRoot=Join-Path $serverRoot '.local'
$statePath=Join-Path $privateRoot 'tunnel-state.json'
$provenance=Get-Content -LiteralPath (Join-Path $serverRoot 'docs\cloudflared-provenance.json') -Raw | ConvertFrom-Json
$exe=Join-Path $serverRoot '.tools\cloudflared\cloudflared.exe'
if((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant() -ne $provenance.sha256){throw 'Tunnel binary changed; do not run.'}
if(Test-Path -LiteralPath $statePath){
    $state=Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $existing=Get-CimInstance Win32_Process -Filter "ProcessId=$($state.pid)" -ErrorAction SilentlyContinue
    if($existing -and $existing.ExecutablePath -eq $exe){
        $health=Invoke-RestMethod "$($state.publicUrl)/health/ready" -TimeoutSec 10
        if($health.status -ne 'ready'){throw 'Existing tunnel is not ready; inspect it, no duplicate will be started.'}
        @("FruitVision HTTPS tạm thời: $($state.publicUrl)","Web: $($state.publicUrl)/index.html","Swagger: $($state.publicUrl)/v1/index.html","OpenAPI: $($state.publicUrl)/openapi/v1.json","Link thay đổi khi tạo tunnel mới. Máy tính và backend phải tiếp tục chạy. Không dùng Render.") | Set-Content -LiteralPath (Join-Path $serverRoot 'PUBLIC_URL.txt') -Encoding utf8
        Write-Output "Verified existing FruitVision HTTPS tunnel: $($state.publicUrl)";return
    }
}
if(Get-NetTCPConnection -LocalPort 20242 -State Listen -ErrorAction SilentlyContinue){throw 'Tunnel metrics port is already owned; no foreign process will be stopped.'}
$stdout=Join-Path $privateRoot 'tunnel.stdout.log';$stderr=Join-Path $privateRoot 'tunnel.stderr.log'
$process=Start-Process -FilePath $exe -ArgumentList @('tunnel','--url','http://127.0.0.1:5098','--no-autoupdate','--protocol','http2','--metrics','127.0.0.1:20242') -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
$state=[ordered]@{pid=$process.Id;executable=$exe;startedUtc=[DateTimeOffset]::UtcNow.ToString('o');origin='http://127.0.0.1:5098';publicUrl=$null;temporary=$true;hostname_changes_on_new_tunnel=$true}
$state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding utf8
$url=$null
for($i=0;$i -lt 60;$i++){
    if($process.HasExited){throw 'Tunnel worker exited; inspect retained tunnel logs before any retry.'}
    $text=(Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue)+(Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue)
    $match=[regex]::Match($text,'https://[a-z0-9-]+\.trycloudflare\.com')
    if($match.Success){$url=$match.Value;break}
    Start-Sleep -Milliseconds 500
}
if(-not $url){throw 'No public hostname before deadline; inspect retained PID/logs, do not start a duplicate.'}
$state.publicUrl=$url
$state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding utf8
$ready=$false
$readinessDeadline=[DateTimeOffset]::UtcNow.AddSeconds(90)
while([DateTimeOffset]::UtcNow -lt $readinessDeadline){
    try{$health=Invoke-RestMethod "$url/health/ready" -TimeoutSec 5;if($health.status -eq 'ready'){$ready=$true;break}}catch{}
    Start-Sleep -Seconds 1
}
if(-not $ready){throw 'Public hostname issued but HTTPS readiness not verified; inspect network, no duplicate tunnel.'}
@("FruitVision HTTPS tạm thời: $url","Web: $url/index.html","Swagger: $url/v1/index.html","OpenAPI: $url/openapi/v1.json","Link thay đổi khi tạo tunnel mới. Máy tính và backend phải tiếp tục chạy. Không dùng Render.") | Set-Content -LiteralPath (Join-Path $serverRoot 'PUBLIC_URL.txt') -Encoding utf8
Write-Output "Public HTTPS API is reachable: $url"
