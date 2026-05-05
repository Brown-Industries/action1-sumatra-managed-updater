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

function Get-Timestamp {
    return [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Write-Log {
    param([Parameter(Mandatory = $true)][string]$Message)
    # [Console]::WriteLine is robust against PowerShell-in-Docker where Write-Host can silently
    # drop output when no TTY is attached. Goes straight to stdout.
    [Console]::Out.WriteLine("[$(Get-Timestamp)] $Message")
    [Console]::Out.Flush()
}

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Name, [string]$Detail = '')
    $body = if ([string]::IsNullOrWhiteSpace($Detail)) { "SUMATRA_STEP $Name" } else { "SUMATRA_STEP $Name $Detail" }
    Write-Log $body
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
$package = Resolve-Action1PackageByName -BaseUrl $config.Action1BaseUrl -OrgId $config.Action1OrgId -AccessToken $accessToken -PackageName $config.PackageName -PackageBody $packageBody -RequestCommand $requestCommand
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
    Write-Log "SumatraPDF $($release.Version) is already recorded in Action1 with binary attached."
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
    Write-Log "Uploaded missing Action1 binary for SumatraPDF $($release.Version)."
} else {
    Write-Log "Created Action1 SumatraPDF version $($release.Version) and uploaded installer."
}
