################################################################
# HelloID-Conn-Prov-Target-Simac-Pronto-SubPermissions-Group
# PowerShell V2
################################################################

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# Script Mapping lookup values
$identificationId = $personContext.Person.Custom.SimacProntoPassNumber # Mandatory
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
        } elseif ($ErrorObject.Exception.GetType().FullName -eq 'System.Net.WebException') {
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
        } catch {
            $httpErrorObj.FriendlyMessage = $httpErrorObj.ErrorDetails
            Write-Warning $_.Exception.Message
        }
        Write-Output $httpErrorObj
    }
}
#endregion

# Begin
try {
    # Verify if [aRef] has a value
    if ([string]::IsNullOrEmpty($($actionContext.References.Account))) {
        throw 'The account reference could not be found'
    }

    # get auth token and set header
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
    $accessToken = (Invoke-RestMethod @splatTokenParams).token

    $headers = @{
        Authorization  = "Bearer $($accessToken)"
        'content-type' = 'application/json'
        Accept         = 'application/json'
    }

    Write-Information 'Verifying if a Simac-Pronto account exists'
    $splatGetUserParams = @{
        Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/persons/$($actionContext.References.Account)"
        Method  = 'GET'
        Headers = $headers
    }
    try {
        $correlatedAccount = (Invoke-RestMethod @splatGetUserParams) | Select-Object -First 1
    } catch {
        if ($_.Exception.Response.StatusCode -eq 404) {
            $correlatedAccount = $null
        } else {
            throw $_
        }
    }

    # Collect current permissions
    $currentPermissions = @{}
    foreach ($permission in $actionContext.CurrentPermissions) {
        $currentPermissions["$($permission.Reference.Id)"] = $permission.DisplayName
    }

    # Collect desired permissions
    $desiredPermissions = @{}
    if (-not($actionContext.Operation -eq 'revoke')) {
        if ( [string]::IsNullOrEmpty($($identificationId))) {
            throw 'The identification ID could not be found from the HelloID person object. Please make sure the "Script" mapping is correct.'
        }

        $desiredPermissions["$($identificationId)"] = "$($identificationId)"
    }

    # Process desired permissions to grant
    foreach ($permission in $desiredPermissions.GetEnumerator()) {
        $outputContext.SubPermissions.Add([PSCustomObject]@{
                DisplayName = $permission.Name
                Reference   = [PSCustomObject]@{
                    Id = $permission.Value
                }
            })

        if (-not $currentPermissions.ContainsKey($permission.Value)) {
            $correlatedAccount.Identifications = [System.Collections.Generic.List[object]]$correlatedAccount.Identifications
            $correlatedAccount.Identifications.Add([PSCustomObject]@{
                    Id        = "$($permission.value)"
                    FromTime  = (Get-Date).ToString('yyyy-MM-ddT00:00:00')
                    UntilTime = $null
                })

            $splatGrantParams = @{
                Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/persons/$($actionContext.References.Account)"
                Method  = 'PATCH'
                Headers = $headers
                Body    = (($correlatedAccount | Select-Object -Property Identifications) | ConvertTo-Json)
            }

            if (-not($actionContext.DryRun -eq $true)) {
                $null = Invoke-RestMethod @splatGrantParams
            }

            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Action  = 'GrantPermission'
                    Message = "Granted access to permission $($permission.Value)"
                    IsError = $false
                })
        }
    }

    # Process current permissions to revoke
    $newCurrentPermissions = @{}
    foreach ($permission in $currentPermissions.GetEnumerator()) {
        if (-not $desiredPermissions.ContainsKey($permission.Value)) {
            # Set the UntilTime to current date where the Identifications Id matches the permission reference. To revoke the permission.
            $correlatedAccount.Identifications | Where-Object { $_.Id -eq $permission.value } | ForEach-Object { $_.UntilTime = (Get-Date).ToString('yyyy-MM-ddT00:00:00') }

            $splatRevokeParams = @{
                Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/persons/$($actionContext.References.Account)"
                Method  = 'PATCH'
                Headers = $headers
                Body    = (($correlatedAccount | Select-Object -Property Identifications) | ConvertTo-Json)
            }

            if (-not($actionContext.DryRun -eq $true)) {
                $null = Invoke-RestMethod @splatRevokeParams
            }

            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Action  = 'RevokePermission'
                    Message = "Revoked access to permission $($permission.Value)"
                    IsError = $false
                })
        } else {
            $newCurrentPermissions[$permission.Name] = $permission.Value
        }
    }

    # Process permissions to update
    if ($actionContext.Operation -eq 'update') {
        foreach ($permission in $newCurrentPermissions.GetEnumerator()) {
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Action  = 'UpdatePermission'
                    Message = "No changes to access of permission $($permission.Value) required."
                    IsError = $false
                })
        }
    }
    $outputContext.Success = $true
} catch {
    $outputContext.Success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-Simac-ProntoError -ErrorObject $ex
        $auditMessage = "Could not manage Simac-Pronto permissions. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    } else {
        $auditMessage = "Could not manage Simac-Pronto permissions. Error: $($_.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
}