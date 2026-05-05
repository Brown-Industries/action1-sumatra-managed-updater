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
