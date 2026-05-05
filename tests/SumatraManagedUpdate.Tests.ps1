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
