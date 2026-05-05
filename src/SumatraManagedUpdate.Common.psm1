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

function Test-Action1PackageVersionContainerPresent {
    param([Parameter(Mandatory = $true)]$Package)

    return $null -ne $Package.PSObject.Properties['versions']
}

function Get-Action1PackageVersionRecords {
    param([Parameter(Mandatory = $true)]$Package)

    $containers = @()
    foreach ($propertyName in @('versions', 'version')) {
        $property = $Package.PSObject.Properties[$propertyName]
        if ($property) {
            $containers += $property.Value
        }
    }

    $records = @()
    foreach ($container in $containers) {
        if ($null -eq $container) {
            continue
        }

        $nestedItems = $null
        foreach ($nestedName in @('items', 'data', 'results')) {
            $nestedProperty = $container.PSObject.Properties[$nestedName]
            if ($nestedProperty) {
                $nestedItems = $nestedProperty.Value
                break
            }
        }

        if ($null -ne $nestedItems) {
            $records += @($nestedItems)
        }
        else {
            $records += @($container)
        }
    }

    return $records
}

function Get-Action1PackageVersionValues {
    param([Parameter(Mandatory = $true)]$Package)

    $versions = @()
    foreach ($item in (Get-Action1PackageVersionRecords -Package $Package)) {
        if ($null -eq $item) {
            continue
        }
        if ($item -is [string]) {
            $versions += $item
            continue
        }

        $valueFound = $false
        foreach ($versionPropertyName in @('version')) {
            $versionProperty = $item.PSObject.Properties[$versionPropertyName]
            if ($versionProperty -and -not [string]::IsNullOrWhiteSpace([string]$versionProperty.Value)) {
                $versions += [string]$versionProperty.Value
                $valueFound = $true
                break
            }
        }
        if ($valueFound) {
            continue
        }

        $fieldsProperty = $item.PSObject.Properties['fields']
        if ($fieldsProperty) {
            $fieldVersion = $fieldsProperty.Value.PSObject.Properties['Version']
            if ($fieldVersion -and -not [string]::IsNullOrWhiteSpace([string]$fieldVersion.Value)) {
                $versions += [string]$fieldVersion.Value
            }
        }
    }

    return $versions
}

function Test-Action1PackageHasVersion {
    param(
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)][string]$BuildVersion
    )

    $versions = @(Get-Action1PackageVersionValues -Package $Package)
    return $versions -contains $BuildVersion
}

function Get-Action1PackageVersionRecord {
    param(
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)][string]$BuildVersion
    )

    foreach ($record in (Get-Action1PackageVersionRecords -Package $Package)) {
        if ($null -eq $record) {
            continue
        }
        $versionProperty = $record.PSObject.Properties['version']
        if ($versionProperty -and ([string]$versionProperty.Value) -eq $BuildVersion) {
            return $record
        }

        $fieldsProperty = $record.PSObject.Properties['fields']
        if ($fieldsProperty) {
            $fieldVersion = $fieldsProperty.Value.PSObject.Properties['Version']
            if ($fieldVersion -and ([string]$fieldVersion.Value) -eq $BuildVersion) {
                return $record
            }
        }
    }
    return $null
}

function Test-Action1PackageVersionHasWindowsBinary {
    param($VersionRecord)

    if ($null -eq $VersionRecord) { return $false }
    $binaryProperty = $VersionRecord.PSObject.Properties['binary_id']
    if (-not $binaryProperty) { return $false }
    if ($null -eq $binaryProperty.Value) { return $false }
    $windowsBinary = $binaryProperty.Value.PSObject.Properties['Windows_64']
    return $windowsBinary -and -not [string]::IsNullOrWhiteSpace([string]$windowsBinary.Value)
}

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

Export-ModuleMember -Function ConvertTo-SumatraVersion, Assert-SumatraVersionString, Resolve-SumatraInstallerFileName, Resolve-SumatraInstallerUrl, Get-SumatraLatestRelease, Test-SumatraInstallerUrlAvailable, Save-SumatraInstaller, New-Action1SumatraVersionBody, New-Action1SumatraPackageBody, Get-SumatraSettingValue, ConvertTo-SumatraBooleanSetting, Get-SumatraContainerRuntimeConfig, ConvertTo-SumatraBashSingleQuotedArgument, Assert-SumatraContainerCronExpression, New-SumatraContainerScheduleCommand, New-SumatraContainerCronEnvironmentSpec, Invoke-SumatraContainerSyncOnce, Invoke-SumatraContainerStartupSync, Test-Action1PackageVersionContainerPresent, Get-Action1PackageVersionRecords, Get-Action1PackageVersionValues, Test-Action1PackageHasVersion, Get-Action1PackageVersionRecord, Test-Action1PackageVersionHasWindowsBinary, Resolve-Action1SumatraVersionSyncAction
