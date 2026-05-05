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
