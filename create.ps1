#################################################
# HelloID-Conn-Prov-Target-Simac-Pronto-Create
# PowerShell V2
#################################################

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

try {
    # Initial Assignments
    $outputContext.AccountReference = 'Currently not available'

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

    # Validate correlation configuration
    if ($actionContext.CorrelationConfiguration.Enabled) {
        $correlationField = $actionContext.CorrelationConfiguration.AccountField
        $correlationValue = $actionContext.CorrelationConfiguration.PersonFieldValue

        if ([string]::IsNullOrEmpty($($correlationField))) {
            throw 'Correlation is enabled but not configured correctly'
        }
        if ([string]::IsNullOrEmpty($($correlationValue))) {
            throw 'Correlation is enabled but [accountFieldValue] is empty. Please make sure it is correctly mapped'
        }

        # Determine if a user needs to be [created] or [correlated]
        Write-Information "Verifying if a Simac-Pronto account exists where $correlationField is: [$correlationValue]"
        $splatGetUserParams = @{
            Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/persons/$($correlationValue)"
            Method  = 'GET'
            Headers = $headers
        }
        try {
            $correlatedAccount = @(Invoke-RestMethod @splatGetUserParams)
        } catch {
            if ($_.Exception.Response.StatusCode -eq 404) {
                $correlatedAccount = $null
            } else {
                throw $_
            }
        }
    }

    if ($correlatedAccount.Count -eq 0) {
        $action = 'CreateAccount'
    } elseif ($correlatedAccount.Count -eq 1) {
        $action = 'CorrelateAccount'
    } elseif ($correlatedAccount.Count -gt 1) {
        throw "Multiple accounts found for person where $correlationField is: [$correlationValue]"
    }

    # Process
    switch ($action) {
        'CreateAccount' {
            # Create account disabled
            $actionContext.Data | Add-Member @{
                FromTime  = (Get-Date).AddDays(-1).ToString('yyyy-MM-ddT00:00:00')
                UntilTime = (Get-Date).ToString('yyyy-MM-ddT00:00:00')
            }

            $splatCreateParams = @{
                Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/persons"
                Method  = 'POST'
                Body    = $actionContext.Data | ConvertTo-Json
                Headers = $headers
            }

            if (-not($actionContext.DryRun -eq $true)) {
                Write-Information 'Creating and correlating Simac-Pronto account'
                $null = Invoke-RestMethod @splatCreateParams

                $outputContext.Data = ($outputContext.Data | Select-Object -Property $outputContext.data.PSObject.Properties.Name)
                $outputContext.AccountReference = "$($outputContext.Data.Id)"
            } else {
                Write-Information '[DryRun] Create and correlate Simac-Pronto account, will be executed during enforcement'
            }
            $auditLogMessage = "Create account was successful. AccountReference is: [$($outputContext.AccountReference)]"
            break
        }

        'CorrelateAccount' {
            Write-Information 'Correlating Simac-Pronto account'

            $outputContext.Data = ($correlatedAccount | Select-Object -Property $outputContext.data.PSObject.Properties.Name)
            $outputContext.AccountReference = "$($correlatedAccount.Id)"
            $outputContext.AccountCorrelated = $true
            $auditLogMessage = "Correlated account: [$($outputContext.AccountReference)] on field: [$($correlationField)] with value: [$($correlationValue)]"
            break
        }
    }

    $outputContext.success = $true
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Action  = $action
            Message = $auditLogMessage
            IsError = $false
        })
} catch {
    $outputContext.success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-Simac-ProntoError -ErrorObject $ex
        $auditLogMessage = "Could not create or correlate Simac-Pronto account. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    } else {
        $auditLogMessage = "Could not create or correlate Simac-Pronto account. Error: $($ex.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditLogMessage
            IsError = $true
        })
}