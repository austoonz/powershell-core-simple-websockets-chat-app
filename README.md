# PowerShell Core Port of simple-websockets-chat-app

This is a PowerShell Core port of the [simple-websockets-chat-app](https://github.com/aws-samples/simple-websockets-chat-app) sample for AWS Lambda. For more information [Announcing WebSocket APIs in Amazon API Gateway](https://aws.amazon.com/blogs/compute/announcing-websocket-apis-in-amazon-api-gateway/) blog post.

## Deploy

To deploy this sample, ensure you have setup a [PowerShell Core Development Environment for AWS Lambda](https://docs.aws.amazon.com/lambda/latest/dg/lambda-powershell-setup-dev-environment.html).

First, execute the following PowerShell commands in the root directory of this repository. This will import the WebSocket PowerShell Module and compile the PowerShell Core AWS Lambda Function.

```powershell
Import-Module -Name 'AWSLambdaPSCore'

$functionScript = [System.IO.Path]::Combine('.', 'WebSocket', 'WebSocket.ps1')
$websocketManifest = [System.IO.Path]::Combine('.', 'WebSocket', 'WebSocket.psd1')
$lambdaPackage = [System.IO.Path]::Combine('.', '_packaged', 'WebSocket.zip')

Import-Module $websocketManifest

$null = New-AWSPowerShellLambdaPackage -ScriptPath $functionScript -OutputPackage $lambdaPackage
```

This sample can be deployed using the [AWS Lambda .NET Core Global Tool](https://aws.amazon.com/blogs/developer/net-core-global-tools-for-aws/).

To install the global tool, execute the following command. Be sure at least version 3.1.0 of the tool is installed.

```
dotnet tool install -g Amazon.Lambda.Tools
```

To upgrade the global tool, execute the following command.

```
dotnet tool update -g Amazon.Lambda.Tools
```

To deploy the sample application, execute the following command in the root directory of this repository.

```
dotnet lambda deploy-serverless <stack-name> --template template.yaml --region <region> --s3-bucket <storage-bucket>
```

To test the WebSockets functionality, use a WebSockets client (such as the Chrome "Simple WebSocket Client" extension) to connect to the value listed in the CloudFormation "WebSocketURI" output.

To send messages to connected clients, send a JSON message formatted like this, with the value of "data" as the message to send.

```
{"action":"sendmessage", "data":"Hello World"}
```

To delete the sample application, execute the following command.

```
dotnet lambda delete-serverless <stack-name>
```