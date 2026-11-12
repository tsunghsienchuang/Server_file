# Dot-source from PowerShell 7 on the Windows runner.
# $fixture = Start-ServerFilesWslFixture
# try { ...; Assert-ServerFilesWslPassword -Fixture $fixture }
# finally { Stop-ServerFilesWslFixture -Fixture $fixture }

function New-ServerFilesWslProcess {
    param(
        [Parameter(Mandatory)][string]$Wsl,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$RedirectInput
    )
    $launch = [System.Diagnostics.ProcessStartInfo]::new($Wsl)
    $launch.UseShellExecute = $false
    $launch.CreateNoWindow = $true
    $launch.RedirectStandardOutput = $true
    $launch.RedirectStandardError = $true
    $launch.RedirectStandardInput = $RedirectInput.IsPresent
    $encoding = [System.Text.UTF8Encoding]::new($false)
    $launch.StandardOutputEncoding = $encoding
    $launch.StandardErrorEncoding = $encoding
    if ($RedirectInput) { $launch.StandardInputEncoding = $encoding }
    foreach ($argument in $Arguments) { $launch.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::Start($launch)
    [pscustomobject]@{
        Process = $process
        Output = $process.StandardOutput.ReadToEndAsync()
        ErrorOutput = $process.StandardError.ReadToEndAsync()
    }
}

function Invoke-ServerFilesWsl {
    param(
        [Parameter(Mandatory)][string]$Wsl,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$StdinText,
        [int]$TimeoutSeconds = 180
    )
    $inputProvided = $PSBoundParameters.ContainsKey('StdinText')
    $worker = New-ServerFilesWslProcess -Wsl $Wsl -Arguments $Arguments -RedirectInput:$inputProvided
    try {
        if ($inputProvided) {
            try { $worker.Process.StandardInput.Write($StdinText) }
            finally { $worker.Process.StandardInput.Close() }
        }
        if (!$worker.Process.WaitForExit(1000 * $TimeoutSeconds)) {
            $worker.Process.Kill($true)
            throw "WSL did not finish within $TimeoutSeconds seconds."
        }
        $stdout = $worker.Output.GetAwaiter().GetResult().Replace([string][char]0, '')
        $stderr = $worker.ErrorOutput.GetAwaiter().GetResult().Replace([string][char]0, '')
        if ($worker.Process.ExitCode -ne 0) {
            throw "WSL exited with code $($worker.Process.ExitCode). $stderr $stdout"
        }
        $stdout
    } finally {
        $worker.Process.Dispose()
    }
}

function Stop-ServerFilesWslFixture {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Fixture)
    $Fixture.Password = $null
    if ($Fixture.Imported) {
        try {
            $null = Invoke-ServerFilesWsl -Wsl $Fixture.Wsl -Arguments @('--terminate', $Fixture.Distro) -TimeoutSeconds 30
        } catch {
            Write-Verbose "Fixture distro was already stopped or could not be terminated: $_"
        }
        if ($Fixture.Daemon) {
            if (!$Fixture.Daemon.Process.WaitForExit(5000)) {
                $Fixture.Daemon.Process.Kill($true)
                $null = $Fixture.Daemon.Process.WaitForExit(5000)
            }
            $Fixture.Daemon.Process.Dispose()
            $Fixture.Daemon = $null
        }
        $null = Invoke-ServerFilesWsl -Wsl $Fixture.Wsl -Arguments @('--unregister', $Fixture.Distro) -TimeoutSeconds 45
        $Fixture.Imported = $false
    }
    if (Test-Path -LiteralPath $Fixture.TempPath) {
        Remove-Item -LiteralPath $Fixture.TempPath -Recurse -Force -ErrorAction Stop
    }
}

function Start-ServerFilesWslFixture {
    [CmdletBinding()]
    param()
    if (!$IsWindows) { throw 'The SSH fixture requires Windows with WSL 1 enabled.' }
    $wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'
    if (!(Test-Path -LiteralPath $wsl -PathType Leaf)) { throw 'Windows Subsystem for Linux is unavailable.' }

    $suffix = [Guid]::NewGuid().ToString('N')
    $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) "server-files-wsl-$suffix"
    $distro = "ServerFilesFixture-$suffix"
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    } finally {
        $listener.Stop()
    }
    $fixture = [pscustomobject]@{
        Wsl = $wsl
        Distro = $distro
        TempPath = $tempPath
        Imported = $false
        Daemon = $null
        Address = '127.0.0.1'
        Port = $port
        Username = 'previewfixture'
        Password = 'Sf-' + [Guid]::NewGuid().ToString('N') + '-!'
        RemoteDirectory = '~/server-files-fixture'
        Fingerprint = $null
        ExpectedFilename = 'password-fixture.txt'
        ExpectedText = "server-files-password-fixture-$suffix"
    }

    try {
        $null = New-Item -ItemType Directory -Path $tempPath -ErrorAction Stop
        $storage = Join-Path $tempPath 'rootfs'
        $null = New-Item -ItemType Directory -Path $storage -ErrorAction Stop
        $ubuntuBase = 'https://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release'
        $archiveName = 'ubuntu-base-22.04-base-amd64.tar.gz'
        $manifest = (Invoke-WebRequest -Uri "$ubuntuBase/SHA256SUMS" -TimeoutSec 90 -ErrorAction Stop).Content
        $filePattern = [regex]::Escape($archiveName)
        $digest = [regex]::Match($manifest, "(?m)^([0-9a-fA-F]{64}) [ *]$filePattern\r?$")
        if (!$digest.Success) { throw 'Ubuntu did not list the fixture rootfs checksum.' }
        $archive = Join-Path $tempPath $archiveName
        Invoke-WebRequest -Uri "$ubuntuBase/$archiveName" -OutFile $archive -TimeoutSec 180 -ErrorAction Stop
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash -ne $digest.Groups[1].Value) {
            throw 'Ubuntu fixture rootfs checksum mismatch.'
        }
        $tarPath = Join-Path $tempPath 'rootfs.tar'
        $compressed = [System.IO.File]::OpenRead($archive)
        try {
            $extractor = [System.IO.Compression.GZipStream]::new($compressed, [System.IO.Compression.CompressionMode]::Decompress)
            try {
                $tar = [System.IO.File]::Create($tarPath)
                try { $extractor.CopyTo($tar) }
                finally { $tar.Dispose() }
            } finally {
                $extractor.Dispose()
            }
        } finally {
            $compressed.Dispose()
        }
        $null = Invoke-ServerFilesWsl -Wsl $wsl -Arguments @('--import', $distro, $storage, $tarPath, '--version', '1') -TimeoutSeconds 240
        $fixture.Imported = $true
        Remove-Item -LiteralPath $archive, $tarPath -Force -ErrorAction Stop

        $setup = @'
set -euo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive
port=$1
marker=$2
login=previewfixture
state=/tmp/server-files-fixture-ssh
IFS= read -r password

# Suppress package post-install service starts so no server binds outside loopback.
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod 755 /usr/sbin/policy-rc.d
apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=25 update >&2
apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=25 install -y --no-install-recommends openssh-server python3 >&2
useradd --create-home --shell /bin/bash "$login"
printf '%s:%s\n' "$login" "$password" | chpasswd
unset password
install -d -m 0755 /run/sshd
install -d -m 0700 "$state"
folder="/home/$login/server-files-fixture"
install -d -m 0700 -o "$login" -g "$login" "$folder"
printf '%s\n' "$marker" > "$folder/password-fixture.txt"
chown "$login:$login" "$folder/password-fixture.txt"
chmod 0600 "$folder/password-fixture.txt"

ssh-keygen -q -t ed25519 -N '' -f "$state/host_ed25519"
cat > "$state/sshd_config" <<CONFIG
Port $port
ListenAddress 127.0.0.1
AddressFamily inet
HostKey $state/host_ed25519
PidFile $state/sshd.pid
AllowUsers $login
PermitRootLogin no
PermitEmptyPasswords no
PasswordAuthentication yes
PubkeyAuthentication no
KbdInteractiveAuthentication no
AuthenticationMethods password
UsePAM no
AllowTcpForwarding local
AllowStreamLocalForwarding local
AllowAgentForwarding no
X11Forwarding no
GatewayPorts no
PermitTTY no
PrintMotd no
LogLevel VERBOSE
CONFIG
/usr/sbin/sshd -t -f "$state/sshd_config"
ssh-keygen -lf "$state/host_ed25519.pub" -E sha256
'@
        $setupPath = Join-Path $tempPath 'fixture-setup.sh'
        [System.IO.File]::WriteAllText($setupPath, $setup.Replace([string][char]13, ''), [System.Text.UTF8Encoding]::new($false))
        $prefix = @('--distribution', $distro, '--user', 'root', '--exec')
        $linuxScript = (Invoke-ServerFilesWsl -Wsl $wsl -Arguments ($prefix + @('wslpath', '-u', $setupPath))).Trim()
        $result = Invoke-ServerFilesWsl -Wsl $wsl -Arguments ($prefix + @('/bin/bash', $linuxScript, [string]$port, $fixture.ExpectedText)) -StdinText ($fixture.Password + [char]10) -TimeoutSeconds 420
        $fingerprint = [regex]::Match($result, 'SHA256:[A-Za-z0-9+/]+')
        if (!$fingerprint.Success) { throw 'The fixture SSH host key has no SHA-256 fingerprint.' }
        $fixture.Fingerprint = $fingerprint.Value
        Remove-Item -LiteralPath $setupPath -Force -ErrorAction Stop

        $state = '/tmp/server-files-fixture-ssh'
        $fixture.Daemon = New-ServerFilesWslProcess -Wsl $wsl -Arguments ($prefix + @('/usr/sbin/sshd', '-D', '-f', "$state/sshd_config", '-E', "$state/sshd.log"))
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        while ([DateTime]::UtcNow -lt $deadline) {
            if ($fixture.Daemon.Process.HasExited) {
                $details = $fixture.Daemon.ErrorOutput.GetAwaiter().GetResult()
                throw "The fixture SSH server stopped before opening its port. $details"
            }
            $probe = [System.Net.Sockets.TcpClient]::new()
            try {
                $probe.Connect($fixture.Address, $port)
                $probe.ReceiveTimeout = 1000
                $banner = [System.IO.StreamReader]::new($probe.GetStream()).ReadLine()
                if ($banner -like 'SSH-2.0-OpenSSH_*') { return $fixture }
            } catch {
                Start-Sleep -Milliseconds 200
            } finally {
                $probe.Dispose()
            }
        }
        throw 'The fixture SSH server did not accept IPv4 loopback connections.'
    } catch {
        try { Stop-ServerFilesWslFixture -Fixture $fixture }
        catch { Write-Warning "Could not clean the temporary WSL fixture: $_" }
        throw
    }
}

function Assert-ServerFilesWslPassword {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Fixture)
    $pattern = "Accepted password for $($Fixture.Username) from $($Fixture.Address)"
    $match = Invoke-ServerFilesWsl -Wsl $Fixture.Wsl -Arguments @(
        '--distribution', $Fixture.Distro, '--user', 'root', '--exec',
        '/usr/bin/grep', '-F', $pattern, '/tmp/server-files-fixture-ssh/sshd.log'
    ) -TimeoutSeconds 15
    if (!$match.Trim()) { throw 'The fixture did not record a successful SSH password login.' }
    Write-Host 'Fixture SSH server confirmed password authentication over loopback.'
}
