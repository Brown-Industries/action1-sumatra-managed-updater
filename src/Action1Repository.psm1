$commonModulePath = Join-Path $PSScriptRoot 'SumatraManagedUpdate.Common.psm1'
Import-Module $commonModulePath

function ConvertTo-Action1FormValue {
    param([string]$Value)
    return [uri]::EscapeDataString($Value).Replace('%20', '+')
}

function New-Action1TokenRequestBody {
    param(
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$ClientSecret
    )

    return "grant_type=client_credentials&client_id=$(ConvertTo-Action1FormValue -Value $ClientId)&client_secret=$(ConvertTo-Action1FormValue -Value $ClientSecret)"
}

function Select-Action1PackageByExactName {
    param(
        [Parameter(Mandatory = $true)]$Packages,
        [Parameter(Mandatory = $true)][string]$PackageName
    )

    $matches = @($Packages.items | Where-Object {
        ([string]$_.name).Equals($PackageName, [System.StringComparison]::OrdinalIgnoreCase)
    })

    if ($matches.Count -gt 1) {
        throw "Multiple Action1 packages match PACKAGE_NAME '$PackageName'. Rename or remove duplicates before running automation."
    }
    if ($matches.Count -eq 0) {
        return $null
    }
    return $matches[0]
}

function Get-Action1AccessToken {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$ClientSecret
    )

    $tokenUrl = "$($BaseUrl.TrimEnd('/'))/oauth2/token"
    $response = Invoke-RestMethod -Method Post -Uri $tokenUrl -ContentType 'application/x-www-form-urlencoded' -Body (New-Action1TokenRequestBody -ClientId $ClientId -ClientSecret $ClientSecret)
    if ([string]::IsNullOrWhiteSpace([string]$response.access_token)) {
        throw 'Action1 token response did not include access_token.'
    }
    return [string]$response.access_token
}

function Invoke-Action1JsonApi {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'POST', 'PATCH')][string]$Method,
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [Parameter(Mandatory = $true)][string]$Path,
        [object]$Body = $null
    )

    $headers = @{ Authorization = "Bearer $AccessToken" }
    $uri = "$($BaseUrl.TrimEnd('/'))/$($Path.TrimStart('/'))"
    if ($null -ne $Body) {
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Depth 20)
    }
    return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
}

function Invoke-Action1RequestCommand {
    param(
        [scriptblock]$RequestCommand,
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        [object]$Body = $null,
        [string]$BaseUrl = '',
        [string]$AccessToken = ''
    )

    if ($RequestCommand) {
        return & $RequestCommand $Method $Path $Body
    }
    return Invoke-Action1JsonApi -Method $Method -BaseUrl $BaseUrl -AccessToken $AccessToken -Path $Path -Body $Body
}

function Ensure-Action1PackageByName {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$OrgId,
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [Parameter(Mandatory = $true)][string]$PackageName,
        [Parameter(Mandatory = $true)]$PackageBody,
        [scriptblock]$RequestCommand = $null
    )

    $filter = [uri]::EscapeDataString($PackageName)
    $packages = Invoke-Action1RequestCommand -RequestCommand $RequestCommand -Method 'GET' -Path "/software-repository/$OrgId`?custom=yes&filter=$filter&fields=*&limit=100" -BaseUrl $BaseUrl -AccessToken $AccessToken
    $existing = Select-Action1PackageByExactName -Packages $packages -PackageName $PackageName
    if ($null -ne $existing) {
        return $existing
    }

    return Invoke-Action1RequestCommand -RequestCommand $RequestCommand -Method 'POST' -Path "/software-repository/$OrgId" -Body $PackageBody -BaseUrl $BaseUrl -AccessToken $AccessToken
}

function Assert-Action1PositivePayloadLength {
    param([Parameter(Mandatory = $true)][long]$PayloadLength)

    if ($PayloadLength -lt 1) {
        throw 'PayloadLength must be at least 1.'
    }
}

function New-Action1UploadInitHeaders {
    param(
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [Parameter(Mandatory = $true)][long]$PayloadLength
    )

    Assert-Action1PositivePayloadLength -PayloadLength $PayloadLength

    @{
        Authorization             = "Bearer $AccessToken"
        'X-Upload-Content-Type'   = 'application/octet-stream'
        'X-Upload-Content-Length' = [string]$PayloadLength
    }
}

function New-Action1UploadPutHeaders {
    param(
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [Parameter(Mandatory = $true)][long]$PayloadLength
    )

    Assert-Action1PositivePayloadLength -PayloadLength $PayloadLength

    @{
        Authorization   = "Bearer $AccessToken"
        'Content-Range' = "bytes 0-$($PayloadLength - 1)/$PayloadLength"
    }
}

function Set-Action1RepositoryVersionPayloadFileName {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$OrgId,
        [Parameter(Mandatory = $true)][string]$PackageId,
        [Parameter(Mandatory = $true)][string]$VersionId,
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [Parameter(Mandatory = $true)][string]$PayloadFileName
    )

    $body = @{
        file_name = @{
            Windows_64 = @{
                name = $PayloadFileName
                type = 'cloud'
            }
        }
    }
    return Invoke-Action1JsonApi -Method 'PATCH' -BaseUrl $BaseUrl -AccessToken $AccessToken -Path "/software-repository/$OrgId/$PackageId/versions/$VersionId" -Body $body
}

function New-Action1RepositoryVersion {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$OrgId,
        [Parameter(Mandatory = $true)][string]$PackageId,
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [Parameter(Mandatory = $true)]$Body
    )

    return Invoke-Action1JsonApi -Method 'POST' -BaseUrl $BaseUrl -AccessToken $AccessToken -Path "/software-repository/$OrgId/$PackageId/versions" -Body $Body
}

function Invoke-Action1UploadRequest {
    param(
        [scriptblock]$RequestCommand = $null,
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)]$Headers,
        [Parameter(Mandatory = $true)][string]$ContentType,
        [Parameter(Mandatory = $true)]$Body,
        [switch]$SkipHttpErrorCheck
    )

    if ($RequestCommand) {
        return & $RequestCommand $Method $Uri $Headers $ContentType $Body
    }

    $parameters = @{
        Method      = $Method
        Uri         = $Uri
        Headers     = $Headers
        ContentType = $ContentType
        Body        = $Body
    }
    if ($SkipHttpErrorCheck -and (Get-Command Invoke-WebRequest).Parameters.ContainsKey('SkipHttpErrorCheck')) {
        $parameters.SkipHttpErrorCheck = $true
    }
    return Invoke-WebRequest @parameters
}

function Test-Action1SuccessStatusCode {
    param([object]$StatusCode)

    $status = 0
    if (-not [int]::TryParse([string]$StatusCode, [ref]$status)) {
        return $false
    }
    return ($status -ge 200 -and $status -lt 300)
}

function Test-Action1UploadInitStatusCode {
    param([object]$StatusCode)

    $status = 0
    if (-not [int]::TryParse([string]$StatusCode, [ref]$status)) {
        return $false
    }
    return ((Test-Action1SuccessStatusCode -StatusCode $status) -or $status -eq 308)
}

function Assert-Action1UploadLocationAllowed {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$UploadLocation,
        [Parameter(Mandatory = $true)][string]$PackageId,
        [Parameter(Mandatory = $true)][string]$VersionId
    )

    try {
        $baseUri = [uri]$BaseUrl
        $uploadUri = [uri]$UploadLocation
    }
    catch {
        throw "Action1 upload initialization returned an invalid upload location for package '$PackageId' version '$VersionId'."
    }

    if (-not $uploadUri.IsAbsoluteUri -or $uploadUri.Scheme -ne $baseUri.Scheme -or $uploadUri.Host -ne $baseUri.Host -or $uploadUri.Port -ne $baseUri.Port) {
        throw "Action1 upload initialization returned an unexpected host or scheme for package '$PackageId' version '$VersionId'."
    }

    return $uploadUri.AbsoluteUri
}

function Send-Action1VersionPayload {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$OrgId,
        [Parameter(Mandatory = $true)][string]$PackageId,
        [Parameter(Mandatory = $true)][string]$VersionId,
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [Parameter(Mandatory = $true)][string]$PayloadPath,
        [scriptblock]$RequestCommand = $null
    )

    $payloadBytes = [IO.File]::ReadAllBytes($PayloadPath)
    if ($payloadBytes.Length -lt 1) {
        throw "Action1 payload file must not be empty for package '$PackageId' version '$VersionId'."
    }

    $initUri = "$($BaseUrl.TrimEnd('/'))/software-repository/$OrgId/$PackageId/versions/$VersionId/upload?platform=Windows_64"
    try {
        $initResponse = Invoke-Action1UploadRequest -RequestCommand $RequestCommand -Method 'POST' -Uri $initUri -Headers (New-Action1UploadInitHeaders -AccessToken $AccessToken -PayloadLength $payloadBytes.Length) -ContentType 'application/json' -Body '{}' -SkipHttpErrorCheck
    }
    catch {
        $statusCode = $null
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        if ($statusCode -eq 308 -and $_.Exception.Response) {
            $initResponse = [pscustomobject]@{
                StatusCode = $statusCode
                Headers    = $_.Exception.Response.Headers
            }
        }
        elseif ($null -ne $statusCode) {
            throw "Action1 upload init failed for package '$PackageId' version '$VersionId' with status code $statusCode."
        }
        else {
            throw "Action1 upload init failed for package '$PackageId' version '$VersionId'."
        }
    }
    if (-not (Test-Action1UploadInitStatusCode -StatusCode $initResponse.StatusCode)) {
        if ($null -ne $statusCode) {
            throw "Action1 upload init failed for package '$PackageId' version '$VersionId' with status code $statusCode."
        }
        throw "Action1 upload initialization failed for package '$PackageId' version '$VersionId' with status code $($initResponse.StatusCode)."
    }

    $uploadLocation = [string]($initResponse.Headers['X-Upload-Location'] | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($uploadLocation)) {
        throw "Action1 upload initialization did not return X-Upload-Location for package '$PackageId' version '$VersionId'."
    }
    $validatedUploadLocation = Assert-Action1UploadLocationAllowed -BaseUrl $BaseUrl -UploadLocation $uploadLocation -PackageId $PackageId -VersionId $VersionId

    try {
        $putResponse = Invoke-Action1UploadRequest -RequestCommand $RequestCommand -Method 'PUT' -Uri $validatedUploadLocation -Headers (New-Action1UploadPutHeaders -AccessToken $AccessToken -PayloadLength $payloadBytes.Length) -ContentType 'application/octet-stream' -Body $payloadBytes
    }
    catch {
        throw "Action1 upload PUT failed for package '$PackageId' version '$VersionId'."
    }

    if ($null -ne $putResponse -and -not (Test-Action1SuccessStatusCode -StatusCode $putResponse.StatusCode)) {
        throw "Action1 upload PUT failed for package '$PackageId' version '$VersionId' with status code $($putResponse.StatusCode)."
    }
}

Export-ModuleMember -Function ConvertTo-Action1FormValue, New-Action1TokenRequestBody, Select-Action1PackageByExactName, Get-Action1AccessToken, Invoke-Action1JsonApi, Invoke-Action1RequestCommand, Ensure-Action1PackageByName, Assert-Action1PositivePayloadLength, New-Action1UploadInitHeaders, New-Action1UploadPutHeaders, Set-Action1RepositoryVersionPayloadFileName, New-Action1RepositoryVersion, Invoke-Action1UploadRequest, Test-Action1SuccessStatusCode, Test-Action1UploadInitStatusCode, Assert-Action1UploadLocationAllowed, Send-Action1VersionPayload
