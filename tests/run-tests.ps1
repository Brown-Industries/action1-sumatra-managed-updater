$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$testFile = Join-Path $PSScriptRoot 'SumatraManagedUpdate.Tests.ps1'

$script:Failures = 0

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)] $Actual,
        [Parameter(Mandatory = $true)] $Expected,
        [Parameter(Mandatory = $true)] [string] $Message
    )
    if ($Actual -ne $Expected) {
        $script:Failures++
        Write-Host "FAIL: $Message" -ForegroundColor Red
        Write-Host "  Expected: $Expected"
        Write-Host "  Actual:   $Actual"
    } else {
        Write-Host "PASS: $Message" -ForegroundColor Green
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)] [bool] $Condition,
        [Parameter(Mandatory = $true)] [string] $Message
    )
    if (-not $Condition) {
        $script:Failures++
        Write-Host "FAIL: $Message" -ForegroundColor Red
    } else {
        Write-Host "PASS: $Message" -ForegroundColor Green
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)] [scriptblock] $ScriptBlock,
        [Parameter(Mandatory = $true)] [string] $Message,
        [string] $ExpectedMessageLike = ''
    )
    try {
        & $ScriptBlock | Out-Null
        $script:Failures++
        Write-Host "FAIL: $Message (no exception thrown)" -ForegroundColor Red
        return
    } catch {
        if ($ExpectedMessageLike -and ([string]$_.Exception.Message -notlike $ExpectedMessageLike)) {
            $script:Failures++
            Write-Host "FAIL: $Message (message mismatch)" -ForegroundColor Red
            Write-Host "  Expected like: $ExpectedMessageLike"
            Write-Host "  Actual:        $($_.Exception.Message)"
            return
        }
        Write-Host "PASS: $Message" -ForegroundColor Green
    }
}

if (-not (Test-Path -LiteralPath $testFile)) {
    Write-Host "Test file not found: $testFile" -ForegroundColor Red
    exit 1
}

. $testFile

if ($script:Failures -gt 0) {
    Write-Host "$script:Failures test failure(s)." -ForegroundColor Red
    exit 1
}

Write-Host 'All tests passed.' -ForegroundColor Green
exit 0
