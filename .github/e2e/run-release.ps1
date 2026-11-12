param([Parameter(Mandatory)][string]$ExePath)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

. (Join-Path $PSScriptRoot 'wsl-ssh-fixture.ps1')
$console = Join-Path $PSScriptRoot 'invoke-native-console.ps1'
$edge = Join-Path ${env:ProgramFiles(x86)} 'Microsoft/Edge/Application/msedge.exe'
if (-not (Test-Path -LiteralPath $edge -PathType Leaf)) { throw 'Installed Microsoft Edge was not found' }
if (Get-Command codex -ErrorAction SilentlyContinue) { throw 'Codex is present on the test machine PATH' }
$sshClient = Join-Path $env:SystemRoot 'System32/OpenSSH/ssh.exe'
if (-not (Test-Path -LiteralPath $sshClient -PathType Leaf)) { throw 'Windows OpenSSH Client is unavailable' }
Write-Host "Windows $([Environment]::OSVersion.Version), $([Runtime.InteropServices.RuntimeInformation]::OSArchitecture). Codex CLI absent from PATH."

function Find-BrowserDispatch {
    param([datetime]$Since, [string]$LauncherPath)
    $events = Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4688; StartTime=$Since} -ErrorAction SilentlyContinue
    foreach ($event in $events) {
        $properties = @{}
        foreach ($item in ([xml]$event.ToXml()).Event.EventData.Data) { $properties[$item.GetAttribute('Name')] = $item.InnerText }
        if ($properties['ParentProcessName'] -eq $LauncherPath -and
            $properties['NewProcessName'] -like '*\rundll32.exe' -and
            $properties['CommandLine'] -like '*url.dll,FileProtocolHandler*http://127.0.0.1:8878/*') { return $true }
    }
    return $false
}

$fixture = $null
$launcherId = $null
try {
    $fixture = Start-ServerFilesWslFixture
    Write-Host 'Linux SSH fixture is ready with password authentication only.'
    # Process auditing is used only inside this disposable VM to capture the launcher-to-browser handoff.
    $auditKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit'
    New-Item -Path $auditKey -Force | Out-Null
    New-ItemProperty -Path $auditKey -Name ProcessCreationIncludeCmdLine_Enabled -Value 1 -PropertyType DWord -Force | Out-Null
    & auditpol.exe /set '/subcategory:Process Creation' /success:enable | Out-Null
    $auditSince = Get-Date
    $env:SERVER_FILES_FIXTURE_PASSWORD = $fixture.Password
    if ($env:GITHUB_ACTIONS) { Write-Host "::add-mask::$($fixture.Password)" }
    $launcherId = [int](& $console -ExePath $ExePath -SshHost $fixture.Address -SshUser $fixture.Username `
        -SshPort $fixture.Port -RemoteFolder $fixture.RemoteDirectory -ExpectedHostFingerprint $fixture.Fingerprint -Verbose)
    Remove-Item Env:SERVER_FILES_FIXTURE_PASSWORD -ErrorAction SilentlyContinue
    if ($launcherId -le 0) { throw 'Native Windows launch did not return a process ID' }
    Assert-ServerFilesWslPassword -Fixture $fixture
    Write-Host 'Linux sshd independently confirmed password authentication.'

    $screenshot = Join-Path $env:RUNNER_TEMP 'server-files-edge-preview.png'
    & node (Join-Path $PSScriptRoot 'verify-edge.mjs') $edge $screenshot $fixture.ExpectedFilename $fixture.ExpectedText
    $dispatched = Find-BrowserDispatch -Since $auditSince -LauncherPath $ExePath
    if (-not $dispatched) { throw 'Could not verify that the released launcher dispatched the Files URL to Windows' }
    Write-Host 'Verified that the released EXE asked Windows to open the Files URL.'
    @"
### Published Server Files v1.1.0 on Windows x64

- Downloaded the released ZIP from GitHub and verified its SHA-256 before extracting it.
- Opened the released executable through the Windows shell with the same open action used by Explorer.
- Entered an SSH password in the native console and verified that the Linux SSH server accepted password authentication.
- Observed the released process dispatch the Files URL to Windows, then verified the file list and exact sample file contents in Microsoft Edge.
- Codex CLI was absent from PATH. The test neither installed nor invoked Codex.
"@ >> $env:GITHUB_STEP_SUMMARY
} finally {
    Remove-Item Env:SERVER_FILES_FIXTURE_PASSWORD -ErrorAction SilentlyContinue
    if ($launcherId -gt 0) {
        try { & $console -StopProcessId $launcherId | Out-Null }
        catch { Write-Warning 'Native Ctrl+C cleanup failed; stopping the isolated test process.' }
        Wait-Process -Id $launcherId -Timeout 5 -ErrorAction SilentlyContinue
        Stop-Process -Id $launcherId -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $fixture) { Stop-ServerFilesWslFixture -Fixture $fixture }
}
