##########################################################
# HelloID-Conn-Prov-Target-Simac-Pronto-LicensePlates
# PowerShell V2
##########################################################

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
        # Start-Sleep -Seconds  6

        $token = Invoke-RestMethod @splatTokenParams #-Verbose:$false

        Write-Output $token.token
    }
    catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}
#endregion

try {
    Write-Information "Creating [$($resourceContext.SourceData.Count)] resources"
    
    $correlationField = "prontoLicensePlate"
    
    $accessToken = Get-AccessToken

    $headers = @{
        Authorization  = "Bearer $($accessToken)"
        'content-type' = 'application/json'
        Accept         = 'application/json'
    }

    $splatRetrieveLicensePlatesParams = @{
        Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/identifications?filter=LicensePlate"
        Method  = 'GET'
        Headers = $headers
    }
    $retrievedLicensePlates = (Invoke-RestMethod @splatRetrieveLicensePlatesParams).data.serialNumber

    $resourceData = $resourceContext.SourceData | Where-Object { $null -ne $_.$correlationField -and $_.$correlationField -ne 'FOUTIEF' } | Select-Object * -Unique

    $outputContext.Success = $true
    foreach ($resource in $resourceData) {        
        try {
            # If resource does not exist
            if ($resource.$correlationField -notin $retrievedLicensePlates) {
                # Make sure to test with special characters and if needed; add utf8 encoding.
                if (-not ($actionContext.DryRun -eq $True)) {
                    Write-Information "Create [$($resource.$correlationField)] Simac Pronto resource"
                    
                    $newIdentificationBody = @{
                        Id           = "$($resource.$correlationField)"
                        SerialNumber = "$($resource.$correlationField)"
                        Type         = "LicensePlate"
                        EntryDate    = (Get-Date).ToString('yyyy-MM-dd')
                    } | ConvertTo-Json

                    $splatAddIdentificationParams = @{
                        Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/identifications"
                        Method  = 'POST'
                        Headers = $headers
                        Body    = $newIdentificationBody
                    }

                    if (-not($actionContext.DryRun -eq $true)) {
                        $null = Invoke-RestMethod @splatAddIdentificationParams                
                    } 
                    
                    $outputContext.AuditLogs.Add([PSCustomObject]@{
                            Action  = 'CreateResource'
                            Message = "Created Simac Pronto resource: [$($resource.$correlationField)] for License Plate [$($resource.$correlationField)]"
                            IsError = $false
                        })
                }
                else {                    
                    Write-Information "[DryRun] Create Simac Pronto [$($resource.$correlationField)] resource, will be executed during enforcement"

                    $auditLogMessage = "[DryRun] Create Simac Pronto [$($resource.$correlationField)] resource, will be executed during enforcement"
                    $outputContext.AuditLogs.Add([PSCustomObject]@{
                            Message = $auditLogMessage
                            IsError = $false
                        })
                }                
            }            
        }
        catch {            
            $outputContext.Success = $false
            $ex = $PSItem
            Write-Warning ($ex | ConvertTo-Json)
            if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
                $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
                $errorObj = Resolve-Simac-ProntoError -ErrorObject $ex
                $auditLogMessage = "Could not create Simac Pronto resource for [$($resource.$correlationField)]. Error: $($errorObj.FriendlyMessage)"
                Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
            }
            else {
                $auditLogMessage = "Could not create Simac Pronto resource for [$($resource.$correlationField)]. Error: $($ex.Exception.Message)"
                Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
            }
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = $auditLogMessage
                    IsError = $true
                })
        }
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