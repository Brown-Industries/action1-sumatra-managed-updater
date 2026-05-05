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

Export-ModuleMember -Function ConvertTo-SumatraVersion, Assert-SumatraVersionString, Resolve-SumatraInstallerFileName, Resolve-SumatraInstallerUrl, Get-SumatraLatestRelease, Test-SumatraInstallerUrlAvailable
