# Tests are appended to this file by subsequent tasks.
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repoRoot 'src\SumatraManagedUpdate.Common.psm1'
if (Test-Path -LiteralPath $modulePath) {
    Import-Module $modulePath -Force
}

Write-Host '--- ConvertTo-SumatraVersion ---'
Assert-Equal -Actual (ConvertTo-SumatraVersion -TagName '3.6.1rel') -Expected '3.6.1' -Message 'strips trailing rel suffix without separator'
Assert-Equal -Actual (ConvertTo-SumatraVersion -TagName '3.5.2-rel') -Expected '3.5.2' -Message 'strips trailing -rel suffix'
Assert-Equal -Actual (ConvertTo-SumatraVersion -TagName '3.4.6')    -Expected '3.4.6' -Message 'plain semver passes through'
Assert-Equal -Actual (ConvertTo-SumatraVersion -TagName 'v3.3.3')   -Expected '3.3.3' -Message 'strips leading v'
Assert-Throws -ScriptBlock { ConvertTo-SumatraVersion -TagName '' }            -Message 'empty tag throws'      -ExpectedMessageLike '*tag*'
Assert-Throws -ScriptBlock { ConvertTo-SumatraVersion -TagName 'prerel-3.6-1' } -Message 'prerel tag throws'    -ExpectedMessageLike '*not a release tag*'
Assert-Throws -ScriptBlock { ConvertTo-SumatraVersion -TagName 'just-text' }   -Message 'non-numeric throws'   -ExpectedMessageLike '*numeric*'

Write-Host '--- Resolve-SumatraInstallerUrl ---'
Assert-Equal -Actual (Resolve-SumatraInstallerUrl -Version '3.6.1') -Expected 'https://www.sumatrapdfreader.org/dl/rel/3.6.1/SumatraPDF-3.6.1-64-install.exe' -Message 'constructs current pattern'
Assert-Equal -Actual (Resolve-SumatraInstallerUrl -Version '3.3.3') -Expected 'https://www.sumatrapdfreader.org/dl/rel/3.3.3/SumatraPDF-3.3.3-64-install.exe' -Message 'works for older versions'
Assert-Throws -ScriptBlock { Resolve-SumatraInstallerUrl -Version '' }       -Message 'empty version throws'
Assert-Throws -ScriptBlock { Resolve-SumatraInstallerUrl -Version 'foo bar' } -Message 'invalid version throws' -ExpectedMessageLike '*numeric*'

Assert-Equal -Actual (Resolve-SumatraInstallerFileName -Version '3.6.1') -Expected 'SumatraPDF-3.6.1-64-install.exe' -Message 'file name follows version'

Write-Host '--- Get-SumatraLatestRelease ---'

$validRelease = [pscustomobject]@{ tag_name = '3.6.1rel'; published_at = '2026-04-06T13:47:05Z'; draft = $false; prerelease = $false }
$result = Get-SumatraLatestRelease -Response $validRelease
Assert-Equal -Actual $result.Version     -Expected '3.6.1'                  -Message 'normalizes tag'
Assert-Equal -Actual $result.TagName     -Expected '3.6.1rel'               -Message 'preserves raw tag'
Assert-Equal -Actual $result.PublishedAt -Expected '2026-04-06T13:47:05Z' -Message 'preserves published_at'

$prereleaseResp = [pscustomobject]@{ tag_name = '3.7.0rel'; published_at = '2026-05-01T00:00:00Z'; draft = $false; prerelease = $true }
Assert-Throws -ScriptBlock { Get-SumatraLatestRelease -Response $prereleaseResp } -Message 'rejects prerelease' -ExpectedMessageLike '*prerelease*'

$draftResp = [pscustomobject]@{ tag_name = '3.7.0rel'; published_at = '2026-05-01T00:00:00Z'; draft = $true; prerelease = $false }
Assert-Throws -ScriptBlock { Get-SumatraLatestRelease -Response $draftResp } -Message 'rejects draft' -ExpectedMessageLike '*draft*'

$noTag = [pscustomobject]@{ tag_name = ''; published_at = '2026-05-01T00:00:00Z'; draft = $false; prerelease = $false }
Assert-Throws -ScriptBlock { Get-SumatraLatestRelease -Response $noTag } -Message 'rejects empty tag'

Write-Host '--- Test-SumatraInstallerUrlAvailable ---'

$okResponse  = [pscustomobject]@{ StatusCode = 200; Headers = @{ 'Content-Length' = '6543210' } }
$missing404  = [pscustomobject]@{ StatusCode = 404; Headers = @{ 'Content-Length' = '777' } }
$emptyOk     = [pscustomobject]@{ StatusCode = 200; Headers = @{ 'Content-Length' = '0' } }

$capturedUri = $null
$result = Test-SumatraInstallerUrlAvailable -Url 'https://www.sumatrapdfreader.org/dl/rel/3.6.1/SumatraPDF-3.6.1-64-install.exe' -RequestCommand {
    param($Method, $Uri)
    $script:capturedUri = $Uri
    return $okResponse
}
Assert-Equal -Actual $result -Expected $true -Message 'returns true for 200 with non-zero content-length'

Assert-Throws -ScriptBlock {
    Test-SumatraInstallerUrlAvailable -Url 'https://www.sumatrapdfreader.org/dl/rel/9.9.9/SumatraPDF-9.9.9-64-install.exe' -RequestCommand { param($Method, $Uri) return $missing404 }
} -Message '404 throws' -ExpectedMessageLike '*404*'

Assert-Throws -ScriptBlock {
    Test-SumatraInstallerUrlAvailable -Url 'https://www.sumatrapdfreader.org/dl/rel/3.6.1/SumatraPDF-3.6.1-64-install.exe' -RequestCommand { param($Method, $Uri) return $emptyOk }
} -Message 'zero content-length throws' -ExpectedMessageLike '*content-length*'

# Regression: Invoke-WebRequest in PS7 returns a generic Dictionary<string, IEnumerable<string>>,
# whose .Contains() resolves to the KeyValuePair overload (not a key lookup). Use a generic
# dictionary in this test so the production code path is actually exercised.
$genericHeaders = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.IEnumerable[string]]]::new()
$genericHeaders['Content-Length'] = [string[]]@('1234567')
$genericResponse = [pscustomobject]@{ StatusCode = 200; Headers = $genericHeaders }
$result = Test-SumatraInstallerUrlAvailable -Url 'https://www.sumatrapdfreader.org/dl/rel/3.6.1/SumatraPDF-3.6.1-64-install.exe' -RequestCommand { param($Method, $Uri) return $genericResponse }
Assert-Equal -Actual $result -Expected $true -Message 'reads Content-Length from generic IDictionary<string, IEnumerable<string>> (PS7 IWR shape)'

Write-Host '--- Save-SumatraInstaller ---'

$tempDir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
try {
    $target = Join-Path $tempDir 'SumatraPDF-test-64-install.exe'
    $fakeBytes = [byte[]](1..32)
    $result = Save-SumatraInstaller -Url 'https://example.invalid/x.exe' -Path $target -DownloadCommand {
        param($Url, $Path)
        [IO.File]::WriteAllBytes($Path, $fakeBytes)
    }
    Assert-True -Condition (Test-Path -LiteralPath $target) -Message 'download writes target file'
    Assert-Equal -Actual $result.SizeBytes -Expected 32 -Message 'reports byte count'
    Assert-Equal -Actual $result.Path -Expected $target -Message 'returns target path'
    Assert-True -Condition ($result.Sha256.Length -eq 64) -Message 'reports sha256 hex string'

    $emptyTarget = Join-Path $tempDir 'empty.exe'
    Assert-Throws -ScriptBlock {
        Save-SumatraInstaller -Url 'https://example.invalid/empty.exe' -Path $emptyTarget -DownloadCommand {
            param($Url, $Path)
            [IO.File]::WriteAllBytes($Path, ([byte[]]::new(0)))
        }
    } -Message '0-byte download throws' -ExpectedMessageLike '*empty*'

    $missingTarget = Join-Path $tempDir 'missing.exe'
    Assert-Throws -ScriptBlock {
        Save-SumatraInstaller -Url 'https://example.invalid/missing.exe' -Path $missingTarget -DownloadCommand {
            param($Url, $Path)
            # do nothing — leaves no file behind
        }
    } -Message 'missing file throws' -ExpectedMessageLike '*not produce*'
} finally {
    if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force }
}

Write-Host '--- New-Action1SumatraVersionBody ---'

$body = New-Action1SumatraVersionBody -Version '3.6.1' -DetectedDate '2026-05-05' -PayloadFileName 'SumatraPDF-3.6.1-64-install.exe'
Assert-Equal -Actual $body.version                  -Expected '3.6.1' -Message 'version field'
Assert-Equal -Actual $body.app_name_match           -Expected '^SumatraPDF$' -Message 'app_name_match field'
Assert-Equal -Actual $body.release_date             -Expected '2026-05-05' -Message 'release_date field'
Assert-Equal -Actual $body.silent_install_switches  -Expected '-install -silent -all-users' -Message 'silent switches'
Assert-Equal -Actual $body.success_exit_codes       -Expected '0' -Message 'success exit codes'
Assert-Equal -Actual $body.reboot_exit_codes        -Expected '' -Message 'no reboot exit codes'
Assert-Equal -Actual $body.install_type             -Expected 'exe' -Message 'install_type'
Assert-Equal -Actual $body.EULA_accepted            -Expected 'no' -Message 'EULA field'
Assert-Equal -Actual $body.update_type              -Expected 'Regular Updates' -Message 'update_type'
Assert-Equal -Actual ($body.os -join ',')           -Expected 'Windows 10,Windows 11' -Message 'os list'
Assert-Equal -Actual $body.file_name.Windows_64.name -Expected 'SumatraPDF-3.6.1-64-install.exe' -Message 'binary file name'
Assert-Equal -Actual $body.file_name.Windows_64.type -Expected 'cloud' -Message 'binary type'

Write-Host '--- New-Action1SumatraPackageBody ---'
$pkg = New-Action1SumatraPackageBody -PackageName 'SumatraPDF'
Assert-Equal -Actual $pkg.name     -Expected 'SumatraPDF' -Message 'name'
Assert-Equal -Actual $pkg.vendor   -Expected 'SumatraPDF' -Message 'vendor'
Assert-Equal -Actual $pkg.platform -Expected 'Windows'    -Message 'platform'
Assert-True  -Condition (([string]$pkg.description).Length -gt 0) -Message 'description set'

Write-Host '--- Get-SumatraContainerRuntimeConfig ---'

$envHashHappy = @{
    ACTION1_CLIENT_ID = 'cid'
    ACTION1_CLIENT_SECRET = 'csecret'
}
$cfg = Get-SumatraContainerRuntimeConfig -Environment $envHashHappy
Assert-Equal -Actual $cfg.Action1ClientId  -Expected 'cid' -Message 'client id read'
Assert-Equal -Actual $cfg.Action1OrgId     -Expected 'all' -Message 'default org id is "all"'
Assert-Equal -Actual $cfg.PackageName      -Expected 'SumatraPDF' -Message 'default PACKAGE_NAME is SumatraPDF (NOT "SumatraPDF Managed Updater")'
Assert-Equal -Actual $cfg.OneShot          -Expected $true -Message 'default ONE_SHOT is true'
Assert-Equal -Actual $cfg.CheckFrequencyMinutes -Expected 1440 -Message 'default frequency 1440 minutes'

Assert-Throws -ScriptBlock { Get-SumatraContainerRuntimeConfig -Environment @{} } -Message 'missing client id throws' -ExpectedMessageLike '*ACTION1_CLIENT_ID*'

$envBadMinutes = @{ ACTION1_CLIENT_ID = 'a'; ACTION1_CLIENT_SECRET = 'b'; CHECK_FREQUENCY_MINUTES = 'bogus' }
Assert-Throws -ScriptBlock { Get-SumatraContainerRuntimeConfig -Environment $envBadMinutes } -Message 'bad minutes throws' -ExpectedMessageLike '*positive integer*'

Write-Host '--- Schedule + Cron helpers ---'

$intervalCfg = [pscustomobject]@{ CheckFrequencyMinutes = 1440; CheckFrequencyCron = '' }
$intervalSchedule = New-SumatraContainerScheduleCommand -Config $intervalCfg -SyncScriptPath '/app/src/Sync.ps1'
Assert-Equal -Actual $intervalSchedule.Kind    -Expected 'Interval' -Message 'no cron => interval'
Assert-Equal -Actual $intervalSchedule.Seconds -Expected 86400      -Message '1440 minutes => 86400 seconds'

$cronCfg = [pscustomobject]@{ CheckFrequencyMinutes = 1440; CheckFrequencyCron = '0 4 * * *' }
$cronSchedule = New-SumatraContainerScheduleCommand -Config $cronCfg -SyncScriptPath '/app/src/Sync.ps1'
Assert-Equal -Actual $cronSchedule.Kind       -Expected 'Cron'        -Message 'cron set => cron'
Assert-Equal -Actual $cronSchedule.Expression -Expected '0 4 * * *'   -Message 'cron expression preserved'

Assert-Throws -ScriptBlock { Assert-SumatraContainerCronExpression -Expression 'too few' } -Message 'cron must have 5 fields'
Assert-Throws -ScriptBlock { Assert-SumatraContainerCronExpression -Expression "0 4 * * *`tlol" } -Message 'cron rejects control chars'

$startupOk = Invoke-SumatraContainerStartupSync -OneShot $false -SyncCommand { } -LogCommand { param($e) }
Assert-Equal -Actual $startupOk.Succeeded -Expected $true -Message 'startup ok => succeeded true'

$startupFail = Invoke-SumatraContainerStartupSync -OneShot $false -SyncCommand { throw 'boom' } -LogCommand { param($e) }
Assert-Equal -Actual $startupFail.Succeeded          -Expected $false -Message 'startup fail not one-shot => succeeded false'
Assert-Equal -Actual $startupFail.ContinueScheduling -Expected $true  -Message 'startup fail not one-shot => continues scheduling'

Assert-Throws -ScriptBlock { Invoke-SumatraContainerStartupSync -OneShot $true -SyncCommand { throw 'boom' } -LogCommand { param($e) } } -Message 'one-shot rethrows'

Write-Host '--- Action1 Package Version helpers ---'

$packageWithVersions = [pscustomobject]@{
    versions = [pscustomobject]@{
        items = @(
            [pscustomobject]@{ version = '2702.1.47' },
            [pscustomobject]@{ version = '2702.1.58' }
        )
    }
}
$packageVersions = @(Get-Action1PackageVersionValues -Package $packageWithVersions)
Assert-Equal -Actual ($packageVersions -join ',') -Expected '2702.1.47,2702.1.58' -Message 'Action1 package version helper reads version container'
Assert-True -Condition (Test-Action1PackageHasVersion -Package $packageWithVersions -BuildVersion '2702.1.58') -Message 'Action1 package version helper detects existing build version'
Assert-True -Condition (-not (Test-Action1PackageHasVersion -Package $packageWithVersions -BuildVersion '2702.1.99')) -Message 'Action1 package version helper reports missing build version'

$packageWithBinary = [pscustomobject]@{
    versions = @(
        [pscustomobject]@{
            id = 'version-1'
            version = '2702.1.58'
            binary_id = [pscustomobject]@{ Windows_64 = 'binary-1' }
        }
    )
}
$versionRecord = Get-Action1PackageVersionRecord -Package $packageWithBinary -BuildVersion '2702.1.58'
Assert-Equal -Actual $versionRecord.id -Expected 'version-1' -Message 'Version record helper returns matching version record'
Assert-True -Condition (Test-Action1PackageVersionHasWindowsBinary -VersionRecord $versionRecord) -Message 'Version binary helper detects Windows binary'

$packageWithFieldVersion = [pscustomobject]@{
    versions = [pscustomobject]@{
        items = @(
            [pscustomobject]@{ id = 'field-version-1'; fields = [pscustomobject]@{ Version = '2702.1.58' } }
        )
    }
}
$fieldVersionRecord = Get-Action1PackageVersionRecord -Package $packageWithFieldVersion -BuildVersion '2702.1.58'
Assert-Equal -Actual $fieldVersionRecord.id -Expected 'field-version-1' -Message 'Version record helper reads fields Version fallback'

$packageWithoutBinary = [pscustomobject]@{
    versions = @(
        [pscustomobject]@{ id = 'version-1'; version = '2702.1.58' }
    )
}
$missingBinaryRecord = Get-Action1PackageVersionRecord -Package $packageWithoutBinary -BuildVersion '2702.1.58'
Assert-True -Condition (-not (Test-Action1PackageVersionHasWindowsBinary -VersionRecord $missingBinaryRecord)) -Message 'Version binary helper reports missing Windows binary'

$packageWithConfiguredFileButNoBinary = [pscustomobject]@{
    versions = @(
        [pscustomobject]@{
            id = 'version-1'
            version = '2702.1.58'
            file_name = [pscustomobject]@{ Windows_64 = [pscustomobject]@{ name = 'SumatraPDF-installer.exe'; type = 'cloud' } }
        }
    )
}
$configuredFileRecord = Get-Action1PackageVersionRecord -Package $packageWithConfiguredFileButNoBinary -BuildVersion '2702.1.58'
Assert-True -Condition (-not (Test-Action1PackageVersionHasWindowsBinary -VersionRecord $configuredFileRecord)) -Message 'Version binary helper does not treat configured file name as uploaded binary'

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Stop'
try {
    $nullBinaryRecord = [pscustomobject]@{ version = '2702.1.58'; binary_id = $null }
    Assert-True -Condition (-not (Test-Action1PackageVersionHasWindowsBinary -VersionRecord $nullBinaryRecord)) -Message 'Version binary helper handles null binary id without error'
}
finally {
    $ErrorActionPreference = $previousErrorActionPreference
}

Write-Host '--- Resolve-Action1SumatraVersionSyncAction ---'

$pkgEmpty = [pscustomobject]@{ versions = [pscustomobject]@{ items = @() } }
Assert-Equal -Actual (Resolve-Action1SumatraVersionSyncAction -Package $pkgEmpty -Version '3.6.1') -Expected 'CreateAndUpload' -Message 'no record => CreateAndUpload'

$pkgNoBinary = [pscustomobject]@{ versions = [pscustomobject]@{ items = @(
    [pscustomobject]@{ id = 'v1'; version = '3.6.1' }
) } }
Assert-Equal -Actual (Resolve-Action1SumatraVersionSyncAction -Package $pkgNoBinary -Version '3.6.1') -Expected 'UploadMissingBinary' -Message 'record without binary => UploadMissingBinary'

$pkgWithBinary = [pscustomobject]@{ versions = [pscustomobject]@{ items = @(
    [pscustomobject]@{ id = 'v1'; version = '3.6.1'; binary_id = [pscustomobject]@{ Windows_64 = 'bin-abc' } }
) } }
Assert-Equal -Actual (Resolve-Action1SumatraVersionSyncAction -Package $pkgWithBinary -Version '3.6.1') -Expected 'NoOp' -Message 'record with binary => NoOp'

$pkgMulti = [pscustomobject]@{ versions = [pscustomobject]@{ items = @(
    [pscustomobject]@{ id = 'v1'; version = '3.5.2'; binary_id = [pscustomobject]@{ Windows_64 = 'bin-old' } },
    [pscustomobject]@{ id = 'v2'; version = '3.6.1' }
) } }
Assert-Equal -Actual (Resolve-Action1SumatraVersionSyncAction -Package $pkgMulti -Version '3.6.1') -Expected 'UploadMissingBinary' -Message 'multi-record picks correct version'

Write-Host '--- Action1Repository ---'
Import-Module (Join-Path $repoRoot 'src\Action1Repository.psm1') -Force

# Token body urlencoding
$tokenBody = New-Action1TokenRequestBody -ClientId 'id with space' -ClientSecret 'secret&plus'
Assert-Equal -Actual $tokenBody -Expected 'grant_type=client_credentials&client_id=id+with+space&client_secret=secret%26plus' -Message 'token body urlencodes'

# Package selection refuses ambiguous match
$packagesAmbiguous = [pscustomobject]@{ items = @(
    [pscustomobject]@{ name = 'SumatraPDF' },
    [pscustomobject]@{ name = 'sumatrapdf' }
) }
Assert-Throws -ScriptBlock { Select-Action1PackageByExactName -Packages $packagesAmbiguous -PackageName 'SumatraPDF' } -Message 'multi-match throws' -ExpectedMessageLike '*Multiple Action1 packages*'

# Upload location host-match check
Assert-Throws -ScriptBlock {
    Assert-Action1UploadLocationAllowed -BaseUrl 'https://app.action1.com/api/3.0' -UploadLocation 'https://attacker.example.com/up' -PackageId 'p' -VersionId 'v'
} -Message 'mismatched host throws' -ExpectedMessageLike '*unexpected host*'

$validUploadLoc = Assert-Action1UploadLocationAllowed -BaseUrl 'https://app.action1.com/api/3.0' -UploadLocation 'https://app.action1.com/upload/abc' -PackageId 'p' -VersionId 'v'
Assert-Equal -Actual $validUploadLoc -Expected 'https://app.action1.com/upload/abc' -Message 'matching host returns absolute uri'

# Status code helpers
Assert-Equal -Actual (Test-Action1SuccessStatusCode -StatusCode 200) -Expected $true  -Message '200 success'
Assert-Equal -Actual (Test-Action1SuccessStatusCode -StatusCode 308) -Expected $false -Message '308 not 2xx'
Assert-Equal -Actual (Test-Action1UploadInitStatusCode -StatusCode 308) -Expected $true -Message '308 valid for upload init'

Write-Host '--- Sync script offline integration ---'

$fixtureDir = Join-Path $repoRoot 'tests\fixtures\sync'
$logPath = Join-Path $fixtureDir 'api-requests.log'
if (Test-Path -LiteralPath $logPath) { Remove-Item -LiteralPath $logPath -Force }

$prevEnv = @{
    ACTION1_CLIENT_ID = $env:ACTION1_CLIENT_ID
    ACTION1_CLIENT_SECRET = $env:ACTION1_CLIENT_SECRET
}
try {
    $env:ACTION1_CLIENT_ID = 'fixture-client'
    $env:ACTION1_CLIENT_SECRET = 'fixture-secret'

    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'src\Sync-SumatraAction1Release.ps1') -OfflineFixtureRoot $fixtureDir
    Assert-Equal -Actual $LASTEXITCODE -Expected 0 -Message 'sync script exits 0 in offline mode'

    Assert-True -Condition (Test-Path -LiteralPath $logPath) -Message 'api-requests.log written'
    $logLines = Get-Content -LiteralPath $logPath
    Assert-True -Condition ($logLines -contains 'GET https://api.github.com/repos/sumatrapdfreader/sumatrapdf/releases/latest') -Message 'github call logged'
    Assert-True -Condition ([bool](($logLines | Where-Object { $_ -like 'POST /software-repository/all*' }) | Select-Object -First 1)) -Message 'package create logged'
    Assert-True -Condition ([bool](($logLines | Where-Object { $_ -like 'POST */versions' }) | Select-Object -First 1)) -Message 'version create logged'
    Assert-True -Condition ([bool](($logLines | Where-Object { $_ -like 'UPLOAD */versions/*/upload' }) | Select-Object -First 1)) -Message 'upload logged'
} finally {
    $env:ACTION1_CLIENT_ID = $prevEnv.ACTION1_CLIENT_ID
    $env:ACTION1_CLIENT_SECRET = $prevEnv.ACTION1_CLIENT_SECRET
}
