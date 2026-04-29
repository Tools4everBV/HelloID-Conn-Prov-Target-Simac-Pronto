############################################################
# HelloID-Conn-Prov-Target-Simac-Pronto-Permissions-PersonsGroup
# PowerShell V2
############################################################

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

#region functions
function Resolve-Simac-ProntoError {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object]
        $ErrorObject
    )
    process {
        $httpErrorObj = [PSCustomObject]@{
            ScriptLineNumber = $ErrorObject.InvocationInfo.ScriptLineNumber
            Line             = $ErrorObject.InvocationInfo.Line
            ErrorDetails     = $ErrorObject.Exception.Message
            FriendlyMessage  = $ErrorObject.Exception.Message
        }
        if (-not [string]::IsNullOrEmpty($ErrorObject.ErrorDetails.Message)) {
            $httpErrorObj.ErrorDetails = $ErrorObject.ErrorDetails.Message
        }
        elseif ($ErrorObject.Exception.GetType().FullName -eq 'System.Net.WebException') {
            if ($null -ne $ErrorObject.Exception.Response) {
                $streamReaderResponse = [System.IO.StreamReader]::new($ErrorObject.Exception.Response.GetResponseStream()).ReadToEnd()
                if (-not [string]::IsNullOrEmpty($streamReaderResponse)) {
                    $httpErrorObj.ErrorDetails = $streamReaderResponse
                }
            }
        }
        try {
            $errorDetailsObject = ($httpErrorObj.ErrorDetails | ConvertFrom-Json)
            $httpErrorObj.FriendlyMessage = $errorDetailsObject.message
        }
        catch {
            $httpErrorObj.FriendlyMessage = $httpErrorObj.ErrorDetails
            Write-Warning $_.Exception.Message
        }
        Write-Output $httpErrorObj
    }
}

function Get-AccessToken {
    [CmdletBinding()]
    param ()
    try {
        $splatTokenParams = @{
            Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/auth/token"
            Method  = 'POST'
            Headers = @{
                'accept' = 'application/json'
            }
            Body    = @{
                username = $actionContext.Configuration.UserName
                password = $actionContext.Configuration.Password
            }
        }
        # Wait 6 seconds in order to prevent error Too Many Requests
        Start-Sleep -Seconds  6

        $token = Invoke-RestMethod @splatTokenParams #-Verbose:$false

        Write-Output $token.token
    }
    catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}
#endregion

try {
    Write-Information 'Retrieving permissions'

    $accessToken = Get-AccessToken

    $headers = @{
        Authorization  = "Bearer $($accessToken)"
        'content-type' = 'application/json'
        Accept         = 'application/json'
    }

    $allRetrievedPermissions = [System.Collections.Generic.List[object]]::new()

    $pageNumber = 1
    do {
        $splatImportPermissionsParams = @{
            Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/personsgroups?page=$($pageNumber)&active=true"
            Method  = 'GET'
            Headers = $headers
        }
        $retrievedPermissions = Invoke-RestMethod @splatImportPermissionsParams

        
        if ($retrievedPermissions.data) {
            foreach ($permission in $retrievedPermissions.data) {
                $allRetrievedPermissions.Add($permission)                
            }
            
        }
        $itemsOnPage = $retrievedPermissions.meta.to - $retrievedPermissions.meta.from + 1
        $pageNumber++
    } while ($itemsOnPage -eq $retrievedPermissions.meta.per_page)

    $parentPermissions = $allRetrievedPermissions | Group-Object -Property id -AsHashTable

    foreach ($permission in $allRetrievedPermissions) {
        $displayName = $permission.Name
        if ($null -ne $permission.ParentId) {
            $displayName = "$($parentPermissions[$permission.ParentId].Name) - $($permission.Name)"
        }
        $outputContext.Permissions.Add(
            @{
                DisplayName    = $displayName
                Identification = @{
                    Reference = "$($permission.Id)"
                }
            }
        )
    }
}
catch {
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-Simac-ProntoError -ErrorObject $ex
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
}