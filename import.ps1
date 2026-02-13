#################################################
# HelloID-Conn-Prov-Target-Simac-Pronto-Import
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
    Write-Information 'Starting Simac-Pronto account entitlement import'

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

    $pageNumber = 1
    do {
        $splatImportAccountParams = @{
            Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/persons/?page=$($pageNumber)"
            Method  = 'GET'
            Headers = $headers
        }
        $response = Invoke-RestMethod @splatImportAccountParams

        if ($response.data) {
            foreach ($importedAccount in $response.data ) {
                if ([string]::IsNullOrWhiteSpace($importedAccount.Id )) {
                    Write-Warning "Skipping import account [$($importedAccount.PreferedFullname)] because it has no ID"
                    continue
                }
                $data = $importedAccount | Select-Object -Property $actionContext.ImportFields
                # Enabled has a -not filter because the API uses an isDisabled property, which is the exact opposite of the enabled state used by HelloID.

                # Set Enabled based on importedAccount status
                $isEnabled = $false
                $now = Get-Date

                $activeDate = $null
                if ($null -ne $importedAccount.FromTime) {
                    $activeDate = Get-Date $importedAccount.FromTime
                }
                $expireDate = $null
                if ($null -ne $importedAccount.UntilTime) {
                    $expireDate = Get-Date $importedAccount.UntilTime
                }

                $inRange = (-not $activeDate -or $activeDate -le $now) -and (-not $expireDate -or $expireDate -ge $now)
                if ($inRange -eq $true) {
                    $isEnabled = $true
                }

                # Make sure the displayName has a value
                $displayName = $importedAccount.PreferedFullname
                if ([string]::IsNullOrEmpty($displayName)) {
                    $displayName = $importedAccount.Id
                }

                # Make sure the displayName has a value
                $userName = $importedAccount.Email
                if ([string]::IsNullOrEmpty($userName)) {
                    $userName = $importedAccount.Id
                }

                Write-Output @{
                    AccountReference = "$($importedAccount.Id)"
                    DisplayName      = $displayName
                    UserName         = $userName
                    Enabled          = $isEnabled
                    Data             = $data
                }
            }
        }
        $itemsOnPage = $response.meta.to - $response.meta.from + 1
        $pageNumber++
    } while ($itemsOnPage -eq $response.meta.per_page)

    Write-Information 'Simac-Pronto account entitlement import completed'
} catch {
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-Simac-ProntoError -ErrorObject $ex
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
        Write-Error "Could not import Simac-Pronto account entitlements. Error: $($errorObj.FriendlyMessage)"
    } else {
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
        Write-Error "Could not import Simac-Pronto account entitlements. Error: $($ex.Exception.Message)"
    }
}