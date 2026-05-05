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
