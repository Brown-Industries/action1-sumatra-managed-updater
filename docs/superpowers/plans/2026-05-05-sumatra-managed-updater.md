# SumatraPDF Action1 Managed Updater — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a stateless container that, on each run, queries GitHub for the latest stable SumatraPDF release, downloads its 64-bit Windows installer EXE, and uploads it as a new pinned package version in Action1's software repository.

**Architecture:** Mirrors the layout of `Brown-Industries/action1-fusion-managed-updater` but drops Fusion-specific machinery (base64 PS1 payload builder, endpoint script, watcher state file, inventory-derived build version) since each Sumatra version is a real installer. One PowerShell entry script (`Sync-SumatraAction1Release.ps1`) does discovery + Action1 write in one pass; the Action1 package's own version list is the source of truth, so no state file is needed.

**Tech Stack:** PowerShell 7.4 (pwsh), Bash + cron (Linux container), Docker, GitHub Actions for image publish, homegrown `Assert-Equal` test runner (matches Fusion repo's pattern — no Pester).

**Spec:** `docs/superpowers/specs/2026-05-05-sumatra-managed-updater-design.md`

**Reference repo (read but do not modify):** `Brown-Industries/action1-fusion-managed-updater` on GitHub. Local clone if needed: `git clone --depth 1 https://github.com/Brown-Industries/action1-fusion-managed-updater.git /tmp/fusion-ref`. Throughout this plan, paths under `/tmp/fusion-ref/` refer to that clone.

---

## File structure

Files this plan creates (all paths relative to repo root `C:\git\action1-sumatra-managed-updater\`):

```
.dockerignore                                     # excludes tests/, docs/, .git from image
.gitignore                                        # standard ignores
Dockerfile                                        # pwsh + cron base, copies src/ + container/
README.md                                         # usage docs
docker-compose.example.yml                        # remote-image + local-build example
.github/workflows/docker-publish.yml              # ports Fusion CI verbatim, retargets image
src/SumatraManagedUpdate.Common.psm1              # GitHub fetch, URL build, version body, schedule helpers, Action1 version-record helpers
src/Action1Repository.psm1                        # OAuth, package lookup, version create, binary upload (ports cleanly from Fusion)
src/Sync-SumatraAction1Release.ps1                # main entry: orchestrates discover → ensure package → create + upload version
container/entrypoint.ps1                          # one-shot or interval/cron loop (ports verbatim from Fusion)
tests/run-tests.ps1                               # homegrown Assert-Equal runner (ports verbatim from Fusion)
tests/SumatraManagedUpdate.Tests.ps1              # offline unit tests for Common module
tests/fixtures/sync/                              # offline integration fixtures
tests/fixtures/sync/github-release-latest.json    # canned GitHub /releases/latest body
tests/fixtures/sync/action1-package.json          # canned Action1 package response
tests/fixtures/sync/action1-token.json            # canned OAuth token response
tests/fixtures/sync/installer.bin                 # 16-byte stand-in for the EXE
```

File responsibility split:

- `SumatraManagedUpdate.Common.psm1`: pure helpers + module-scoped logic that the entry script orchestrates. Testable offline, no global state.
- `Action1Repository.psm1`: every Action1 HTTP call (auth, list, create, upload). Port from Fusion's module of the same name; only the package body shape differs.
- `Sync-SumatraAction1Release.ps1`: thin orchestrator. No business rules in this file — it composes module functions and decides "create vs. upload-only vs. NoOp".
- `container/entrypoint.ps1`: the only file the Dockerfile invokes. Decides one-shot vs. interval vs. cron from env, then calls the sync script.

---

## Phase 1 — Repo bootstrap

### Task 1: Initialize repo skeleton

**Files:**
- Create: `C:\git\action1-sumatra-managed-updater\.gitignore`
- Create: `C:\git\action1-sumatra-managed-updater\.dockerignore`

The repo and `main` branch already exist with the spec file committed. This task adds the ignore files so subsequent commits don't accidentally include local junk or balloon the Docker build context.

- [ ] **Step 1: Create `.gitignore`**

```
# OS / editor
.DS_Store
Thumbs.db
*.swp
.vscode/

# Local download / scratch
/tmp/
/installers/
*.exe

# Test artifacts
tests/fixtures/**/api-requests.log
```

- [ ] **Step 2: Create `.dockerignore`**

```
.git
.github
.gitignore
.dockerignore
README.md
docs/
tests/
docker-compose.example.yml
*.md
```

- [ ] **Step 3: Commit**

```
cd C:\git\action1-sumatra-managed-updater
git add .gitignore .dockerignore
git commit -m "chore: add gitignore and dockerignore"
```

---

### Task 2: Port the test runner

**Files:**
- Create: `tests/run-tests.ps1`

The Fusion repo uses a homegrown runner with `Assert-Equal` and `Assert-True` rather than Pester. Ports verbatim — only the test file path changes.

- [ ] **Step 1: Create `tests/run-tests.ps1`**

```powershell
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
```

- [ ] **Step 2: Create empty test file so the runner doesn't fail**

Create `tests/SumatraManagedUpdate.Tests.ps1`:

```powershell
# Tests are appended to this file by subsequent tasks.
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repoRoot 'src\SumatraManagedUpdate.Common.psm1'
if (Test-Path -LiteralPath $modulePath) {
    Import-Module $modulePath -Force
}
```

- [ ] **Step 3: Run the runner to confirm scaffolding works**

```
pwsh -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
```

Expected output: `All tests passed.` (no tests yet, but the runner exits 0.)

- [ ] **Step 4: Commit**

```
git add tests/
git commit -m "chore(tests): add homegrown assert runner ported from fusion"
```

---

## Phase 2 — Common module: net-new Sumatra logic (TDD)

Each task follows the same shape: write the failing test, run it red, implement, run it green, commit. Append new tests to `tests/SumatraManagedUpdate.Tests.ps1` and new functions to `src/SumatraManagedUpdate.Common.psm1`. The module file does not exist yet — Task 3 creates it. Subsequent tasks append.

### Task 3: ConvertTo-SumatraVersion (tag normalization)

**Files:**
- Create: `src/SumatraManagedUpdate.Common.psm1`
- Modify: `tests/SumatraManagedUpdate.Tests.ps1`

GitHub tag forms observed for SumatraPDF: `3.6.1rel`, `3.5.2`, `3.4.6`, `3.3.3`. The release is sometimes published with a trailing `rel` suffix (no separator, e.g. `3.6.1rel`) and sometimes without. The function strips an optional trailing `-rel` or `rel` and validates that what remains is a dotted numeric version.

- [ ] **Step 1: Append failing tests to `tests/SumatraManagedUpdate.Tests.ps1`**

```powershell
Write-Host '--- ConvertTo-SumatraVersion ---'
Assert-Equal -Actual (ConvertTo-SumatraVersion -TagName '3.6.1rel') -Expected '3.6.1' -Message 'strips trailing rel suffix without separator'
Assert-Equal -Actual (ConvertTo-SumatraVersion -TagName '3.5.2-rel') -Expected '3.5.2' -Message 'strips trailing -rel suffix'
Assert-Equal -Actual (ConvertTo-SumatraVersion -TagName '3.4.6')    -Expected '3.4.6' -Message 'plain semver passes through'
Assert-Equal -Actual (ConvertTo-SumatraVersion -TagName 'v3.3.3')   -Expected '3.3.3' -Message 'strips leading v'
Assert-Throws -ScriptBlock { ConvertTo-SumatraVersion -TagName '' }            -Message 'empty tag throws'      -ExpectedMessageLike '*tag*'
Assert-Throws -ScriptBlock { ConvertTo-SumatraVersion -TagName 'prerel-3.6-1' } -Message 'prerel tag throws'    -ExpectedMessageLike '*not a release tag*'
Assert-Throws -ScriptBlock { ConvertTo-SumatraVersion -TagName 'just-text' }   -Message 'non-numeric throws'   -ExpectedMessageLike '*numeric*'
```

- [ ] **Step 2: Run tests to verify they fail**

```
pwsh -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
```

Expected: failures complaining `ConvertTo-SumatraVersion` is not recognized.

- [ ] **Step 3: Create `src/SumatraManagedUpdate.Common.psm1` with the function**

```powershell
$ErrorActionPreference = 'Stop'

function ConvertTo-SumatraVersion {
    param([Parameter(Mandatory = $true)][string]$TagName)

    if ([string]::IsNullOrWhiteSpace($TagName)) {
        throw 'tag name must not be empty.'
    }
    $value = $TagName.Trim()
    if ($value -like 'prerel-*') {
        throw "GitHub tag '$TagName' is not a release tag."
    }
    if ($value.StartsWith('v')) { $value = $value.Substring(1) }
    if ($value.EndsWith('-rel')) { $value = $value.Substring(0, $value.Length - 4) }
    elseif ($value.EndsWith('rel')) { $value = $value.Substring(0, $value.Length - 3) }
    if ($value -notmatch '^\d+(\.\d+){1,3}$') {
        throw "GitHub tag '$TagName' did not normalize to a numeric dotted version."
    }
    return $value
}

Export-ModuleMember -Function ConvertTo-SumatraVersion
```

- [ ] **Step 4: Run tests, expect green**

```
pwsh -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```
git add src/ tests/
git commit -m "feat(common): tag-name normalization for sumatra releases"
```

---

### Task 4: Resolve-SumatraInstallerUrl (URL construction)

**Files:**
- Modify: `src/SumatraManagedUpdate.Common.psm1`
- Modify: `tests/SumatraManagedUpdate.Tests.ps1`

Verified URL pattern (HEAD checks 2026-05-05 for 3.6.1, 3.5.2, 3.4.6, 3.3.3): `https://www.sumatrapdfreader.org/dl/rel/{v}/SumatraPDF-{v}-64-install.exe`. Pure construction here — the HEAD verification is a separate function in Task 6.

- [ ] **Step 1: Append failing tests**

```powershell
Write-Host '--- Resolve-SumatraInstallerUrl ---'
Assert-Equal -Actual (Resolve-SumatraInstallerUrl -Version '3.6.1') -Expected 'https://www.sumatrapdfreader.org/dl/rel/3.6.1/SumatraPDF-3.6.1-64-install.exe' -Message 'constructs current pattern'
Assert-Equal -Actual (Resolve-SumatraInstallerUrl -Version '3.3.3') -Expected 'https://www.sumatrapdfreader.org/dl/rel/3.3.3/SumatraPDF-3.3.3-64-install.exe' -Message 'works for older versions'
Assert-Throws -ScriptBlock { Resolve-SumatraInstallerUrl -Version '' }       -Message 'empty version throws'
Assert-Throws -ScriptBlock { Resolve-SumatraInstallerUrl -Version 'foo bar' } -Message 'invalid version throws' -ExpectedMessageLike '*numeric*'

Assert-Equal -Actual (Resolve-SumatraInstallerFileName -Version '3.6.1') -Expected 'SumatraPDF-3.6.1-64-install.exe' -Message 'file name follows version'
```

- [ ] **Step 2: Run tests, expect failures**

```
pwsh -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
```

- [ ] **Step 3: Append functions to `src/SumatraManagedUpdate.Common.psm1`**

Insert before the `Export-ModuleMember` line:

```powershell
function Assert-SumatraVersionString {
    param([Parameter(Mandatory = $true)][string]$Version)
    if ([string]::IsNullOrWhiteSpace($Version)) {
        throw 'version must not be empty.'
    }
    if ($Version -notmatch '^\d+(\.\d+){1,3}$') {
        throw "version '$Version' is not a numeric dotted version."
    }
    return $Version
}

function Resolve-SumatraInstallerFileName {
    param([Parameter(Mandatory = $true)][string]$Version)
    [void](Assert-SumatraVersionString -Version $Version)
    return "SumatraPDF-$Version-64-install.exe"
}

function Resolve-SumatraInstallerUrl {
    param([Parameter(Mandatory = $true)][string]$Version)
    [void](Assert-SumatraVersionString -Version $Version)
    return "https://www.sumatrapdfreader.org/dl/rel/$Version/$(Resolve-SumatraInstallerFileName -Version $Version)"
}
```

Update the `Export-ModuleMember` line at the bottom to:

```powershell
Export-ModuleMember -Function ConvertTo-SumatraVersion, Assert-SumatraVersionString, Resolve-SumatraInstallerFileName, Resolve-SumatraInstallerUrl
```

- [ ] **Step 4: Run tests, expect green**

```
pwsh -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
```

- [ ] **Step 5: Commit**

```
git add src/ tests/
git commit -m "feat(common): installer url and file name from version"
```

---

### Task 5: Get-SumatraLatestRelease parser (offline)

**Files:**
- Modify: `src/SumatraManagedUpdate.Common.psm1`
- Modify: `tests/SumatraManagedUpdate.Tests.ps1`

The function takes a *parsed* GitHub `/releases/latest` response object (already deserialized from JSON) and returns `[pscustomobject]@{ Version; PublishedAt; TagName }`. The HTTP call lives in the entry script — keeping the parser pure makes it trivially testable without network. Hard-fail if the response is a draft or prerelease (defensive — `/releases/latest` excludes both per the GitHub docs, but we don't trust silently).

- [ ] **Step 1: Append failing tests**

```powershell
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
```

- [ ] **Step 2: Run tests, expect failures**

- [ ] **Step 3: Append the function**

Insert before `Export-ModuleMember`:

```powershell
function Get-SumatraLatestRelease {
    param([Parameter(Mandatory = $true)]$Response)

    $tag = [string]$Response.tag_name
    $publishedAt = [string]$Response.published_at
    $isDraft = [bool]$Response.draft
    $isPrerelease = [bool]$Response.prerelease

    if ($isDraft) { throw 'GitHub /releases/latest returned a draft release; refusing to act.' }
    if ($isPrerelease) { throw 'GitHub /releases/latest returned a prerelease; refusing to act.' }
    if ([string]::IsNullOrWhiteSpace($tag)) { throw 'GitHub /releases/latest response did not include tag_name.' }

    $version = ConvertTo-SumatraVersion -TagName $tag
    return [pscustomobject]@{
        Version     = $version
        TagName     = $tag
        PublishedAt = $publishedAt
    }
}
```

Update `Export-ModuleMember` to include `Get-SumatraLatestRelease`.

- [ ] **Step 4: Run tests green; commit**

```
pwsh -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
git add src/ tests/
git commit -m "feat(common): parse github releases/latest into version + date"
```

---

### Task 6: Test-SumatraInstallerUrlAvailable (HEAD verifier)

**Files:**
- Modify: `src/SumatraManagedUpdate.Common.psm1`
- Modify: `tests/SumatraManagedUpdate.Tests.ps1`

Performs an HTTP HEAD on the constructed URL and verifies status 200 + non-zero `Content-Length`. The function takes an optional `-RequestCommand` scriptblock so tests can inject a fake response (matches the dependency-injection pattern used in Fusion's `Action1Repository.psm1`). When `-RequestCommand` is null, it uses `Invoke-WebRequest -Method Head`.

- [ ] **Step 1: Append failing tests**

```powershell
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
```

- [ ] **Step 2: Run tests, expect failures**

- [ ] **Step 3: Append the function**

```powershell
function Get-SumatraResponseHeaderValue {
    param(
        [Parameter(Mandatory = $true)]$Headers,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($null -eq $Headers) { return '' }
    $value = $null
    if ($Headers -is [Collections.IDictionary]) {
        if ($Headers.Contains($Name)) { $value = $Headers[$Name] }
    } else {
        $property = $Headers.PSObject.Properties[$Name]
        if ($property) { $value = $property.Value }
    }
    if ($value -is [Array]) { $value = $value | Select-Object -First 1 }
    return [string]$value
}

function Test-SumatraInstallerUrlAvailable {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [scriptblock]$RequestCommand = $null
    )

    $response = if ($RequestCommand) {
        & $RequestCommand 'HEAD' $Url
    } else {
        Invoke-WebRequest -Method Head -Uri $Url -UseBasicParsing
    }

    $status = 0
    [int]::TryParse([string]$response.StatusCode, [ref]$status) | Out-Null
    if ($status -ne 200) {
        throw "Sumatra installer URL HEAD returned $status for '$Url'."
    }

    $lengthRaw = Get-SumatraResponseHeaderValue -Headers $response.Headers -Name 'Content-Length'
    $length = 0L
    [long]::TryParse($lengthRaw, [ref]$length) | Out-Null
    if ($length -lt 1) {
        throw "Sumatra installer URL HEAD reported zero content-length for '$Url'."
    }
    return $true
}
```

Update `Export-ModuleMember` to include `Test-SumatraInstallerUrlAvailable`.

- [ ] **Step 4: Run tests green; commit**

```
pwsh -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
git add src/ tests/
git commit -m "feat(common): HEAD-verify sumatra installer url before download"
```

---

### Task 7: Save-SumatraInstaller (download with curl + IWR fallback)

**Files:**
- Modify: `src/SumatraManagedUpdate.Common.psm1`
- Modify: `tests/SumatraManagedUpdate.Tests.ps1`

Downloads the installer to a target path. Prefers `curl` (cross-platform, present in pwsh:7.4-ubuntu-22.04 base image), falls back to `Invoke-WebRequest`. Verifies file exists and size > 0 after download. Returns `[pscustomobject]@{ Path; SizeBytes; Sha256 }`.

The function takes an optional `-DownloadCommand` scriptblock for tests; without it, it picks curl/IWR.

- [ ] **Step 1: Append failing tests**

```powershell
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
```

- [ ] **Step 2: Run tests, expect failures**

- [ ] **Step 3: Append the function**

```powershell
function Get-SumatraDefaultDownloadCommand {
    return {
        param([Parameter(Mandatory = $true)][string]$Url, [Parameter(Mandatory = $true)][string]$Path)
        $curl = Get-Command curl -ErrorAction SilentlyContinue
        if ($null -ne $curl) {
            $curlArgs = @('-fL', '--retry', '3', '--retry-delay', '2', '-o', $Path, $Url)
            & $curl.Source @curlArgs
            if ($LASTEXITCODE -ne 0) {
                throw "curl exited $LASTEXITCODE downloading '$Url'."
            }
            return
        }
        Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing
    }
}

function Save-SumatraInstaller {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Path,
        [scriptblock]$DownloadCommand = $null
    )

    $parentDir = Split-Path -Parent $Path
    if ($parentDir -and -not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    if ($null -eq $DownloadCommand) {
        $DownloadCommand = Get-SumatraDefaultDownloadCommand
    }

    & $DownloadCommand $Url $Path

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Download did not produce file at '$Path'."
    }
    $size = (Get-Item -LiteralPath $Path).Length
    if ($size -lt 1) {
        throw "Downloaded file is empty: '$Path'."
    }
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    return [pscustomobject]@{ Path = $Path; SizeBytes = $size; Sha256 = $hash }
}
```

Update `Export-ModuleMember` to include `Save-SumatraInstaller`.

- [ ] **Step 4: Run tests green; commit**

```
pwsh -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
git add src/ tests/
git commit -m "feat(common): download installer with curl fallback to IWR"
```

---

### Task 8: New-Action1SumatraVersionBody and New-Action1SumatraPackageBody

**Files:**
- Modify: `src/SumatraManagedUpdate.Common.psm1`
- Modify: `tests/SumatraManagedUpdate.Tests.ps1`

Two builder functions for the Action1 JSON bodies. Field values are exactly as specified in the design doc.

- [ ] **Step 1: Append failing tests**

```powershell
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
Assert-True  -Condition ([string]$pkg.description).Length -gt 0 -Message 'description set'
```

- [ ] **Step 2: Run tests, expect failures**

- [ ] **Step 3: Append the functions**

```powershell
function New-Action1SumatraVersionBody {
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$DetectedDate,
        [Parameter(Mandatory = $true)][string]$PayloadFileName
    )

    [ordered]@{
        version                 = $Version
        app_name_match          = '^SumatraPDF$'
        release_date            = $DetectedDate
        security_severity       = 'Unspecified'
        silent_install_switches = '-install -silent -all-users'
        success_exit_codes      = '0'
        reboot_exit_codes       = ''
        install_type            = 'exe'
        EULA_accepted           = 'no'
        update_type             = 'Regular Updates'
        os                      = @('Windows 10', 'Windows 11')
        file_name               = @{ Windows_64 = @{ name = $PayloadFileName; type = 'cloud' } }
    }
}

function New-Action1SumatraPackageBody {
    param([Parameter(Mandatory = $true)][string]$PackageName)

    [ordered]@{
        name           = $PackageName
        vendor         = 'SumatraPDF'
        description    = 'Action1-managed updater for SumatraPDF. Each version is a pinned 64-bit Windows installer that can be deployed independently.'
        platform       = 'Windows'
        internal_notes = 'Versions correspond to GitHub releases under sumatrapdfreader/sumatrapdf. Older versions remain deployable.'
    }
}
```

Update `Export-ModuleMember` to include both.

- [ ] **Step 4: Run tests green; commit**

```
pwsh -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
git add src/ tests/
git commit -m "feat(common): action1 package + version body builders"
```

---

## Phase 3 — Common module: ports from Fusion

These tasks copy battle-tested helpers from the Fusion repo, rename `Fusion → Sumatra`, and run the matching tests. There are very few semantic changes; the goal is reuse, not rewrite.

### Task 9: Port settings reader and runtime config

**Files:**
- Modify: `src/SumatraManagedUpdate.Common.psm1`
- Modify: `tests/SumatraManagedUpdate.Tests.ps1`

Ports `Get-FusionSettingValue`, `ConvertTo-FusionBooleanSetting`, and `Get-FusionContainerRuntimeConfig` (rename to `Sumatra*`). The only behavioral change is the default `PackageName` becomes `'SumatraPDF'`.

- [ ] **Step 1: Open Fusion reference**

Read `/tmp/fusion-ref/src/FusionManagedUpdate.Common.psm1` lines 108-171 (the three Fusion equivalents).

- [ ] **Step 2: Append the renamed functions to `src/SumatraManagedUpdate.Common.psm1`**

```powershell
function Get-SumatraSettingValue {
    param(
        [hashtable]$Environment,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Default = ''
    )
    $value = $null
    if ($Environment -and $Environment.ContainsKey($Name)) {
        $value = [string]$Environment[$Name]
    } else {
        $value = [Environment]::GetEnvironmentVariable($Name)
    }
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $Default
    }
    return $value
}

function ConvertTo-SumatraBooleanSetting {
    param(
        [string]$Value,
        [bool]$Default = $false,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Default }
    switch -Regex ($Value.Trim()) {
        '^(1|true|yes|y)$' { return $true }
        '^(0|false|no|n)$' { return $false }
        default { throw "$Name must be true or false." }
    }
}

function Get-SumatraContainerRuntimeConfig {
    param([hashtable]$Environment = $null)

    $clientId = Get-SumatraSettingValue -Environment $Environment -Name 'ACTION1_CLIENT_ID'
    $clientSecret = Get-SumatraSettingValue -Environment $Environment -Name 'ACTION1_CLIENT_SECRET'
    if ([string]::IsNullOrWhiteSpace($clientId)) { throw 'ACTION1_CLIENT_ID is required.' }
    if ([string]::IsNullOrWhiteSpace($clientSecret)) { throw 'ACTION1_CLIENT_SECRET is required.' }

    $minutesText = Get-SumatraSettingValue -Environment $Environment -Name 'CHECK_FREQUENCY_MINUTES' -Default '1440'
    $minutes = 0
    if (-not [int]::TryParse($minutesText, [ref]$minutes) -or $minutes -lt 1) {
        throw 'CHECK_FREQUENCY_MINUTES must be a positive integer.'
    }

    [pscustomobject]@{
        Action1ClientId       = $clientId
        Action1ClientSecret   = $clientSecret
        Action1BaseUrl        = (Get-SumatraSettingValue -Environment $Environment -Name 'ACTION1_BASE_URL' -Default 'https://app.action1.com/api/3.0').TrimEnd('/')
        Action1OrgId          = Get-SumatraSettingValue -Environment $Environment -Name 'ACTION1_ORG_ID' -Default 'all'
        PackageName           = Get-SumatraSettingValue -Environment $Environment -Name 'PACKAGE_NAME' -Default 'SumatraPDF'
        OneShot               = ConvertTo-SumatraBooleanSetting -Value (Get-SumatraSettingValue -Environment $Environment -Name 'ONE_SHOT' -Default 'true') -Default $true -Name 'ONE_SHOT'
        CheckFrequencyCron    = Get-SumatraSettingValue -Environment $Environment -Name 'CHECK_FREQUENCY_CRON'
        CheckFrequencyMinutes = $minutes
    }
}
```

Update `Export-ModuleMember` to include all three.

- [ ] **Step 3: Append tests**

```powershell
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
```

- [ ] **Step 4: Run tests green; commit**

```
pwsh -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
git add src/ tests/
git commit -m "feat(common): port runtime config reader from fusion"
```

---

### Task 10: Port schedule + cron helpers

**Files:**
- Modify: `src/SumatraManagedUpdate.Common.psm1`
- Modify: `tests/SumatraManagedUpdate.Tests.ps1`

Ports `New-FusionContainerScheduleCommand`, `ConvertTo-FusionBashSingleQuotedArgument`, `Assert-FusionContainerCronExpression`, `New-FusionContainerCronEnvironmentSpec`, `Invoke-FusionContainerSyncOnce`, `Invoke-FusionContainerStartupSync` (rename `Fusion → Sumatra`).

- [ ] **Step 1: Open Fusion reference**

Read `/tmp/fusion-ref/src/FusionManagedUpdate.Common.psm1` lines 173-290.

- [ ] **Step 2: Append renamed functions to `src/SumatraManagedUpdate.Common.psm1`**

Copy the function bodies, replacing `Fusion` with `Sumatra` in function names and string literals. One specific rename: in `Invoke-SumatraContainerSyncOnce`, the error message becomes `"Sumatra container sync script '$ScriptPath' exited with code $exitCode."`.

```powershell
function ConvertTo-SumatraBashSingleQuotedArgument {
    param([Parameter(Mandatory = $true)][string]$Value)
    return "'$($Value.Replace("'", "'\''"))'"
}

function Assert-SumatraContainerCronExpression {
    param([Parameter(Mandatory = $true)][string]$Expression)
    if ([string]::IsNullOrWhiteSpace($Expression)) { throw 'CHECK_FREQUENCY_CRON must not be blank.' }
    if ($Expression -match '[\x00-\x1F\x7F]') { throw 'CHECK_FREQUENCY_CRON must not contain control characters.' }
    $fields = @($Expression.Trim() -split '\s+')
    if ($fields.Count -ne 5) { throw 'CHECK_FREQUENCY_CRON must contain exactly five fields.' }
    return $Expression
}

function New-SumatraContainerScheduleCommand {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$SyncScriptPath
    )
    $quotedSyncScriptPath = ConvertTo-SumatraBashSingleQuotedArgument -Value $SyncScriptPath
    $command = "pwsh -NoProfile -ExecutionPolicy Bypass -File $quotedSyncScriptPath"
    if (-not [string]::IsNullOrWhiteSpace([string]$Config.CheckFrequencyCron)) {
        return [pscustomobject]@{
            Kind       = 'Cron'
            Expression = Assert-SumatraContainerCronExpression -Expression ([string]$Config.CheckFrequencyCron)
            Command    = $command
        }
    }
    return [pscustomobject]@{
        Kind    = 'Interval'
        Seconds = [int]$Config.CheckFrequencyMinutes * 60
        Command = $command
    }
}

function New-SumatraContainerCronEnvironmentSpec {
    param([hashtable]$Environment = $null)

    $names = @(
        'ACTION1_CLIENT_ID', 'ACTION1_CLIENT_SECRET', 'ACTION1_BASE_URL',
        'ACTION1_ORG_ID', 'PACKAGE_NAME', 'CHECK_FREQUENCY_CRON',
        'CHECK_FREQUENCY_MINUTES', 'ONE_SHOT'
    )
    $lines = foreach ($name in $names) {
        $value = Get-SumatraSettingValue -Environment $Environment -Name $name
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace($value)) {
            $escaped = ([string]$value).Replace("'", "'\''")
            "$name='$escaped'"
        }
    }
    [pscustomobject]@{
        Mode  = '0600'
        Lines = @($lines)
    }
}

function Invoke-SumatraContainerSyncOnce {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string]$PowerShellCommand = 'pwsh'
    )
    & $PowerShellCommand -NoProfile -ExecutionPolicy Bypass -File $ScriptPath
    $exitCode = $LASTEXITCODE
    if ($null -ne $exitCode -and $exitCode -ne 0) {
        throw "Sumatra container sync script '$ScriptPath' exited with code $exitCode."
    }
}

function Invoke-SumatraContainerStartupSync {
    param(
        [Parameter(Mandatory = $true)][bool]$OneShot,
        [Parameter(Mandatory = $true)][scriptblock]$SyncCommand,
        [scriptblock]$LogCommand = {
            param($ErrorRecord)
            Write-Error $ErrorRecord -ErrorAction Continue
        }
    )
    try {
        & $SyncCommand
        return [pscustomobject]@{ Succeeded = $true; ContinueScheduling = $true }
    } catch {
        if ($OneShot) { throw }
        & $LogCommand $_
        return [pscustomobject]@{ Succeeded = $false; ContinueScheduling = $true }
    }
}
```

Update `Export-ModuleMember` to include all six new function names.

- [ ] **Step 3: Append tests**

```powershell
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
```

- [ ] **Step 4: Run tests green; commit**

```
pwsh -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
git add src/ tests/
git commit -m "feat(common): port schedule and cron helpers from fusion"
```

---

### Task 11: Port Action1 package version inspection helpers

**Files:**
- Modify: `src/SumatraManagedUpdate.Common.psm1`
- Modify: `tests/SumatraManagedUpdate.Tests.ps1`

Ports `Test-Action1PackageVersionContainerPresent`, `Get-Action1PackageVersionRecords`, `Get-Action1PackageVersionValues`, `Test-Action1PackageHasVersion`, `Get-Action1PackageVersionRecord`, `Test-Action1PackageVersionHasWindowsBinary` from the Fusion module. These are vendor-agnostic helpers that operate on Action1 API response shapes; copy verbatim.

- [ ] **Step 1: Read the source range**

Read `/tmp/fusion-ref/src/FusionManagedUpdate.Common.psm1` lines 374-540 (the package-version helpers — adjust if function ordering differs in the file).

- [ ] **Step 2: Copy the functions verbatim into `src/SumatraManagedUpdate.Common.psm1`**

Copy the `Test-Action1PackageVersionContainerPresent`, `Get-Action1PackageVersionRecords`, `Get-Action1PackageVersionValues`, `Test-Action1PackageHasVersion`, `Get-Action1PackageVersionRecord`, `Test-Action1PackageVersionHasWindowsBinary` function definitions exactly as written in the Fusion module — they take `$Package` / `$VersionRecord` parameters and don't reference `Fusion` anywhere.

Update `Export-ModuleMember` to include all six.

- [ ] **Step 3: Port the matching tests**

Read `/tmp/fusion-ref/tests/FusionManagedUpdate.Tests.ps1` and find the test cases for the six helpers. Copy their `Assert-Equal` / `Assert-True` calls into `tests/SumatraManagedUpdate.Tests.ps1`. The fixtures are inline `[pscustomobject]` literals; no external file changes needed.

- [ ] **Step 4: Add Resolve-Action1VersionSyncAction helper**

The Fusion repo defines this in `Action1Repository.psm1`, but for Sumatra we move it into `Common.psm1` because the version-record shape inspection logic belongs with the other Action1 inspection helpers, and we only need a slimmer variant (no payload-file-name comparison — Sumatra's filename is fully determined by version, so we just check whether a record exists with the binary attached).

```powershell
function Resolve-Action1SumatraVersionSyncAction {
    param(
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)][string]$Version
    )
    $record = Get-Action1PackageVersionRecord -Package $Package -BuildVersion $Version
    if ($null -eq $record) { return 'CreateAndUpload' }
    if (Test-Action1PackageVersionHasWindowsBinary -VersionRecord $record) {
        return 'NoOp'
    }
    return 'UploadMissingBinary'
}
```

Add tests for the four cases (missing record, record without binary, record with binary, multi-record-pick-correct).

- [ ] **Step 5: Run tests green; commit**

```
pwsh -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
git add src/ tests/
git commit -m "feat(common): port action1 version inspection helpers from fusion"
```

---

### Task 12: Port Action1Repository.psm1

**Files:**
- Create: `src/Action1Repository.psm1`

The Fusion module at `/tmp/fusion-ref/src/Action1Repository.psm1` is 382 lines and ports almost verbatim. The differences for Sumatra:

- Drop `New-Action1PayloadFileName` (Sumatra's filename is generated by `Resolve-SumatraInstallerFileName` in Common, not from a hash of a generated PS1 payload).
- Drop `Resolve-Action1VersionSyncAction` (replaced by `Resolve-Action1SumatraVersionSyncAction` in Common — Sumatra's variant doesn't need payload-filename comparison).
- Drop `Test-Action1PackageVersionUsesPayloadFileName` and `Get-Action1VersionWindowsPayloadFileName` (only used by the Fusion variant of `Resolve-Action1VersionSyncAction`).
- Keep everything else verbatim: `ConvertTo-Action1FormValue`, `New-Action1TokenRequestBody`, `Select-Action1PackageByExactName`, `Get-Action1AccessToken`, `Invoke-Action1JsonApi`, `Invoke-Action1RequestCommand`, `Ensure-Action1PackageByName`, `Assert-Action1PositivePayloadLength`, `New-Action1UploadInitHeaders`, `New-Action1UploadPutHeaders`, `Set-Action1RepositoryVersionPayloadFileName`, `New-Action1RepositoryVersion`, `Invoke-Action1UploadRequest`, `Test-Action1SuccessStatusCode`, `Test-Action1UploadInitStatusCode`, `Assert-Action1UploadLocationAllowed`, `Send-Action1VersionPayload`.

`Ensure-Action1PackageByName` is called with `New-Action1SumatraPackageBody` instead of `New-Action1FusionPackageBody`. Looking at the Fusion implementation, the body builder is referenced as a global function name — we need to adjust this.

- [ ] **Step 1: Read the Fusion module**

Read `/tmp/fusion-ref/src/Action1Repository.psm1` end-to-end.

- [ ] **Step 2: Create the Sumatra version of the file**

Copy the Fusion file content into `src/Action1Repository.psm1` and:

1. Change the leading import: `$commonModulePath = Join-Path $PSScriptRoot 'SumatraManagedUpdate.Common.psm1'` (was `FusionManagedUpdate.Common.psm1`).
2. Modify `Ensure-Action1PackageByName` so it accepts a `-PackageBody` parameter instead of hardcoding `New-Action1FusionPackageBody`. Specifically, the existing line `Body (New-Action1FusionPackageBody -PackageName $PackageName)` becomes `Body $PackageBody`. The function signature gains `[Parameter(Mandatory = $true)]$PackageBody`.
3. Drop the four functions listed above (`New-Action1PayloadFileName`, `Resolve-Action1VersionSyncAction`, `Test-Action1PackageVersionUsesPayloadFileName`, `Get-Action1VersionWindowsPayloadFileName`).
4. Update the `Export-ModuleMember` list at the bottom to remove the dropped functions.

- [ ] **Step 3: Add inline tests for the most failure-prone helpers**

Append to `tests/SumatraManagedUpdate.Tests.ps1`:

```powershell
Write-Host '--- Action1Repository ---'
Import-Module (Join-Path $repoRoot 'src\Action1Repository.psm1') -Force

# Token body urlencoding
$tokenBody = New-Action1TokenRequestBody -ClientId 'id with space' -ClientSecret 'secret&plus'
Assert-Equal -Actual $tokenBody -Expected 'grant_type=client_credentials&client_id=id+with+space&client_secret=secret%26plus' -Message 'token body urlencodes'

# Package selection refuses ambiguous match
$packagesAmbiguous = [pscustomobject]@{ items = @(
    [pscustomobject]@{ name = 'SumatraPDF' },
    [pscustomobject]@{ name = 'sumatrapdf' }   # case-insensitive duplicate
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
```

- [ ] **Step 4: Run tests green; commit**

```
pwsh -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
git add src/ tests/
git commit -m "feat: port action1 repository module from fusion"
```

---

## Phase 4 — Sync entry script + container

### Task 13: Write Sync-SumatraAction1Release.ps1

**Files:**
- Create: `src/Sync-SumatraAction1Release.ps1`
- Modify: `tests/SumatraManagedUpdate.Tests.ps1` (offline integration test invocation in Task 14)

Orchestrator. Follows the data flow from the spec section 2:

1. Load runtime config.
2. GET GitHub `/releases/latest` → parse via `Get-SumatraLatestRelease`.
3. Build URL via `Resolve-SumatraInstallerUrl` → HEAD-verify via `Test-SumatraInstallerUrlAvailable`.
4. Acquire Action1 token, find or create package.
5. Decide sync action via `Resolve-Action1SumatraVersionSyncAction`.
6. If NoOp, exit 0. Otherwise download installer, create + upload version.
7. Re-fetch version, verify binary attached.

Supports `-OfflineFixtureRoot` for the integration test (matches Fusion's pattern).

- [ ] **Step 1: Create `src/Sync-SumatraAction1Release.ps1`**

```powershell
[CmdletBinding()]
param(
    [string]$OfflineFixtureRoot = '',
    [string]$InstallerCacheDir = ''
)

$ErrorActionPreference = 'Stop'

$commonModulePath = Join-Path $PSScriptRoot 'SumatraManagedUpdate.Common.psm1'
$action1ModulePath = Join-Path $PSScriptRoot 'Action1Repository.psm1'
Import-Module $commonModulePath -Force
Import-Module $action1ModulePath -Force

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Name, [string]$Detail = '')
    $line = if ([string]::IsNullOrWhiteSpace($Detail)) { "SUMATRA_STEP $Name" } else { "SUMATRA_STEP $Name $Detail" }
    Write-Host $line
}

function Read-OfflineJson {
    param([Parameter(Mandatory = $true)][string]$Name)
    $path = Join-Path $OfflineFixtureRoot $Name
    if (-not (Test-Path -LiteralPath $path)) { throw "Offline fixture file was not found: $path" }
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}

function Write-OfflineRequest {
    param([Parameter(Mandatory = $true)][string]$Line)
    Add-Content -LiteralPath (Join-Path $OfflineFixtureRoot 'api-requests.log') -Encoding ASCII -Value $Line
}

$config = Get-SumatraContainerRuntimeConfig

if (-not $InstallerCacheDir) {
    $InstallerCacheDir = if ($IsWindows) { Join-Path $env:TEMP 'sumatra-installer-cache' } else { '/tmp/sumatra-installer-cache' }
}

# 1. GitHub /releases/latest
Write-Step 'github_query_start'
if ($OfflineFixtureRoot) {
    $githubResponse = Read-OfflineJson -Name 'github-release-latest.json'
    Write-OfflineRequest -Line 'GET https://api.github.com/repos/sumatrapdfreader/sumatrapdf/releases/latest'
} else {
    $githubResponse = Invoke-RestMethod -Method GET -Uri 'https://api.github.com/repos/sumatrapdfreader/sumatrapdf/releases/latest' -Headers @{ 'User-Agent' = 'action1-sumatra-managed-updater' }
}
$release = Get-SumatraLatestRelease -Response $githubResponse
Write-Step 'github_release_selected' "version=$($release.Version) tag=$($release.TagName) published=$($release.PublishedAt)"

# 2. Resolve + verify installer URL
$installerUrl = Resolve-SumatraInstallerUrl -Version $release.Version
$installerFileName = Resolve-SumatraInstallerFileName -Version $release.Version
Write-Step 'installer_url_resolved' $installerUrl

if (-not $OfflineFixtureRoot) {
    [void](Test-SumatraInstallerUrlAvailable -Url $installerUrl)
}

# 3. Action1 token + package
$requestCommand = $null
if ($OfflineFixtureRoot) {
    $accessToken = (Read-OfflineJson -Name 'action1-token.json').access_token
    $requestCommand = {
        param($Method, $Path, $Body)
        Write-OfflineRequest -Line "$Method $Path"
        if ($Method -eq 'GET' -and $Path -like '/software-repository/*?custom=yes*') { return Read-OfflineJson -Name 'action1-package-list.json' }
        if ($Method -eq 'POST' -and $Path -eq "/software-repository/$($config.Action1OrgId)") { return [pscustomobject]@{ id = 'pkg-created'; name = $Body.name } }
        if ($Method -eq 'GET' -and $Path -like "/software-repository/*$($config.Action1OrgId)*?fields=versions") { return Read-OfflineJson -Name 'action1-package.json' }
        if ($Method -eq 'POST' -and $Path -like '*/versions') { return [pscustomobject]@{ id = 'ver-created'; version = $release.Version } }
        if ($Method -eq 'GET' -and $Path -like '*/versions/*') { return Read-OfflineJson -Name 'action1-version-after-upload.json' }
        throw "Offline request is not defined: $Method $Path"
    }
} else {
    $accessToken = Get-Action1AccessToken -BaseUrl $config.Action1BaseUrl -ClientId $config.Action1ClientId -ClientSecret $config.Action1ClientSecret
}

$packageBody = New-Action1SumatraPackageBody -PackageName $config.PackageName
$package = Ensure-Action1PackageByName -BaseUrl $config.Action1BaseUrl -OrgId $config.Action1OrgId -AccessToken $accessToken -PackageName $config.PackageName -PackageBody $packageBody -RequestCommand $requestCommand
Write-Step 'action1_package_resolved' "id=$($package.id) name=$($package.name)"

# 4. Idempotency
if ($OfflineFixtureRoot) {
    $packageDetails = Read-OfflineJson -Name 'action1-package.json'
} else {
    $packageDetails = Invoke-Action1JsonApi -Method 'GET' -BaseUrl $config.Action1BaseUrl -AccessToken $accessToken -Path "/software-repository/$($config.Action1OrgId)/$($package.id)?fields=versions"
}
$syncAction = Resolve-Action1SumatraVersionSyncAction -Package $packageDetails -Version $release.Version

if ($syncAction -eq 'NoOp') {
    Write-Step 'noop' "version=$($release.Version) already recorded"
    Write-Host "SumatraPDF $($release.Version) is already recorded in Action1 with binary attached."
    exit 0
}

# 5. Resolve / create version
$detectedDate = (Get-Date).ToString('yyyy-MM-dd')
$versionId = $null
if ($syncAction -eq 'CreateAndUpload') {
    $versionBody = New-Action1SumatraVersionBody -Version $release.Version -DetectedDate $detectedDate -PayloadFileName $installerFileName
    if ($OfflineFixtureRoot) {
        Write-OfflineRequest -Line "POST /software-repository/$($config.Action1OrgId)/$($package.id)/versions"
        $created = [pscustomobject]@{ id = 'ver-created'; version = $release.Version }
    } else {
        $created = New-Action1RepositoryVersion -BaseUrl $config.Action1BaseUrl -OrgId $config.Action1OrgId -PackageId $package.id -AccessToken $accessToken -Body $versionBody
    }
    $versionId = $created.id
    Write-Step 'action1_version_create' "id=$versionId"
} else {
    # UploadMissingBinary
    $existingRecord = Get-Action1PackageVersionRecord -Package $packageDetails -BuildVersion $release.Version
    $versionId = $existingRecord.id
    if ([string]::IsNullOrWhiteSpace([string]$versionId)) {
        throw "Action1 package version record for SumatraPDF $($release.Version) did not include an id."
    }
    if ($OfflineFixtureRoot) {
        Write-OfflineRequest -Line "PATCH /software-repository/$($config.Action1OrgId)/$($package.id)/versions/$versionId"
    } else {
        [void](Set-Action1RepositoryVersionPayloadFileName -BaseUrl $config.Action1BaseUrl -OrgId $config.Action1OrgId -PackageId $package.id -VersionId $versionId -AccessToken $accessToken -PayloadFileName $installerFileName)
    }
    Write-Step 'action1_version_existing' "id=$versionId"
}

# 6. Download installer (offline mode uses the fixture file as the installer)
if ($OfflineFixtureRoot) {
    $installerPath = Join-Path $OfflineFixtureRoot 'installer.bin'
    if (-not (Test-Path -LiteralPath $installerPath)) {
        throw "Offline fixture is missing 'installer.bin'."
    }
    $downloadInfo = [pscustomobject]@{
        Path = $installerPath
        SizeBytes = (Get-Item -LiteralPath $installerPath).Length
        Sha256 = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
} else {
    if (-not (Test-Path -LiteralPath $InstallerCacheDir)) { New-Item -ItemType Directory -Path $InstallerCacheDir -Force | Out-Null }
    $installerPath = Join-Path $InstallerCacheDir $installerFileName
    Write-Step 'installer_download_start' $installerPath
    $downloadInfo = Save-SumatraInstaller -Url $installerUrl -Path $installerPath
}
Write-Step 'installer_download_complete' "size=$($downloadInfo.SizeBytes) sha256=$($downloadInfo.Sha256)"

# 7. Upload + verify
Write-Step 'action1_upload_start' "version_id=$versionId file=$installerFileName"
if ($OfflineFixtureRoot) {
    Write-OfflineRequest -Line "UPLOAD /software-repository/$($config.Action1OrgId)/$($package.id)/versions/$versionId/upload"
} else {
    Send-Action1VersionPayload -BaseUrl $config.Action1BaseUrl -OrgId $config.Action1OrgId -PackageId $package.id -VersionId $versionId -AccessToken $accessToken -PayloadPath $downloadInfo.Path
}

if ($OfflineFixtureRoot) {
    $verifyResponse = Read-OfflineJson -Name 'action1-version-after-upload.json'
} else {
    $verifyResponse = Invoke-Action1JsonApi -Method 'GET' -BaseUrl $config.Action1BaseUrl -AccessToken $accessToken -Path "/software-repository/$($config.Action1OrgId)/$($package.id)/versions/$versionId"
}
if (-not (Test-Action1PackageVersionHasWindowsBinary -VersionRecord $verifyResponse)) {
    throw "Action1 version $versionId did not report binary_id.Windows_64 after upload."
}
Write-Step 'verification_success' "version_id=$versionId"

if ($syncAction -eq 'UploadMissingBinary') {
    Write-Host "Uploaded missing Action1 binary for SumatraPDF $($release.Version)."
} else {
    Write-Host "Created Action1 SumatraPDF version $($release.Version) and uploaded installer."
}
```

- [ ] **Step 2: Smoke test the script in dry-run-style mode**

There is no separate dry-run mode. The script will be exercised through the offline fixture in Task 14.

- [ ] **Step 3: Commit**

```
git add src/
git commit -m "feat(sync): orchestrator script for github -> action1 sync"
```

---

### Task 14: Offline-fixture integration test

**Files:**
- Create: `tests/fixtures/sync/github-release-latest.json`
- Create: `tests/fixtures/sync/action1-token.json`
- Create: `tests/fixtures/sync/action1-package-list.json`
- Create: `tests/fixtures/sync/action1-package.json`
- Create: `tests/fixtures/sync/action1-version-after-upload.json`
- Create: `tests/fixtures/sync/installer.bin`
- Modify: `tests/SumatraManagedUpdate.Tests.ps1`

Drives the sync script through every branch using canned JSON. Asserts the exact sequence of API calls written to `api-requests.log`.

- [ ] **Step 1: Create the fixture files**

`tests/fixtures/sync/github-release-latest.json`:

```json
{
  "tag_name": "3.6.1rel",
  "published_at": "2026-04-06T13:47:05Z",
  "draft": false,
  "prerelease": false
}
```

`tests/fixtures/sync/action1-token.json`:

```json
{ "access_token": "fixture-token-abc123" }
```

`tests/fixtures/sync/action1-package-list.json`:

```json
{ "items": [] }
```

`tests/fixtures/sync/action1-package.json` (the package response *after* the version is created — still has no binary, drives the CreateAndUpload path):

```json
{
  "id": "pkg-created",
  "name": "SumatraPDF",
  "versions": { "items": [] }
}
```

`tests/fixtures/sync/action1-version-after-upload.json` (post-upload re-fetch, must report Windows_64 binary):

```json
{
  "id": "ver-created",
  "version": "3.6.1",
  "binary_id": { "Windows_64": "bin-uploaded-xyz" },
  "file_name": { "Windows_64": { "name": "SumatraPDF-3.6.1-64-install.exe", "type": "cloud" } }
}
```

`tests/fixtures/sync/installer.bin`: 16 arbitrary bytes:

```powershell
[IO.File]::WriteAllBytes('tests/fixtures/sync/installer.bin', [byte[]](0..15))
```

- [ ] **Step 2: Append the integration test**

```powershell
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
```

- [ ] **Step 3: Add fixture log to `.gitignore`**

```
echo 'tests/fixtures/sync/api-requests.log' >> .gitignore
```

(Already covered by the Task 1 `.gitignore` pattern `tests/fixtures/**/api-requests.log`. Verify with `git check-ignore tests/fixtures/sync/api-requests.log` — should print the path.)

- [ ] **Step 4: Run tests green**

```
pwsh -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
```

- [ ] **Step 5: Commit**

```
git add tests/fixtures/ tests/SumatraManagedUpdate.Tests.ps1 .gitignore
git commit -m "test: end-to-end offline integration for sync script"
```

---

### Task 15: container/entrypoint.ps1

**Files:**
- Create: `container/entrypoint.ps1`

Direct port of `/tmp/fusion-ref/container/entrypoint.ps1`. The only changes are import paths and the script the entrypoint invokes.

- [ ] **Step 1: Create the file**

```powershell
#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [string]$SyncScriptPath = '/app/src/Sync-SumatraAction1Release.ps1'
)

$ErrorActionPreference = 'Stop'

Import-Module '/app/src/SumatraManagedUpdate.Common.psm1' -Force

$config = Get-SumatraContainerRuntimeConfig
$schedule = New-SumatraContainerScheduleCommand -Config $config -SyncScriptPath $SyncScriptPath

$null = Invoke-SumatraContainerStartupSync -OneShot $config.OneShot -SyncCommand {
    Invoke-SumatraContainerSyncOnce -ScriptPath $SyncScriptPath
}

if ($config.OneShot) {
    exit 0
}

if ($schedule.Kind -eq 'Interval') {
    while ($true) {
        Start-Sleep -Seconds $schedule.Seconds
        try {
            Invoke-SumatraContainerSyncOnce -ScriptPath $SyncScriptPath
        }
        catch {
            Write-Error $_ -ErrorAction Continue
        }
    }
}

$envFile = '/etc/action1-sumatra-container.env'
$envSpec = New-SumatraContainerCronEnvironmentSpec
$envSpec.Lines | Set-Content -LiteralPath $envFile -Encoding ASCII
chmod $envSpec.Mode $envFile

$runner = '/usr/local/bin/action1-sumatra-sync.sh'
@(
    '#!/usr/bin/env bash'
    'set -a'
    ". $envFile"
    'set +a'
    $schedule.Command
) | Set-Content -LiteralPath $runner -Encoding ASCII
chmod +x $runner

$cronFile = '/etc/cron.d/action1-sumatra-sync'
"$($schedule.Expression) root $runner >> /proc/1/fd/1 2>> /proc/1/fd/2" | Set-Content -LiteralPath $cronFile -Encoding ASCII
chmod 0644 $cronFile

& /usr/sbin/cron -f
```

- [ ] **Step 2: Commit**

```
git add container/
git commit -m "feat(container): port entrypoint from fusion"
```

---

### Task 16: Dockerfile + docker-compose.example.yml

**Files:**
- Create: `Dockerfile`
- Create: `docker-compose.example.yml`

- [ ] **Step 1: Create `Dockerfile`**

```dockerfile
FROM mcr.microsoft.com/powershell:7.4-ubuntu-22.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends cron ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY src/ ./src/
COPY container/ ./container/

ENTRYPOINT ["pwsh", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "/app/container/entrypoint.ps1"]
```

(Note: no `RUN pwsh ./packaging/build-action1-payload.ps1` step — Sumatra has no compiled payload. `curl` is added explicitly because `Save-SumatraInstaller` prefers it.)

- [ ] **Step 2: Create `docker-compose.example.yml`**

```yaml
services:
  remote-image:
    image: brownindustries/action1-sumatra-managed-updater:latest
    environment:
      ACTION1_CLIENT_ID: "REPLACE_ME"
      ACTION1_CLIENT_SECRET: "REPLACE_ME"
      ACTION1_ORG_ID: "all"
      ONE_SHOT: "false"
      CHECK_FREQUENCY_MINUTES: "1440"

  local-build:
    build:
      context: .
      dockerfile: Dockerfile
    environment:
      ACTION1_CLIENT_ID: "REPLACE_ME"
      ACTION1_CLIENT_SECRET: "REPLACE_ME"
      ACTION1_ORG_ID: "all"
```

- [ ] **Step 3: Build the image locally to verify it builds**

```
docker build -t action1-sumatra-managed-updater:dev .
```

Expected: image builds successfully with no errors. The `docker build` command is the verification — no need to run the image (running requires real Action1 credentials).

- [ ] **Step 4: Commit**

```
git add Dockerfile docker-compose.example.yml
git commit -m "feat(docker): build image with pwsh + cron"
```

---

## Phase 5 — CI + docs

### Task 17: GitHub Actions publish workflow

**Files:**
- Create: `.github/workflows/docker-publish.yml`

Direct port of `/tmp/fusion-ref/.github/workflows/docker-publish.yml`. Only the `IMAGE_NAME` env var changes.

- [ ] **Step 1: Create the workflow**

Copy `/tmp/fusion-ref/.github/workflows/docker-publish.yml` verbatim, then change line `IMAGE_NAME: brownindustries/action1-fusion-managed-updater` to `IMAGE_NAME: brownindustries/action1-sumatra-managed-updater`. No other edits.

- [ ] **Step 2: Validate YAML locally**

```
pwsh -NoProfile -Command "Get-Content .github/workflows/docker-publish.yml | Out-Null"
```

(No YAML lint installed by default; the basic file-readable check is enough. Real validation happens when GitHub processes it.)

- [ ] **Step 3: Commit**

```
git add .github/
git commit -m "ci: port docker publish workflow from fusion"
```

---

### Task 18: README.md

**Files:**
- Create: `README.md`

Adapts the structure of Fusion's README to Sumatra. Drops sections that don't apply (no `dist/` payload build, no watcher dry-run, no live watcher environment, no endpoint lab install/update test).

- [ ] **Step 1: Create `README.md`**

```markdown
# SumatraPDF Action1 Managed Updater

Stateless Action1 updater for SumatraPDF. Each Action1 package version is a real,
pinned 64-bit Windows installer that can be deployed to any endpoint independently
of the latest release.

## How it works

On each run the container:

1. Queries `GET https://api.github.com/repos/sumatrapdfreader/sumatrapdf/releases/latest`
2. Constructs the installer URL as `https://www.sumatrapdfreader.org/dl/rel/{version}/SumatraPDF-{version}-64-install.exe`
3. HEAD-verifies the URL returns 200 with a non-zero `Content-Length`
4. Authenticates to Action1 (OAuth2 client credentials)
5. Finds or creates the Action1 package named `SumatraPDF` (or `PACKAGE_NAME`)
6. If the latest version is already recorded with a binary attached, exits 0 (NoOp)
7. Otherwise downloads the installer, creates the version, uploads the binary, and
   re-fetches to verify `binary_id.Windows_64` is set

## Run tests

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

## Container usage

The intended public image is:

```
brownindustries/action1-sumatra-managed-updater:latest
```

One-shot mode is the default:

```bash
docker run --rm \
  -e ACTION1_CLIENT_ID="..." \
  -e ACTION1_CLIENT_SECRET="..." \
  -e ACTION1_ORG_ID="all" \
  brownindustries/action1-sumatra-managed-updater:latest
```

Long-running mode starts once immediately, then checks on an interval or cron schedule:

```bash
docker run -d --name action1-sumatra-updater \
  -e ACTION1_CLIENT_ID="..." \
  -e ACTION1_CLIENT_SECRET="..." \
  -e ONE_SHOT="false" \
  -e CHECK_FREQUENCY_MINUTES="1440" \
  brownindustries/action1-sumatra-managed-updater:latest
```

`CHECK_FREQUENCY_CRON` can be used instead of `CHECK_FREQUENCY_MINUTES` for standard
five-field cron expressions.

### Environment variables

| Name | Required | Default | Purpose |
| --- | --- | --- | --- |
| `ACTION1_CLIENT_ID` | yes | none | Action1 API client ID |
| `ACTION1_CLIENT_SECRET` | yes | none | Action1 API client secret |
| `ACTION1_BASE_URL` | no | `https://app.action1.com/api/3.0` | Action1 API base URL |
| `ACTION1_ORG_ID` | no | `all` | Action1 organization scope |
| `PACKAGE_NAME` | no | `SumatraPDF` | Action1 custom package name |
| `ONE_SHOT` | no | `true` | `true` exits after one sync; `false` keeps scheduling |
| `CHECK_FREQUENCY_MINUTES` | no | `1440` | Interval used when `ONE_SHOT=false` and no cron is set |
| `CHECK_FREQUENCY_CRON` | no | none | Cron schedule used when `ONE_SHOT=false` |

GitHub API is used at the anonymous rate limit (60 req/hr). At one sync per day this
is one request per run; keep `CHECK_FREQUENCY_MINUTES` reasonable.

## Public image publishing

`.github/workflows/docker-publish.yml` builds and publishes to Docker Hub as
`brownindustries/action1-sumatra-managed-updater`.

Publishing events match the Fusion repo convention:

- Pull requests build the image but do not log in to Docker Hub and do not push
- Pushes to the default branch publish `latest`, branch, and `sha-*` tags
- `v*` tag pushes publish the matching version tag and `sha-*` tag
- Manual workflow runs publish only when run from the default branch or a `v*` tag
- If Docker Hub secrets are missing, eligible publish runs build only and emit a warning

Required GitHub repository secrets:

```
DOCKER_HUB_REG_USERNAME
DOCKER_HUB_REG_PASSWORD
```

## Recommended deployment

1. Run tests: `pwsh ./tests/run-tests.ps1`
2. Build the image locally: `docker build -t action1-sumatra-managed-updater:dev .`
3. If a `SumatraPDF` package already exists in your Action1 tenant with a different
   shape (e.g. created manually before this updater existed), reconcile it
   (rename, delete, or accept reuse).
4. Run one-shot against the live tenant: `docker run --rm -e ACTION1_CLIENT_ID=... -e ACTION1_CLIENT_SECRET=... action1-sumatra-managed-updater:dev`
5. Confirm the new version is created with the correct binary attached in the Action1 UI
6. Deploy the version to one pilot endpoint via Action1 and confirm install
7. Switch the container to scheduled mode (`ONE_SHOT=false`) for ongoing automation
```

- [ ] **Step 2: Commit**

```
git add README.md
git commit -m "docs: README with run, deploy, and environment reference"
```

---

## Self-review (post-plan)

The plan author runs this checklist before handing off.

**Spec coverage:**

- Repo + image name: covered by Task 16 + Task 17 (Dockerfile + workflow target the right names)
- Repo layout (per spec § Repo layout): covered (Tasks 1, 2, 9–18)
- Data flow steps 1–6: Task 13 implements all six in sequence
- New-Action1SumatraVersionBody fields exactly as specified: Task 8
- Hard-fail conditions: Tasks 5, 6, 8, 12 cover GitHub parsing, URL HEAD, body validation, host-match check; Task 14's integration test exercises the success path. Failure-path unit coverage is in the individual TDD tasks, not in the integration test.
- NoOp path: covered by `Resolve-Action1SumatraVersionSyncAction` (Task 11) and Task 13's branching
- Env var table: Task 9 verifies defaults including `PackageName='SumatraPDF'`
- Run modes (one-shot / interval / cron): Task 15 entrypoint handles all three; Task 10 tests schedule resolution
- Logging step prefixes: Task 13 emits `SUMATRA_STEP github_query_start`, `github_release_selected`, `installer_url_resolved`, `installer_download_start`, `installer_download_complete`, `action1_package_resolved`, `action1_version_create`, `action1_version_existing`, `action1_upload_start`, `verification_success`, `noop` — matches the spec list
- Offline unit tests: covered by Tasks 3–12 (homegrown runner per the Fusion convention; spec was updated to match before this plan was committed)
- Offline-fixture integration test: Task 14
- CI: Task 17

**Placeholder scan:** searched the plan for "TODO", "TBD", "implement later", "fill in", "appropriate", "similar to Task" — none present. All code blocks contain runnable code, all commands have expected output described.

**Type/name consistency:** function names verified across tasks. `Resolve-SumatraInstallerFileName` (Task 4) referenced in Task 13. `Get-SumatraLatestRelease` (Task 5) returns `.Version`/`.TagName`/`.PublishedAt`, used correctly in Task 13. `Save-SumatraInstaller` (Task 7) returns `.Path`/`.SizeBytes`/`.Sha256`, used correctly in Task 13. `Resolve-Action1SumatraVersionSyncAction` (Task 11) — *note this name*, not `Resolve-Action1VersionSyncAction` (which was the Fusion name and is dropped from `Action1Repository.psm1` per Task 12). Task 13 uses the correct Sumatra-specific name. `Ensure-Action1PackageByName` signature gained `-PackageBody` parameter in Task 12 and Task 13 passes the body — consistent.

---

## Done

After Task 18, the repo has:

- A working stateless container that syncs the latest stable SumatraPDF release into a pinned Action1 package version
- Tests covering tag normalization, URL construction, GitHub parsing, HEAD verification, download, body builders, runtime config, schedule helpers, Action1 version-record helpers, package selection, host-match validation, and a full offline integration sweep
- CI publishing the image to `brownindustries/action1-sumatra-managed-updater` on default-branch + `v*` tag pushes
- README documenting environment, run modes, and deployment runbook
- Spec and plan committed under `docs/superpowers/`
