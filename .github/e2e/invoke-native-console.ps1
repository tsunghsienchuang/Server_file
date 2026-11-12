[CmdletBinding(DefaultParameterSetName = 'Launch')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Launch')][string]$ExePath,
    [Parameter(Mandatory, ParameterSetName = 'Launch')][string]$SshHost,
    [Parameter(Mandatory, ParameterSetName = 'Launch')][string]$SshUser,
    [Parameter(Mandatory, ParameterSetName = 'Launch')][ValidateRange(1,65535)][int]$SshPort,
    [Parameter(ParameterSetName = 'Launch')][AllowEmptyString()][string]$RemoteFolder = '',
    [Parameter(ParameterSetName = 'Launch')][AllowEmptyString()][string]$ExpectedHostFingerprint = '',
    [Parameter(ParameterSetName = 'Launch')][ValidateRange(10,115)][int]$TimeoutSeconds = 75,
    [Parameter(Mandatory, ParameterSetName = 'Stop')][int]$StopProcessId
)

$ErrorActionPreference = 'Stop'
if (-not ('ServerFilesNativeConsole' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'NativeConsole.cs')
}
if ($PSCmdlet.ParameterSetName -eq 'Stop') {
    [ServerFilesNativeConsole]::Stop($StopProcessId)
    return
}

$password = [Environment]::GetEnvironmentVariable('SERVER_FILES_FIXTURE_PASSWORD')
if ([string]::IsNullOrEmpty($password)) {
    throw 'Set SERVER_FILES_FIXTURE_PASSWORD to the synthetic SSH fixture password.'
}
$resolved = (Resolve-Path -LiteralPath $ExePath).ProviderPath
try {
    $result = [ServerFilesNativeConsole]::Launch(
        $resolved, $SshHost, $SshUser, $SshPort, $RemoteFolder,
        $password, $ExpectedHostFingerprint, $TimeoutSeconds
    )
    Write-Verbose ('OpenSSH password prompt exercised. Fixture host-key confirmation shown: ' + $result.VerifiedHostKeyPrompt)
    [int]$result.ProcessId
}
finally {
    $password = $null
}
