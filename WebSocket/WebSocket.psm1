<#
    .SYNOPSIS
    This function is invoked when a client connects to the WebSocket.
#>
function Invoke-OnConnect
{
    param
    (
        $LambdaInput,
        $LambdaContext
    )

    try
    {
        # Get the ConnectionId from the API Request
        $connectionId = $LambdaInput.RequestContext.ConnectionId

        # Create a DynamoDB Client
        $ddbclient = [Amazon.DynamoDBv2.AmazonDynamoDBClient]::new()
        $table = [Amazon.DynamoDBv2.DocumentModel.Table]::LoadTable($ddbclient, $env:TABLE_NAME)

        # Put the ConnectionId into the DynamoDB Table
        $json = ConvertTo-Json -Compress -InputObject @{$env:CONNECTION_FIELD = $connectionId}
        $document = [Amazon.DynamoDBv2.DocumentModel.Document]::FromJson($json)
        $table.PutItemAsync($document).Wait()
        Write-Host ('ConnectionId "{0}" written to DynamoDB' -f $connectionId)

        $response = @{
            statusCode = 200
            body       = 'Connected.'
            headers    = @{'Content-Type' = 'text/plain'}
        }
    }
    catch
    {
        Write-Warning -Message ('Exception caught connecting:' -f $_)

        $response = @{
            statusCode = 500
            body       = 'Failed to connect: {0}' -f $_
            headers    = @{'Content-Type' = 'text/plain'}
        }
    }
    finally
    {
        if ($ddbclient) { $ddbclient.Dispose() }
    }

    $response
}

<#
    .SYNOPSIS
    This function is invoked when a client disconnects from the WebSocket.
#>
function Invoke-OnDisconnect
{
    param
    (
        $LambdaInput,
        $LambdaContext
    )

    try
    {
        # Get the ConnectionId from the API Request
        $connectionId = $LambdaInput.RequestContext.ConnectionId

        # Create a DynamoDB Client
        $ddbClient = [Amazon.DynamoDBv2.AmazonDynamoDBClient]::new()
        $table = [Amazon.DynamoDBv2.DocumentModel.Table]::LoadTable($ddbClient, $env:TABLE_NAME)

        # Delete the DynamoDB Record
        $hashKey = [Amazon.DynamoDBv2.DocumentModel.Primitive]::new($connectionId)
        $table.DeleteItemAsync($hashKey).Wait()
        Write-Host ('ConnectionId "{0}" removed from DynamoDB' -f $connectionId)

        $response = @{
            statusCode = 200
            body       = 'Disonnected.'
            headers    = @{'Content-Type' = 'text/plain'}
        }
    }
    catch
    {
        Write-Warning -Message ('Exception caught disconnecting: {0}' -f $_)

        $response = @{
            statusCode = 500
            body       = 'Failed to disconnect: {0}' -f $_
            headers    = @{'Content-Type' = 'text/plain'}
        }
    }
    finally
    {
        if ($ddbClient) { $ddbClient.Dispose() }
    }

    $response
}

<#
    .SYNOPSIS
    This function is invoked when a client sends a message to the WebSocket.

    .DESCRIPTION
    A message sent to the client must meet the following Json format:

    {"action":"sendmessage", "data":"hello world"}
#>
function Invoke-SendMessage
{
    param
    (
        $LambdaInput,
        $LambdaContext
    )

    $domainName = $LambdaInput.RequestContext.DomainName
    $stage = $LambdaInput.RequestContext.Stage
    $endpoint = "https://$domainName/$stage"
    Write-Host 'API Gateway management endpoint:' $endpoint

    # Create a DynamoDB Client
    $ddbClient = [Amazon.DynamoDBv2.AmazonDynamoDBClient]::new()
    $table = [Amazon.DynamoDBv2.DocumentModel.Table]::LoadTable($ddbClient, $env:TABLE_NAME)

    $ScanOperationConfig = [Amazon.DynamoDBv2.DocumentModel.ScanOperationConfig]::new()
    $search = $table.Scan($ScanOperationConfig)

    # Create an API Gateway Client
    $apiConfig = [Amazon.ApiGatewayManagementApi.AmazonApiGatewayManagementApiConfig]::new()
    $apiConfig.ServiceURL = $endpoint
    $apiConfig.Timeout = New-TimeSpan -Seconds 1
    $apiClient = [Amazon.ApiGatewayManagementApi.AmazonApiGatewayManagementApiClient]::new($apiConfig)

    # Create a MemoryStream for sending to connections
    $message = ConvertFrom-Json -InputObject $LambdaInput.body
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($message.data)
    $stream = [System.IO.MemoryStream]::new($bytes)

    $counter = 0
    try
    {
        do
        {
            # Retrieve all client connectionID values from DynamoDB
            $documentSet = $search.GetNextSetAsync().Result
            foreach ($document in $documentSet)
            {
                $connectionId = $document[$env:CONNECTION_FIELD].Value

                $request = [Amazon.ApiGatewayManagementApi.Model.PostToConnectionRequest]::new()
                $request.ConnectionId = $connectionId
                $request.Data = $stream

                try
                {
                    <#
                        This code does not use the PowerShell Cmdlet, as calls to old non-existent
                        ConnectionIds have long timeout values that we can't change with the Cmdlet.
                        Leveraging the .NET client doesn't have this same issue as we can adjust the
                        timeout.

                        The PowerShell Cmdlet call would look like this:
                        Send-AGMDataToConnection -ConnectionId $connectionId -Data $bytes -EndpointUrl $endpoint
                    #>

                    $stream.Position = 0
                    $null = $apiClient.PostToConnectionAsync($request).Wait()
                    $counter++

                    Write-Host ('Posted to connectionId "{0}"' -f $connectionId)
                }
                catch
                {
                    if ($_.StatusCode -eq [System.Net.HttpStatusCode]::Gone)
                    {
                        Write-Host ('Deleting gone connectionId "{0}"' -f $connectionId)
                        $hashKey = [Amazon.DynamoDBv2.DocumentModel.Primitive]::new($connectionId)
                        $table.DeleteItemAsync($hashKey).Wait()
                    }
                    elseif ($_.Exception.Message -like '*Invalid connectionId:*')
                    {
                        Write-Host ('Deleting invalid connectionId "{0}"' -f $connectionId)
                        $hashKey = [Amazon.DynamoDBv2.DocumentModel.Primitive]::new($connectionId)
                        $table.DeleteItemAsync($hashKey).Wait()
                    }
                    elseif ($_.Exception.Message -like '*A task was canceled.*')
                    {
                        Write-Host ('Call timed out, deleting connectionId "{0}"' -f $connectionId)
                        $hashKey = [Amazon.DynamoDBv2.DocumentModel.Primitive]::new($connectionId)
                        $table.DeleteItemAsync($hashKey).Wait()
                    }
                    else
                    {
                        Write-Warning -Message ('Error posting message to {0}: {1}' -f $connectionId, $_.Exception.Message)
                        Write-Warning -Message $_

                        Write-Host '$_.Exception.Message' $_.Exception.Message
                        Write-Host '$_.InnerException' $_.InnerException
                        Write-Host '$_.CategoryInfo' $_.CategoryInfo
                        Write-Host '$_.ErrorDetails' $_.ErrorDetails
                        Write-Host '$_.ScriptStackTrace' $_.ScriptStackTrace
                    }
                }
            }
        }
        while (-not $search.IsDone)

        $response = @{
            statusCode = 200
            body       = 'Data sent to {0} connection{1}' -f $counter, $(if ($counter -ne 1) {'s'})
            headers    = @{'Content-Type' = 'text/plain'}
        }
    }
    catch
    {
        Write-Warning -Message ('Error sending message: {0}' -f $_)

        $response = @{
            statusCode = 500
            body       = 'Failed to send message: {0}' -f $_
            headers    = @{'Content-Type' = 'text/plain'}
        }
    }
    finally
    {
        if ($ddbClient) { $ddbClient.Dispose() }
        if ($apiClient) { $apiClient.Dispose() }
    }

    $response
}