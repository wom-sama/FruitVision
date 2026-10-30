$ErrorActionPreference='Stop'
$serverRoot=Split-Path -Parent $PSScriptRoot
$toolsRoot=Join-Path $serverRoot '.tools'
New-Item -ItemType Directory -Path $toolsRoot -Force | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
function Expand-CheckedZip([string]$Archive,[string]$Destination,[switch]$Postgres) {
    if(Test-Path -LiteralPath $Destination){throw "Existing target requires inspection: $Destination"}
    New-Item -ItemType Directory -Path $Destination | Out-Null
    $absolute=(Resolve-Path -LiteralPath $Destination).ProviderPath
    $zip=[IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        foreach($entry in $zip.Entries){
            $name=$entry.FullName.Replace('/','\')
            if($Postgres){
                if(-not $name.StartsWith('pgsql\')){continue}
                $name=$name.Substring(6)
                if($name -notmatch '^(bin|lib|share)\\|^(COPYRIGHT|LICENSE)$'){continue}
            }
            if(-not $name){continue}
            if([IO.Path]::IsPathRooted($name) -or ($name.Split('\') -contains '..')){throw 'Unsafe ZIP path.'}
            if((($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000){throw 'ZIP symbolic links are not accepted.'}
            $target=[IO.Path]::GetFullPath((Join-Path $absolute $name))
            if(-not $target.StartsWith($absolute+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'ZIP target escapes runtime folder.'}
            if($name.EndsWith('\')){New-Item -ItemType Directory -Path $target -Force | Out-Null;continue}
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$target,$false)
        }
    } finally {$zip.Dispose()}
}
$downloads=Join-Path $toolsRoot 'downloads'
New-Item -ItemType Directory -Path $downloads -Force | Out-Null
$pgRoot=Join-Path $toolsRoot 'postgresql'
if(-not(Test-Path -LiteralPath (Join-Path $pgRoot 'bin\postgres.exe'))){
    $archive=Join-Path $downloads 'postgresql-windows-x64-binaries.zip'
    if(-not(Test-Path -LiteralPath $archive)){Invoke-WebRequest 'https://get.enterprisedb.com/postgresql/postgresql-18.6-5-windows-x64-binaries.zip' -OutFile $archive -TimeoutSec 300}
    $expected='e2246ba91d22345bc3d017586c09ede52d9df180b1eeb480f050445f1cad84e2'
    if((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected){throw 'PostgreSQL archive differs from the project-pinned HTTPS download; do not extract.'}
    Expand-CheckedZip $archive $pgRoot -Postgres
}
$runtimeRoot=Join-Path $toolsRoot 'dotnet-runtime\staged'
if(-not(Test-Path -LiteralPath (Join-Path $runtimeRoot 'dotnet.exe'))){
    $metadata=Invoke-RestMethod 'https://builds.dotnet.microsoft.com/dotnet/release-metadata/10.0/releases.json'
    $release=@($metadata.releases | Where-Object { $_.'release-version' -eq '10.0.14' })
    $file=@($release[0].aspnetcore.files | Where-Object { $_.rid -eq 'win-x64' -and $_.name -like '*.zip' })
    if($file.Count -ne 1){throw 'Pinned Microsoft runtime asset not found.'}
    $archive=Join-Path $downloads 'aspnetcore-runtime-10.0.14-win-x64.zip'
    if(-not(Test-Path -LiteralPath $archive)){Invoke-WebRequest $file[0].url -OutFile $archive -TimeoutSec 180}
    if((Get-FileHash -LiteralPath $archive -Algorithm SHA512).Hash.ToLowerInvariant() -ne $file[0].hash.ToLowerInvariant()){throw 'Official Microsoft SHA512 verification failed.'}
    Expand-CheckedZip $archive $runtimeRoot
}
& (Join-Path $runtimeRoot 'dotnet.exe') '--list-runtimes'
& (Join-Path $pgRoot 'bin\postgres.exe') '--version'
if($LASTEXITCODE -ne 0){throw 'Runtime verification failed.'}
Write-Output 'Project-private runtimes are available. No global installation or Windows service was changed.'
