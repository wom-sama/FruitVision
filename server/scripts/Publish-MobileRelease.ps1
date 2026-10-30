param(
    [Parameter(Mandatory)][string]$ReleaseDirectory,
    [Parameter(Mandatory)][string]$VerificationReceipt,
    [Parameter(Mandatory)][ValidatePattern('\A[0-9A-Za-z][0-9A-Za-z._-]{0,79}\z')][string]$VersionName,
    [Parameter(Mandatory)][ValidateRange(1,2147483647)][int]$VersionCode,
    [ValidateRange(1,2147483647)][int]$MinimumSupportedVersionCode = 6002,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Notes,
    [string]$RootPath,
    [switch]$Configure
)
$ErrorActionPreference = 'Stop'
$serverRoot = Split-Path -Parent $PSScriptRoot
$privateRoot = [IO.Path]::GetFullPath((Join-Path $serverRoot '.local'))
$abis = @('arm64-v8a','armeabi-v7a','x86_64')
$package = 'vn.mangodemo.mango_offline'
if ($MinimumSupportedVersionCode -gt $VersionCode) { throw 'Minimum supported version cannot exceed the published version.' }
if ($Notes.Length -gt 2000 -or @($Notes.ToCharArray() | Where-Object { [char]::IsControl($_) -and $_ -notin @("`r","`n","`t") }).Count) {
    throw 'Notes must contain at most 2000 characters without unsafe control characters.'
}

function FullPath([string]$Path) { [IO.Path]::GetFullPath($Path) }
function Assert-Within([string]$Path,[string]$Boundary) {
    $value = FullPath $Path
    $base = (FullPath $Boundary).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    if (-not $value.StartsWith($base + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'A filesystem target escapes its explicitly permitted directory.'
    }
    return $value
}
function Assert-NoReparse([string]$Path,[string]$Boundary) {
    $current = FullPath $Path
    $base = FullPath $Boundary
    while ($current.Length -ge $base.Length) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Symbolic links and junctions are not accepted for release publication.'
            }
        }
        if ($current.Equals($base,[StringComparison]::OrdinalIgnoreCase)) { break }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
}
function Read-Json([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-Item -LiteralPath $Path).Length -gt 131072) {
        throw 'A required JSON receipt/manifest is missing or exceeds the bounded size.'
    }
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
}
function Manifest([string]$Path) {
    $value = Read-Json $Path
    if ($value.schemaVersion -ne 1 -or $value.packageName -cne $package -or
        $value.versionCode -isnot [long] -and $value.versionCode -isnot [int]) { throw 'Existing manifest is not a supported mobile release.' }
    # Preserve the exact ISO timestamp independently of PowerShell's JSON date conversion.
    $document = [Text.Json.JsonDocument]::Parse([IO.File]::ReadAllText($Path))
    try { $value.publishedAt = $document.RootElement.GetProperty('publishedAt').GetString() }
    finally { $document.Dispose() }
    return $value
}
function Same-Json($First,$Second) {
    ($First | ConvertTo-Json -Depth 12 -Compress) -ceq ($Second | ConvertTo-Json -Depth 12 -Compress)
}
function Check-Artifact([string]$Path,$Artifact) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or
        (Get-Item -LiteralPath $Path).Length -ne $Artifact.sizeBytes -or
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Artifact.sha256) {
        throw 'APK bytes differ from the verified immutable release artifact.'
    }
}

$release = (Resolve-Path -LiteralPath $ReleaseDirectory -ErrorAction Stop).Path
if (-not (Test-Path -LiteralPath $release -PathType Container)) { throw 'ReleaseDirectory must be a directory.' }
Assert-NoReparse $release $release
$receiptPath = (Resolve-Path -LiteralPath $VerificationReceipt -ErrorAction Stop).Path
$receipt = Read-Json $receiptPath
if ($receipt.allPassed -isnot [bool] -or -not $receipt.allPassed -or @($receipt.artifacts).Count -ne 3) {
    throw 'A trusted successful receipt containing exactly three APK artifacts is required.'
}
$receiptHash = (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
$artifacts = @()
$sources = @{}
$signer = $null
foreach ($abi in $abis) {
    $matches = @($receipt.artifacts | Where-Object { $_.abi -ceq $abi })
    if ($matches.Count -ne 1) { throw 'Receipt must contain each known ABI exactly once.' }
    $row = $matches[0]
    if ($row.version -cne "$VersionName+$VersionCode" -or $row.v2Signature -isnot [bool] -or -not $row.v2Signature -or
        $row.sha256 -isnot [string] -or $row.sha256 -notmatch '\A[0-9a-fA-F]{64}\z' -or
        $row.signerSha256 -isnot [string] -or $row.signerSha256 -notmatch '\A[0-9a-fA-F]{64}\z' -or
        ($row.bytes -isnot [long] -and $row.bytes -isnot [int]) -or $row.bytes -lt 1 -or $row.bytes -gt 83886080 -or
        $row.path -isnot [string] -or [string]::IsNullOrWhiteSpace($row.path)) {
        throw 'Receipt version, signature assertion, signer, byte count or SHA-256 is invalid.'
    }
    $rowSigner = $row.signerSha256.ToLowerInvariant()
    if ($signer -and $signer -cne $rowSigner) { throw 'All three verified APKs must use the same signer.' }
    $signer = $rowSigner
    $source = if ([IO.Path]::IsPathFullyQualified($row.path)) { FullPath $row.path } else { FullPath (Join-Path $release $row.path) }
    $source = Assert-Within $source $release
    Assert-NoReparse $source $release
    if ([IO.Path]::GetExtension($source) -ine '.apk') { throw 'A verified source artifact must be an APK file.' }
    $artifact = [ordered]@{abi=$abi;fileName="app-$abi-release.apk";sizeBytes=[long]$row.bytes;sha256=$row.sha256.ToLowerInvariant()}
    Check-Artifact $source $artifact
    $sources[$abi] = $source
    $artifacts += $artifact
}

if (-not $RootPath) { $RootPath = Join-Path $privateRoot 'mobile-releases' }
if (-not [IO.Path]::IsPathFullyQualified($RootPath)) { throw 'RootPath must be fully qualified.' }
$root = Assert-Within (FullPath $RootPath) $privateRoot
Assert-NoReparse $root $privateRoot
$settingsPath = Join-Path $privateRoot 'runtime.json'
$settings = $null
$configurationNeeded = $false
if ($Configure) {
    Assert-NoReparse $settingsPath $privateRoot
    $settings = Read-Json $settingsPath
    $registered = [string]$settings.MobileUpdates.RootPath
    if ($registered) {
        if (-not [IO.Path]::IsPathFullyQualified($registered) -or -not (FullPath $registered).Equals($root,[StringComparison]::OrdinalIgnoreCase)) {
            throw 'Existing MobileUpdates.RootPath differs; this CLI never silently reconfigures an active release store.'
        }
    } else { $configurationNeeded = $true }
}
New-Item -ItemType Directory -Path $root -Force | Out-Null
$lockPath = Assert-Within (Join-Path $root '.publish.lock') $root
Assert-NoReparse $lockPath $privateRoot
try { $publicationLock = [IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
catch { throw 'Another publisher owns this release root; no publication was attempted.' }
$stage = $null
$idempotent = $false
try {
    $latestPath = Assert-Within (Join-Path $root 'manifest.json') $root
    Assert-NoReparse $latestPath $privateRoot
    $latest = if (Test-Path -LiteralPath $latestPath) { Manifest $latestPath } else { $null }
    if ($latest -and $VersionCode -lt $latest.versionCode) { throw 'Publishing an older version would roll back the latest release and is forbidden.' }
    $versionDirectory = Assert-Within (Join-Path $root ([string]$VersionCode)) $root
    Assert-NoReparse $versionDirectory $privateRoot
    if ($latest -and $latest.versionCode -eq $VersionCode -and -not (Test-Path -LiteralPath $versionDirectory -PathType Container)) {
        throw 'Latest manifest points to a missing immutable version directory; inspect the store before publishing.'
    }
    $snapshotPath = Assert-Within (Join-Path $versionDirectory 'manifest.json') $versionDirectory
    $proofPath = Assert-Within (Join-Path $versionDirectory '.verification-receipt.sha256') $versionDirectory
    $candidate = [ordered]@{schemaVersion=1;packageName=$package;versionName=$VersionName;versionCode=$VersionCode;
        minimumSupportedVersionCode=$MinimumSupportedVersionCode;notes=$Notes;publishedAt=[DateTimeOffset]::UtcNow.ToString('o');artifacts=$artifacts}
    if (Test-Path -LiteralPath $versionDirectory) {
        Assert-NoReparse $snapshotPath $privateRoot
        Assert-NoReparse $proofPath $privateRoot
        $snapshot = Manifest $snapshotPath
        $candidate.publishedAt = $snapshot.publishedAt
        if (-not (Same-Json $candidate $snapshot) -or -not (Test-Path -LiteralPath $proofPath -PathType Leaf) -or
            [IO.File]::ReadAllText($proofPath).Trim() -cne $receiptHash) { throw 'Published version is immutable; metadata or verification receipt differs.' }
        foreach ($artifact in $artifacts) {
            $existing = Assert-Within (Join-Path $versionDirectory $artifact.fileName) $versionDirectory
            Assert-NoReparse $existing $privateRoot
            Check-Artifact $existing $artifact
        }
        $idempotent = $true
    } else {
        $stage = Assert-Within (Join-Path $root ('.staging-' + [Guid]::NewGuid().ToString('N'))) $root
        Assert-NoReparse $stage $privateRoot
        [IO.Directory]::CreateDirectory($stage) | Out-Null
        foreach ($artifact in $artifacts) {
            $target = Assert-Within (Join-Path $stage $artifact.fileName) $stage
            [IO.File]::Copy($sources[$artifact.abi],$target,$false)
            Check-Artifact $target $artifact
        }
        [IO.File]::WriteAllText((Join-Path $stage 'manifest.json'),($candidate | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $stage '.verification-receipt.sha256'),$receiptHash,[Text.UTF8Encoding]::new($false))
        # The absolute source/target were checked under this private root; never move/delete an enumerated path through another shell.
        $null = Assert-Within $stage $root
        $null = Assert-Within $versionDirectory $root
        Assert-NoReparse $stage $privateRoot
        Assert-NoReparse $versionDirectory $privateRoot
        [IO.Directory]::Move($stage,$versionDirectory)
        $stage = $null
    }
    if ($latest -and $latest.versionCode -eq $VersionCode -and -not (Same-Json $candidate $latest)) {
        throw 'Latest manifest already claims this version with different immutable metadata.'
    }
    if (-not $latest -or $latest.versionCode -ne $VersionCode) {
        $temporaryManifest = Assert-Within (Join-Path $root ('.latest-' + [Guid]::NewGuid().ToString('N') + '.tmp')) $root
        [IO.File]::Copy($snapshotPath,$temporaryManifest,$false)
        if ((Get-FileHash -LiteralPath $temporaryManifest).Hash -ne (Get-FileHash -LiteralPath $snapshotPath).Hash) { throw 'Latest-manifest staging differs from the version snapshot.' }
        if (Test-Path -LiteralPath $latestPath) { [IO.File]::Replace($temporaryManifest,$latestPath,[NullString]::Value) }
        else { [IO.File]::Move($temporaryManifest,$latestPath) }
    }
    if ($configurationNeeded) {
        $backup = Assert-Within (Join-Path $privateRoot ('runtime.before-mobile-updates-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '.json')) $privateRoot
        [IO.File]::Copy($settingsPath,$backup,$false)
        if (-not $settings.MobileUpdates) { $settings.MobileUpdates = [ordered]@{} }
        $settings.MobileUpdates.RootPath = $root
        $temporarySettings = Assert-Within (Join-Path $privateRoot ('runtime-mobile-updates-' + [Guid]::NewGuid().ToString('N') + '.tmp')) $privateRoot
        [IO.File]::WriteAllText($temporarySettings,($settings | ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
        [IO.File]::Replace($temporarySettings,$settingsPath,[NullString]::Value)
    }
    [ordered]@{published=$true;versionCode=$VersionCode;versionName=$VersionName;artifactCount=3;idempotent=$idempotent;
        rootPath=$root;configurationChanged=$configurationNeeded;restartRequired=$configurationNeeded;
        verification='Trusted operator receipt plus copied byte/size/hash checks; this CLI does not independently run Android signature tools.'} | ConvertTo-Json -Depth 4
} catch {
    if ($stage) { Write-Warning 'Publication failed; a private staging directory was retained for inspection. Latest was not intentionally replaced.' }
    throw
} finally { $publicationLock.Dispose() }
