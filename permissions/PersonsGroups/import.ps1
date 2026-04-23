####################################################################
# HelloID-Conn-Prov-Target-Simac-Pronto-ImportPermissions-PersonsGroup
# PowerShell V2
####################################################################

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
        $token = Invoke-RestMethod @splatTokenParams #-Verbose:$false

        # Wait 6 seconds in order to prevent error Too Many Requests
        Start-Sleep -Seconds  6

        Write-Output $token.token
    }
    catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}
#endregion

try {
    Write-Information 'Starting Simac-Pronto permission entitlement import'

    $accessToken = Get-AccessToken

    $headers = @{
        Authorization  = "Bearer $($accessToken)"
        'content-type' = 'application/json'
        Accept         = 'application/json'
    }

    $pageNumber = 1
    $importedAccounts = @()
    do {
        $splatImportAccountParams = @{
            Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/persons/?page=$($pageNumber)"
            Method  = 'GET'
            Headers = $headers
        }
        $response = Invoke-RestMethod @splatImportAccountParams

        if ($response.data) {
            $importedAccounts += $response.data | Select-Object -Property Id, PersonsGroups
        }
        $itemsOnPage = $response.meta.to - $response.meta.from + 1
        $pageNumber++
    } while ($itemsOnPage -eq $response.meta.per_page)


    $allRetrievedPermissions = [System.Collections.Generic.List[object]]::new()

    $pageNumber = 1
    do {
        $splatImportPermissionParams = @{
            Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/personsgroups?page=$($pageNumber)"
            Method  = 'GET'
            Headers = $headers
        }
        $response = Invoke-RestMethod @splatImportPermissionParams

        if ($response.data) {
            foreach ($importedPermission in $response.data) {           
                $allRetrievedPermissions.Add($importedPermission)                
            }
        }
        $itemsOnPage = $response.meta.to - $response.meta.from + 1
        $pageNumber++
    } while ($itemsOnPage -eq $response.meta.per_page)

    $parentPermissions = $allRetrievedPermissions | Group-Object -Property id -AsHashTable

    foreach ($importedPermission in $allRetrievedPermissions) {
        # If condition can maybe be removed in a production environment
        if ($null -ne $importedPermission.Id) {
            $accountReferences = [System.Collections.Generic.List[string]]::new()
            foreach ($account in $importedAccounts) {
                if ($null -eq $account.id) {
                    continue
                }

                if (($account.PersonsGroups.id | Measure-Object).count -eq 0) {
                    continue
                }

                if ($account.PersonsGroups.id -contains $importedPermission.id) {
                    $accountReferences.Add("$($account.Id)")
                }
            }

            $displayName = $importedPermission.Name
            if ($null -ne $importedPermission.ParentId) {
                $displayName = "$($parentPermissions[$importedPermission.ParentId].Name) - $($importedPermission.Name)"
            }
                
            $permission = @{
                PermissionReference = @{
                    Reference = "$($importedPermission.id)"
                }
                #Description         = "$($importedPermission.Name)"
                Description         = "$displayName"
                #DisplayName         = "$($importedPermission.Name)"
                AccountReferences   = $null
            }

            # The code below splits a list of permission members into batches of 100
            # Each batch is assigned to $permission.AccountReferences and the permission object will be returned to HelloID for each batch
            # Ensure batching is based on the number of account references to prevent exceeding the maximum limit of 500 account references per batch
                    
            $batchSize = 500
            for ($i = 0; $i -lt $accountReferences.Count; $i += $batchSize) {
                $permission.AccountReferences = $accountReferences[$i..([Math]::Min($i + $batchSize - 1, $accountReferences.Count - 1))]
                Write-Output $permission
            }
        }
    }

    Write-Information 'Simac-Pronto permission entitlement import completed'
}
catch {
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-Simac-ProntoError -ErrorObject $ex
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
        Write-Error "Could not import Simac-Pronto permission entitlements. Error: $($errorObj.FriendlyMessage)"
    }
    else {
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
        Write-Error "Could not import Simac-Pronto permission entitlements. Error: $($ex.Exception.Message)"
    }
}