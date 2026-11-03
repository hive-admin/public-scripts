# ============================================================
# setup-script-min.ps1 -- Windows Server 2022 bootstrap
#
# Installs: Chocolatey, winget, Scoop, Windows Terminal,
#           Google Chrome, aria2, MongoDB (Server, Shell,
#           Database Tools, Compass), Python 3.14 + project
#           packages + Playwright browsers, common CLI tools.
#
# Usage (self-elevates and re-launches under Windows PowerShell 5.1):
#   Set-ExecutionPolicy Bypass -Scope Process -Force
#   .\setup-script-min.ps1
#
# Safe to re-run: every step detects existing installs first.
# Exit code: 0 = no failures, 1 = one or more steps failed.
# ============================================================

[CmdletBinding()]
param(
    [switch]$SkipRebootCheck,
    [string]$LogPath = "$env:SystemDrive\Logs\ServerSetup"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# --- Re-launch elevated, and under Windows PowerShell 5.1 (Appx cmdlets) ---
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin  = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($PSVersionTable.PSEdition -eq 'Core' -or -not $isAdmin) {
    if (-not $PSCommandPath) { Write-Host 'Save this script to a .ps1 file and run it from there.' -ForegroundColor Red; exit 1 }
    $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($SkipRebootCheck) { $relaunch += '-SkipRebootCheck' }
    $relaunch += @('-LogPath', "`"$($LogPath.TrimEnd('\'))`"")
    $winPS = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    if ($isAdmin) {
        $child = Start-Process $winPS -ArgumentList $relaunch -NoNewWindow -Wait -PassThru
        exit $child.ExitCode
    }
    Write-Host 'Not elevated -- continuing in a new Administrator window...' -ForegroundColor Yellow
    Start-Process $winPS -ArgumentList (@('-NoExit') + $relaunch) -Verb RunAs | Out-Null
    exit 0
}

# ============================================================
# CONFIGURATION -- edit lists here
# ============================================================

$Config = @{
    PythonVersion = '3.14'
    PythonWinget  = 'Python.Python.3.14'
    PythonChoco   = 'python314'

    # Deduplicated from every requirements*.txt under C:\Proj (excluding C:\Proj\mega).
    # Unpinned on purpose: projects that need exact pins should use their own venv.
    PipPackages   = @(
        'fastapi', 'uvicorn[standard]', 'pydantic', 'python-dotenv', 'python-multipart', 'httpx',
        'motor', 'pymongo', 'pyopenssl', 'requests', 'urllib3', 'curl-cffi', 'beautifulsoup4', 'lxml',
        'playwright', 'flask', 'pillow', 'numpy', 'pandas', 'jinja2', 'texttable', 'parsedatetime',
        'torf', 'openpyxl', 'rich', 'colorama', 'tqdm', 'loguru', 'unidecode', 'python-dateutil',
        'configparser', 'edge-tts', 'ebooklib', 'qbittorrent-api', 'yt-dlp', 'm3u8', 'plyer', 'pytest'
    )

    # Shared Playwright browser store so every RDP user can use the browsers.
    PlaywrightPath = "$env:ProgramData\ms-playwright"

    # choco id = command that proves it works ($null = check install only).
    # Use .exe names: in PowerShell 5.1 'curl' and 'wget' are Invoke-WebRequest aliases.
    ChocoPackages = [ordered]@{
        'git'             = 'git.exe'
        'notepadplusplus' = $null
        'ffmpeg'          = 'ffmpeg.exe'
        '7zip'            = '7z.exe'
        'qbittorrent'     = $null
        'curl'            = 'curl.exe'
        'wget'            = 'wget.exe'
        'jq'              = 'jq.exe'
    }

    ScoopPackages = @('gifsicle')
    ScoopBuckets  = @('extras')

    Aria2 = @{
        Version = '1.37.0'
        Url     = 'https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0-win-64bit-build1.zip'
        Sha256  = '67d015301eef0b612191212d564c5bb0a14b5b9c4796b76454276a4d28d9b288'
        Dir     = "$env:ProgramFiles\aria2"
    }

    ChromeMsiUrl = 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi'

    UiXamlUrl = 'https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.x64.appx'
    VCLibsUrl = 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx'
}

# ============================================================
# CONSOLE OUTPUT & RESULT TRACKING
# ============================================================

$script:Results      = [System.Collections.Generic.List[object]]::new()
$script:Section      = ''
$script:SectionIndex = 0
$script:SectionCount = 0
$script:LinePending  = $false
$script:RebootNeeded = $false
$script:LastStatus   = 'OK'
$script:StartTime    = Get-Date
$script:Interactive  = $true
try { $script:Interactive = -not [Console]::IsOutputRedirected } catch { }
$script:LogFile      = $null
$script:WorkDir      = $null
$script:Python       = $null
$script:Tags = @{
    OK   = @('[ OK ]', 'Green')
    SKIP = @('[SKIP]', 'DarkGray')
    WARN = @('[WARN]', 'Yellow')
    FAIL = @('[FAIL]', 'Red')
}

function Write-Section([string]$Title) {
    $script:SectionIndex++
    $script:Section = $Title
    $label = ' [{0}/{1}] {2}' -f $script:SectionIndex, $script:SectionCount, $Title
    Write-Host ''
    Write-Host $label.PadRight(70) -ForegroundColor White -BackgroundColor DarkBlue
}

# Ends an in-progress "[ .. ] item" line before printing anything else.
function Close-PendingLine {
    if ($script:LinePending) { Write-Host ''; $script:LinePending = $false }
}

function Write-Note([string]$Text, [string]$Color = 'DarkGray') {
    Close-PendingLine
    Write-Host "         $Text" -ForegroundColor $Color
}

function Write-Status([string]$Status, [string]$Item, [string]$Detail = '', [double]$Seconds = 0) {
    $tag, $color = $script:Tags[$Status]
    Write-Host "  $tag " -ForegroundColor $color -NoNewline
    Write-Host $Item.PadRight(34) -NoNewline
    if ($Detail)        { Write-Host " $Detail" -ForegroundColor $(if ($Status -eq 'FAIL') { 'Red' } else { 'DarkGray' }) -NoNewline }
    if ($Seconds -ge 2) { Write-Host (' ({0:N0}s)' -f $Seconds) -ForegroundColor DarkGray -NoNewline }
    Write-Host ''
}

# A step action reports its outcome by emitting one of these (last one wins).
# Emitting nothing = OK with no detail. Any other pipeline output is ignored.
function New-StepResult([string]$Status, [string]$Detail) {
    [pscustomobject]@{ PSTypeName = 'StepResult'; Status = $Status; Detail = $Detail }
}
function Skip([string]$Detail) { New-StepResult 'SKIP' $Detail }
function Warn([string]$Detail) { New-StepResult 'WARN' $Detail }

function Ok([string]$Detail) { New-StepResult 'OK' $Detail }

# Plain-text log file (console stays concise; full native output goes here).
function Write-Log([string]$Text) {
    if (-not $script:LogFile) { return }
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Text
    try { [IO.File]::AppendAllText($script:LogFile, $line + [Environment]::NewLine, [Text.Encoding]::UTF8) } catch { }
}

function Format-Error($ErrorRecord) {
    $msg = ($ErrorRecord.Exception.Message -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    if (-not $msg) { $msg = "$ErrorRecord" }
    $msg = $msg.Trim()
    if ($msg.Length -gt 110) { $msg = $msg.Substring(0, 107) + '...' }
    $msg
}

# Runs one unit of work, prints a single status line, records the result.
# Never throws: a failed step is recorded and the script moves on.
function Invoke-Step([string]$Item, [scriptblock]$Action) {
    Close-PendingLine
    if ($script:Interactive) {
        Write-Host '  [ .. ] ' -ForegroundColor DarkCyan -NoNewline
        Write-Host $Item -NoNewline
        $script:LinePending = $true
    }
    Write-Log "STEP  [$($script:Section)] $Item"

    $__sw = [Diagnostics.Stopwatch]::StartNew()
    $__st = 'OK'; $__dt = ''
    try {
        $__res = @(& $Action) |
            Where-Object { $null -ne $_ -and $_.PSObject.TypeNames -contains 'StepResult' } |
            Select-Object -Last 1
        if ($__res) { $__st = $__res.Status; $__dt = $__res.Detail }
    } catch {
        $__st = 'FAIL'
        $__dt = Format-Error $_
        Write-Log "ERROR $($_.Exception.Message)"
        Write-Log "      at $($_.InvocationInfo.PositionMessage -replace "`r?`n", ' ')"
    }
    $__sw.Stop()

    if ($script:LinePending) { Write-Host "`r" -NoNewline; $script:LinePending = $false }
    Write-Status $__st $Item $__dt $__sw.Elapsed.TotalSeconds
    Write-Log "$($__st.PadRight(5)) [$($script:Section)] $Item  $__dt"

    $script:Results.Add([pscustomobject]@{ Section = $script:Section; Item = $Item; Status = $__st; Detail = $__dt })
    $script:LastStatus = $__st
}

# ============================================================
# PROCESS, PATH & DOWNLOAD HELPERS
# ============================================================

# Runs a native program without letting its stderr turn into a terminating
# PowerShell error (PS 5.1 + 2>&1 + 'Stop' would otherwise abort on the first line).
# Full output goes to the log file; returns exit code + cleaned text.
function Invoke-Native([string]$FilePath, [string[]]$ArgumentList = @()) {
    $ErrorActionPreference = 'Continue'
    if (-not (Get-Command $FilePath -ErrorAction SilentlyContinue)) { throw "Command not found: $FilePath" }
    Write-Log "EXEC  $FilePath $($ArgumentList -join ' ')"
    $global:LASTEXITCODE = 0
    $lines = @(& $FilePath @ArgumentList 2>&1 | ForEach-Object {
        # strip winget/choco spinner and progress-bar noise
        ("$_" -replace '[\x00-\x08\x0B-\x1F]', '' -replace '[\u2580-\u259F]+', '').Trim()
    } | Where-Object { $_ -and $_ -notmatch '^[-\\|/]$' -and $_ -notmatch '^\d+(\.\d+)?\s*[KMG]?B\s*/' })
    $code = $LASTEXITCODE
    foreach ($l in $lines) { Write-Log "      | $l" }
    Write-Log "      exit $code"
    [pscustomobject]@{ ExitCode = [int]$code; Lines = $lines; Text = ($lines -join "`n") }
}

# Start-Process wrapper for installers (msiexec, setup.exe). Retries while
# another installation holds the Windows Installer mutex (1618).
function Invoke-Installer([string]$FilePath, [string]$Arguments, [int[]]$OkCodes = @(0, 1641, 3010)) {
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        Write-Log "EXEC  $FilePath $Arguments"
        $p = Start-Process -FilePath $FilePath -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden
        Write-Log "      exit $($p.ExitCode)"
        if ($p.ExitCode -ne 1618) { break }
        Write-Note "another installation is running -- retry $attempt/3 in 30s"
        Start-Sleep -Seconds 30
    }
    if ($p.ExitCode -in 1641, 3010) { $script:RebootNeeded = $true }
    if ($p.ExitCode -notin $OkCodes) { throw "$(Split-Path $FilePath -Leaf) exited with code $($p.ExitCode)" }
    $p.ExitCode
}

function Test-Cmd([string]$Name) { [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

# Rebuilds $env:Path from Machine + User (expanded, deduplicated), keeping
# any entries this session added, and reloads tool-related variables.
function Update-SessionEnv {
    $parts = @()
    foreach ($scope in 'Machine', 'User') {
        $v = [Environment]::GetEnvironmentVariable('Path', $scope)
        if ($v) { $parts += $v -split ';' }
    }
    $parts += $env:Path -split ';'
    $seen  = @{}
    $clean = foreach ($p in $parts) {
        $x = [Environment]::ExpandEnvironmentVariables($p.Trim()).TrimEnd('\')
        if ($x -and -not $seen.ContainsKey($x.ToLowerInvariant())) { $seen[$x.ToLowerInvariant()] = $true; $x }
    }
    $env:Path = $clean -join ';'
    foreach ($n in 'ChocolateyInstall', 'SCOOP', 'SCOOP_GLOBAL', 'PLAYWRIGHT_BROWSERS_PATH') {
        $v = [Environment]::GetEnvironmentVariable($n, 'Machine')
        if (-not $v) { $v = [Environment]::GetEnvironmentVariable($n, 'User') }
        if ($v) { Set-Item -Path "env:$n" -Value $v }
    }
}

# Adds a directory to the *machine* PATH if not already present (exact,
# case-insensitive, after expansion). Preserves unexpanded %VAR% entries.
# -Prepend moves/places it first. Returns $true if the registry was changed.
function Add-MachinePath([string]$Dir, [switch]$Prepend) {
    $Dir = $Dir.TrimEnd('\')
    if (-not (Test-Path -LiteralPath $Dir)) { throw "PATH target does not exist: $Dir" }
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $true)
    $changed = $false
    try {
        $raw     = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $entries = @($raw -split ';' | Where-Object { $_.Trim() })
        $isDir   = { param($e) [Environment]::ExpandEnvironmentVariables($e).TrimEnd('\') -ieq $Dir }
        $others  = @($entries | Where-Object { -not (& $isDir $_) })
        if ($Prepend) {
            if (-not ($entries.Count -and (& $isDir $entries[0]))) { $new = @($Dir) + $others; $changed = $true }
        } elseif ($others.Count -eq $entries.Count) {
            $new = $entries + $Dir; $changed = $true
        }
        if ($changed) {
            $key.SetValue('Path', ($new -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
            Write-Log "PATH  $(if ($Prepend) { '+^' } else { '+' }) $Dir"
        }
    } finally { $key.Close() }
    $session = @($env:Path -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ine $Dir })
    $env:Path = if ($Prepend) { (@($Dir) + $session) -join ';' } else { ($session + $Dir) -join ';' }
    if ($changed) { Send-EnvChange }
    $changed
}

# Removes machine PATH entries matching a wildcard (used to clean stale,
# version-specific entries an older version of this script added).
function Remove-MachinePathLike([string]$Pattern, [string]$Except = '') {
    $Except = $Except.TrimEnd('\')
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $true)
    try {
        $raw  = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $all  = @($raw -split ';' | Where-Object { $_.Trim() })
        $keep = @($all | Where-Object {
            $x = [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\')
            ($x -notlike $Pattern) -or ($Except -and $x -ieq $Except)
        })
        if ($keep.Count -ne $all.Count) {
            $key.SetValue('Path', ($keep -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
            Write-Log "PATH  - removed $($all.Count - $keep.Count) entr(y/ies) like $Pattern"
            Send-EnvChange
        }
        $all.Count - $keep.Count
    } finally { $key.Close() }
}

function Set-MachineEnv([string]$Name, [string]$Value) {
    if ([Environment]::GetEnvironmentVariable($Name, 'Machine') -ne $Value) {
        [Environment]::SetEnvironmentVariable($Name, $Value, 'Machine')
        Write-Log "ENV   $Name = $Value"
    }
    Set-Item -Path "env:$Name" -Value $Value
}

# Tells Explorer/new processes that the environment changed (WM_SETTINGCHANGE).
function Send-EnvChange {
    try {
        if (-not ('Win32.EnvNotify' -as [type])) {
            Add-Type -Namespace Win32 -Name EnvNotify -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
        }
        $r = [UIntPtr]::Zero
        [void][Win32.EnvNotify]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 3000, [ref]$r)
    } catch { Write-Log "WARN  WM_SETTINGCHANGE broadcast failed: $($_.Exception.Message)" }
}

# Downloads to a temp name, verifies optional SHA256, then renames into place.
function Invoke-Download([string]$Url, [string]$OutFile, [string]$Sha256 = '') {
    $tmp  = "$OutFile.part"
    $curl = "$env:SystemRoot\System32\curl.exe"
    Remove-Item -LiteralPath $tmp, $OutFile -Force -ErrorAction SilentlyContinue
    Write-Log "GET   $Url"
    if (Test-Path -LiteralPath $curl) {
        $r = Invoke-Native $curl @('-L', '-f', '-sS', '--retry', '5', '--retry-delay', '3',
                                   '--connect-timeout', '30', '-o', $tmp, $Url)
        if ($r.ExitCode -ne 0) { throw "download failed (curl $($r.ExitCode)): $Url" }
    } else {
        $ok = $false
        for ($i = 1; $i -le 3 -and -not $ok; $i++) {
            try { Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing -TimeoutSec 600; $ok = $true }
            catch { if ($i -eq 3) { throw "download failed: $Url -- $($_.Exception.Message)" }; Start-Sleep -Seconds (3 * $i) }
        }
    }
    if ((Get-Item -LiteralPath $tmp).Length -eq 0) { throw "downloaded file is empty: $Url" }
    if ($Sha256) {
        $actual = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash
        if ($actual -ne $Sha256) { Remove-Item -LiteralPath $tmp -Force; throw "SHA256 mismatch for $(Split-Path $OutFile -Leaf) (got $actual)" }
    }
    Move-Item -LiteralPath $tmp -Destination $OutFile -Force
    $OutFile
}

# Valid Authenticode signature whose signer subject matches the pattern.
function Assert-Signature([string]$File, [string]$SubjectLike) {
    $sig = Get-AuthenticodeSignature -LiteralPath $File
    if ($sig.Status -ne 'Valid') { throw "signature check failed for $(Split-Path $File -Leaf): $($sig.Status)" }
    if ($sig.SignerCertificate.Subject -notlike $SubjectLike) { throw "unexpected signer: $($sig.SignerCertificate.Subject)" }
}

# Looks up installed programs in the Uninstall registry keys (machine + current user).
function Get-InstalledApp([string]$NameLike) {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    @(Get-ItemProperty -Path $roots -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -like $NameLike } |
        ForEach-Object {
            $ver = if ($_.PSObject.Properties['DisplayVersion']) { $_.DisplayVersion } else { '' }
            $loc = if ($_.PSObject.Properties['InstallLocation']) { $_.InstallLocation } else { '' }
            [pscustomobject]@{ Name = $_.DisplayName; Version = $ver; Location = $loc }
        })
}

function Test-PendingReboot {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($k in $keys) { if (Test-Path $k) { return $true } }
    $sm = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue
    [bool]($sm -and $sm.PSObject.Properties['PendingFileRenameOperations'] -and $sm.PendingFileRenameOperations)
}

# First line of a version command, or $null. Never throws.
function Get-ToolVersion([string]$Command, [string[]]$VersionArgs = @('--version')) {
    try {
        if (-not (Test-Cmd $Command)) { return $null }
        $r = Invoke-Native $Command $VersionArgs
        $line = $r.Lines | Where-Object { $_ -match '\d' } | Select-Object -First 1
        if ($line) { $line.Trim() } else { $null }
    } catch { $null }
}

# ============================================================
# PACKAGE MANAGER WRAPPERS
# ============================================================

$script:Winget   = $null   # full path to winget.exe once resolved
$script:ScoopCmd = $null   # full path to scoop.cmd once resolved

# winget exit codes (see: winget error -- <code>)
$WG = @{
    AlreadyInstalled = -1978335135   # PACKAGE_ALREADY_INSTALLED
    NoUpdate         = -1978335189   # UPDATE_NOT_APPLICABLE
    HashMismatch     = -1978335215   # INSTALLER_HASH_MISMATCH
    NoApplicable     = -1978335216   # NO_APPLICABLE_INSTALLER (e.g. scope filter)
    InProgress       = -1978334974   # INSTALL_IN_PROGRESS
    RebootToFinish   = -1978334967   # INSTALL_REBOOT_REQUIRED_TO_FINISH
    RebootToInstall  = -1978334966   # INSTALL_REBOOT_REQUIRED_FOR_INSTALL
}

function Get-LastMeaningfulLine($Lines) {
    $l = @($Lines | Where-Object { $_ -match '[A-Za-z]{3}' -and $_ -notmatch '^(Found|Downloading|Starting|Successfully verified)' }) | Select-Object -Last 1
    if ($l -and $l.Length -gt 90) { $l = $l.Substring(0, 87) + '...' }
    $l
}

function Resolve-Winget {
    Update-SessionEnv
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $pkg = @(Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue) +
           @(Get-AppxPackage -AllUsers -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue) |
           Where-Object { $_ } | Sort-Object Version -Descending | Select-Object -First 1
    if ($pkg) {
        $exe = Join-Path $pkg.InstallLocation 'winget.exe'
        if (Test-Path -LiteralPath $exe) { return $exe }
    }
    $null
}

function Get-WingetVersion {
    if (-not $script:Winget) { return $null }
    $line = Get-ToolVersion $script:Winget
    if ($line -match '(\d+\.\d+(\.\d+)?)') { [version]$matches[1] } else { $null }
}

# Installs a package by exact id from the winget source, machine scope when the
# manifest supports it. Returns a short description; throws on failure.
function Install-WingetPackage([string]$Id, [string[]]$ExtraArgs = @()) {
    if (-not $script:Winget) { throw 'winget is not available' }
    $base = @('install', '--id', $Id, '--exact', '--source', 'winget', '--silent', '--disable-interactivity',
              '--accept-package-agreements', '--accept-source-agreements') + $ExtraArgs
    $scoped = $true
    $tries  = 0
    while ($true) {
        $tries++
        $wgArgs = if ($scoped) { $base + @('--scope', 'machine') } else { $base }
        $r = Invoke-Native $script:Winget $wgArgs
        $c = $r.ExitCode
        if ($c -eq 0)                                  { return 'winget' }
        if ($c -in $WG.AlreadyInstalled, $WG.NoUpdate) { return 'winget (already installed)' }
        if ($c -in 1641, 3010, $WG.RebootToFinish)     { $script:RebootNeeded = $true; return 'winget (reboot required)' }
        if ($c -eq $WG.NoApplicable -and $scoped)      { $scoped = $false; Write-Log 'INFO  retrying without --scope machine'; continue }
        if ($c -in $WG.InProgress, 1618 -and $tries -le 3) {
            Write-Note "another installation is running -- retry $tries/3 in 30s"
            Start-Sleep -Seconds 30; continue
        }
        $hex = '0x{0:X8}' -f $c
        if ($c -eq $WG.HashMismatch)    { throw "winget: installer hash mismatch ($hex) -- vendor updated the file, manifest is behind" }
        if ($c -eq $WG.RebootToInstall) { $script:RebootNeeded = $true; throw "winget: reboot required before install ($hex)" }
        throw "winget exit $hex -- $(Get-LastMeaningfulLine $r.Lines)"
    }
}

function Resolve-Choco {
    Update-SessionEnv
    $cmd = Get-Command choco.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $root = if ($env:ChocolateyInstall) { $env:ChocolateyInstall } else { "$env:ProgramData\chocolatey" }
    $exe  = Join-Path $root 'bin\choco.exe'
    if (Test-Path -LiteralPath $exe) { $env:ChocolateyInstall = $root; $env:Path = "$env:Path;$(Split-Path $exe)"; return $exe }
    $null
}

# Installed choco packages as id -> version (lower-case ids).
function Get-ChocoInstalled {
    $map = @{}
    if (-not (Test-Cmd 'choco')) { return $map }
    $r = Invoke-Native 'choco' @('list', '--limit-output', '--no-color')
    foreach ($l in $r.Lines) { if ($l -match '^([^|\s]+)\|(.+)$') { $map[$matches[1].ToLowerInvariant()] = $matches[2] } }
    $map
}

function Install-ChocoPackage([string]$Id, [string[]]$ExtraArgs = @()) {
    if (-not (Test-Cmd 'choco')) { throw 'Chocolatey is not available' }
    $chocoArgs = @('install', $Id, '-y', '--no-progress', '--limit-output', '--no-color') + $ExtraArgs
    $r = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $r = Invoke-Native 'choco' $chocoArgs
        if ($r.ExitCode -ne 1618) { break }
        Write-Note "another installation is running -- retry $attempt/2 in 30s"
        Start-Sleep -Seconds 30
    }
    if ($r.ExitCode -in 1641, 3010) { $script:RebootNeeded = $true; return 'choco (reboot required)' }
    if ($r.ExitCode -ne 0) { throw "choco exit $($r.ExitCode) -- $(Get-LastMeaningfulLine $r.Lines)" }
    'choco'
}

function Resolve-Scoop {
    Update-SessionEnv
    $roots = @($env:SCOOP, "$env:USERPROFILE\scoop") | Where-Object { $_ }
    foreach ($root in $roots) {
        $cmd = Join-Path $root 'shims\scoop.cmd'
        if (Test-Path -LiteralPath $cmd) {
            $shims = Split-Path $cmd
            if (@($env:Path -split ';') -notcontains $shims) { $env:Path = "$shims;$env:Path" }
            return $cmd
        }
    }
    $null
}

# scoop.cmd runs Scoop in its own process, isolating our session from
# Scoop's exit calls and error-preference handling.
function Invoke-Scoop([string[]]$ScoopArgs) {
    if (-not $script:ScoopCmd) { throw 'Scoop is not available' }
    Invoke-Native $script:ScoopCmd $ScoopArgs
}

# ============================================================
# SECTIONS
# ============================================================

function Invoke-Preflight {
    Write-Section 'Pre-flight'

    Invoke-Step 'Operating system' {
        $os = Get-CimInstance Win32_OperatingSystem
        if (-not [Environment]::Is64BitOperatingSystem) { throw 'a 64-bit OS is required' }
        if ([Environment]::OSVersion.Version.Build -lt 17763) { throw "build $([Environment]::OSVersion.Version.Build) is too old (need 17763+ / Server 2019+)" }
        Ok "$($os.Caption.Trim()) (build $($os.BuildNumber))"
    }

    Invoke-Step 'Architecture' {
        $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
        if ($arch -ne 'AMD64') { throw "x64 required (found $arch)" }
        Ok 'x64'
    }

    Invoke-Step 'PowerShell / TLS' {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor
                [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
        } catch {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        }
        Ok "PS $($PSVersionTable.PSVersion), TLS 1.2+"
    }

    Invoke-Step 'Disk space' {
        $drive  = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
        $freeGB = [math]::Round($drive.FreeSpace / 1GB, 1)
        if ($freeGB -lt 5)  { throw "only $freeGB GB free on $env:SystemDrive (need 5+ GB)" }
        if ($freeGB -lt 15) { return Warn "$freeGB GB free on $env:SystemDrive (15+ GB recommended)" }
        Ok "$freeGB GB free on $env:SystemDrive"
    }

    Invoke-Step 'Internet connectivity' {
        $targets = 'https://community.chocolatey.org', 'https://cdn.winget.microsoft.com', 'https://github.com', 'https://pypi.org'
        $failed = @(foreach ($t in $targets) {
            try { Invoke-WebRequest -Uri $t -Method Head -UseBasicParsing -TimeoutSec 20 | Out-Null }
            catch {
                # any HTTP response (even 4xx) proves the host is reachable
                if (-not ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response)) { ([uri]$t).Host }
            }
        })
        if ($failed.Count -eq $targets.Count) { throw 'no internet access (all package hosts unreachable)' }
        if ($failed.Count) { return Warn "unreachable: $($failed -join ', ')" }
        Ok 'package hosts reachable'
    }

    Invoke-Step 'Pending reboot' {
        if ($SkipRebootCheck) { return Skip 'not checked (-SkipRebootCheck)' }
        if (-not (Test-PendingReboot)) { return Ok 'none' }
        Warn 'reboot pending -- some installers may fail; reboot and re-run if they do'
    }
}

function Invoke-ChildScript([string]$Path, [string[]]$ScriptArgs = @()) {
    Invoke-Native "$PSHOME\powershell.exe" (@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Path) + $ScriptArgs)
}

function Install-PackageManagers {
    Write-Section 'Package managers'

    Invoke-Step 'Chocolatey' {
        if (Resolve-Choco) { return Skip "already installed (v$(Get-ToolVersion 'choco'))" }
        $installer = Invoke-Download 'https://community.chocolatey.org/install.ps1' (Join-Path $script:WorkDir 'choco-install.ps1')
        Assert-Signature $installer '*Chocolatey Software*'
        $r = Invoke-ChildScript $installer
        if (-not (Resolve-Choco)) { throw "choco not found after install (exit $($r.ExitCode))" }
        Invoke-Native 'choco' @('feature', 'enable', '-n', 'allowGlobalConfirmation', '--limit-output') | Out-Null
        Ok "installed v$(Get-ToolVersion 'choco')"
    }

    Invoke-Step 'winget' {
        $script:Winget = Resolve-Winget
        $ver = Get-WingetVersion
        if ($ver -and $ver -ge [version]'1.6') { return Skip "already installed (v$ver)" }
        $installer = Invoke-Download 'https://github.com/asheroto/winget-install/releases/latest/download/winget-install.ps1' (Join-Path $script:WorkDir 'winget-install.ps1')
        $r = Invoke-ChildScript $installer @('-Force')
        $script:Winget = Resolve-Winget
        $ver = Get-WingetVersion
        if (-not $ver) { throw "winget not usable after install (exit $($r.ExitCode)) -- reboot and re-run" }
        Ok "installed v$ver"
    }

    if ($script:LastStatus -ne 'FAIL' -and $script:Winget) {
        Invoke-Step 'winget source refresh' {
            $r = Invoke-Native $script:Winget @('source', 'update', '--disable-interactivity')
            if ($r.ExitCode -ne 0) { return Warn ('exit 0x{0:X8} -- using cached index' -f $r.ExitCode) }
            Ok 'winget source updated'
        }
    }

    Invoke-Step 'Scoop' {
        $script:ScoopCmd = Resolve-Scoop
        if ($script:ScoopCmd) { return Skip 'already installed' }
        $installer = Invoke-Download 'https://raw.githubusercontent.com/ScoopInstaller/Install/master/install.ps1' (Join-Path $script:WorkDir 'scoop-install.ps1')
        $r = Invoke-ChildScript $installer @('-RunAsAdmin')
        $script:ScoopCmd = Resolve-Scoop
        if (-not $script:ScoopCmd) { throw "scoop not found after install (exit $($r.ExitCode))" }
        Ok "installed to $(Split-Path (Split-Path $script:ScoopCmd))"
    }
}

function Install-CoreTools {
    Write-Section 'Core tools'
    $installed = Get-ChocoInstalled

    foreach ($id in $Config.ChocoPackages.Keys) {
        $verifyCmd = $Config.ChocoPackages[$id]
        Invoke-Step $id {
            if ($installed.ContainsKey($id)) { return Skip "already installed (choco $($installed[$id]))" }
            if ($verifyCmd) {
                $found = Get-Command $verifyCmd -ErrorAction SilentlyContinue
                if ($found -and $found.Source -notlike "$env:SystemRoot\*") { return Skip "already present ($($found.Source))" }
            }
            $via = Install-ChocoPackage $id
            Update-SessionEnv
            if ($verifyCmd -and -not (Test-Cmd $verifyCmd)) { throw "installed, but $verifyCmd is not on PATH" }
            Ok $via
        }
    }
}

function Install-ScoopPackages {
    Write-Section 'Scoop packages'
    if (-not $script:ScoopCmd) { $script:ScoopCmd = Resolve-Scoop }
    if (-not $script:ScoopCmd) {
        Invoke-Step 'Scoop packages' { throw 'Scoop is not available (see Package managers)' }
        return
    }

    foreach ($bucket in $Config.ScoopBuckets) {
        Invoke-Step "bucket: $bucket" {
            $list = Invoke-Scoop @('bucket', 'list')
            if ($list.Text -match "(?m)^\s*$([regex]::Escape($bucket))\s") { return Skip 'already added' }
            if (-not (Test-Cmd 'git.exe')) { throw 'git is required to add Scoop buckets' }
            $r = Invoke-Scoop @('bucket', 'add', $bucket)
            if ($r.ExitCode -ne 0 -and $r.Text -notmatch 'already exists') { throw "scoop exit $($r.ExitCode) -- $(Get-LastMeaningfulLine $r.Lines)" }
            Ok 'added'
        }
    }

    # --global installs to %ProgramData%\scoop so every RDP user gets the shims.
    foreach ($pkg in $Config.ScoopPackages) {
        Invoke-Step $pkg {
            $list = Invoke-Scoop @('list')
            if ($list.Text -match "(?m)^\s*$([regex]::Escape($pkg))\s") { return Skip 'already installed' }
            $r = Invoke-Scoop @('install', $pkg, '--global')
            $globalShims = Join-Path $(if ($env:SCOOP_GLOBAL) { $env:SCOOP_GLOBAL } else { "$env:ProgramData\scoop" }) 'shims'
            if (Test-Path -LiteralPath $globalShims) { [void](Add-MachinePath $globalShims) }
            Update-SessionEnv
            if (-not (Test-Cmd "$pkg.exe")) { throw "scoop exit $($r.ExitCode) -- $(Get-LastMeaningfulLine $r.Lines)" }
            Ok 'scoop (global)'
        }
    }
}

function Get-AppxX64([string]$Name, [switch]$AllUsers) {
    $p = if ($AllUsers) { Get-AppxPackage -AllUsers -Name $Name -ErrorAction SilentlyContinue }
         else           { Get-AppxPackage -Name $Name -ErrorAction SilentlyContinue }
    @($p | Where-Object { "$($_.Architecture)" -in 'X64', 'Neutral' }) | Sort-Object Version -Descending | Select-Object -First 1
}

# Add-AppxPackage that treats "a same-or-newer version is already installed" as success.
function Add-AppxSafe([string]$Path) {
    try { Add-AppxPackage -Path $Path -ForceApplicationShutdown -ErrorAction Stop }
    catch { if ($_.Exception.Message -notmatch '0x80073D06|higher version|already installed') { throw } }
}

function Install-WindowsTerminal {
    Write-Section 'Windows Terminal'
    $deps = @{}

    Invoke-Step 'VCLibs 14 (x64)' {
        if (Get-AppxX64 'Microsoft.VCLibs.140.00.UWPDesktop') { return Skip 'already installed' }
        $deps.VCLibs = Invoke-Download $Config.VCLibsUrl (Join-Path $script:WorkDir 'VCLibs.x64.appx')
        Assert-Signature $deps.VCLibs '*Microsoft Corporation*'
        Add-AppxSafe $deps.VCLibs
        Ok 'installed'
    }

    Invoke-Step 'Microsoft.UI.Xaml 2.8 (x64)' {
        if (Get-AppxX64 'Microsoft.UI.Xaml.2.8') { return Skip 'already installed' }
        $deps.UIXaml = Invoke-Download $Config.UiXamlUrl (Join-Path $script:WorkDir 'UIXaml.2.8.x64.appx')
        Assert-Signature $deps.UIXaml '*Microsoft Corporation*'
        Add-AppxSafe $deps.UIXaml
        Ok 'installed'
    }

    Invoke-Step 'Windows Terminal' {
        $pkg = Get-AppxX64 'Microsoft.WindowsTerminal' -AllUsers
        if ($pkg) { return Skip "already installed (v$($pkg.Version))" }

        try {
            # Latest GitHub release; the API publishes a SHA256 digest per asset.
            $rel   = Invoke-RestMethod 'https://api.github.com/repos/microsoft/terminal/releases/latest' -UseBasicParsing -TimeoutSec 30
            $asset = $rel.assets | Where-Object { $_.name -like 'Microsoft.WindowsTerminal_*_8wekyb3d8bbwe.msixbundle' } | Select-Object -First 1
            if (-not $asset) { throw 'msixbundle asset not found in latest release' }
            $sha    = if ($asset.PSObject.Properties['digest'] -and $asset.digest -like 'sha256:*') { $asset.digest.Substring(7) } else { '' }
            $bundle = Invoke-Download $asset.browser_download_url (Join-Path $script:WorkDir $asset.name) $sha
            Assert-Signature $bundle '*Microsoft Corporation*'

            # Provision for all (incl. future) users, then register for this user.
            $prov = @{ Online = $true; PackagePath = $bundle; SkipLicense = $true }
            $depPaths = @($deps.Values | Where-Object { $_ })
            if ($depPaths) { $prov.DependencyPackagePath = $depPaths }
            try { Add-AppxProvisionedPackage @prov -ErrorAction Stop | Out-Null }
            catch { Write-Log "WARN  provisioning failed: $($_.Exception.Message)" }
            Add-AppxSafe $bundle
            $via = "GitHub $($rel.tag_name)"
        } catch {
            Write-Log "WARN  GitHub install failed: $($_.Exception.Message) -- falling back to choco"
            Write-Note "GitHub install failed ($(Format-Error $_)) -- trying Chocolatey"
            $via = Install-ChocoPackage 'microsoft-windows-terminal'
        }

        $pkg = Get-AppxX64 'Microsoft.WindowsTerminal' -AllUsers
        if (-not $pkg) { throw 'Windows Terminal package not present after install' }
        Ok "v$($pkg.Version) via $via"
    }

    Invoke-Step 'Terminal: register for current user' {
        if (Get-AppxX64 'Microsoft.WindowsTerminal') { return Skip 'already registered' }
        $pkg = Get-AppxX64 'Microsoft.WindowsTerminal' -AllUsers
        if (-not $pkg) { throw 'Windows Terminal is not installed' }
        Add-AppxPackage -DisableDevelopmentMode -Register (Join-Path $pkg.InstallLocation 'AppxManifest.xml') -ErrorAction Stop
        Ok 'registered'
    }

    Invoke-Step 'Terminal: wt.exe alias' {
        # Older versions of this script put a version-specific WindowsApps folder on the
        # machine PATH; it breaks on every Terminal update. The per-user alias is the right way.
        $removed = Remove-MachinePathLike '*\WindowsApps\Microsoft.WindowsTerminal_*'
        $alias = "$env:LOCALAPPDATA\Microsoft\WindowsApps\wt.exe"
        if (-not (Test-Path -LiteralPath $alias)) { return Warn 'wt.exe alias missing -- sign out/in, or reboot' }
        if ($removed) { return Ok "alias OK; removed $removed stale machine PATH entr(y/ies)" }
        Ok 'alias OK'
    }
}

# Tries winget, then Chocolatey, then an optional custom fallback.
# Returns "via" text of the first that succeeds; throws with all reasons otherwise.
function Install-WithFallback([string]$WingetId, [string]$ChocoId, [scriptblock]$Fallback) {
    $errs = [System.Collections.Generic.List[string]]::new()
    if ($WingetId) {
        if ($script:Winget) {
            try { return (Install-WingetPackage $WingetId) }
            catch { $errs.Add((Format-Error $_)); Write-Note "winget failed: $(Format-Error $_)" }
        } else { $errs.Add('winget unavailable') }
    }
    if ($ChocoId) {
        if (Test-Cmd 'choco') {
            try { $via = Install-ChocoPackage $ChocoId; Update-SessionEnv; return $via }
            catch { $errs.Add((Format-Error $_)); if ($Fallback) { Write-Note "choco failed: $(Format-Error $_)" } }
        } else { $errs.Add('choco unavailable') }
    }
    if ($Fallback) {
        try { return (& $Fallback) } catch { $errs.Add((Format-Error $_)) }
    }
    throw ($errs -join ' | ')
}

function Find-Chrome {
    foreach ($p in "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
                   "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    $null
}

function Install-Applications {
    Write-Section 'Applications'

    Invoke-Step 'Google Chrome' {
        $exe = Find-Chrome
        if ($exe) { return Skip "already installed (v$((Get-Item -LiteralPath $exe).VersionInfo.ProductVersion))" }

        # winget's Chrome manifest often lags Google's rolling installer (hash mismatch),
        # so the signed enterprise MSI from Google is the fallback.
        $via = Install-WithFallback 'Google.Chrome' $null {
            Write-Note 'downloading Google enterprise MSI directly'
            $msi = Invoke-Download $Config.ChromeMsiUrl (Join-Path $script:WorkDir 'googlechromestandaloneenterprise64.msi')
            Assert-Signature $msi '*Google LLC*'
            $log = Join-Path $LogPath 'chrome-msi.log'
            [void](Invoke-Installer "$env:SystemRoot\System32\msiexec.exe" "/i `"$msi`" /qn /norestart /l*v `"$log`"")
            'Google MSI'
        }

        $exe = Find-Chrome
        if (-not $exe) { throw "installer reported success ($via) but chrome.exe was not found" }
        Ok "v$((Get-Item -LiteralPath $exe).VersionInfo.ProductVersion) via $via"
    }

    Invoke-Step 'aria2' {
        $found = Get-Command aria2c.exe -ErrorAction SilentlyContinue
        if ($found) { return Skip "already installed ($(Get-ToolVersion 'aria2c.exe'))" }

        $via = Install-WithFallback $null 'aria2' {
            # Pinned, hash-verified upstream build -> %ProgramFiles%\aria2
            Write-Note 'installing pinned upstream build'
            $zip = Invoke-Download $Config.Aria2.Url (Join-Path $script:WorkDir 'aria2.zip') $Config.Aria2.Sha256
            $tmp = Join-Path $script:WorkDir 'aria2-extract'
            Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
            $src = Get-ChildItem -LiteralPath $tmp -Recurse -Filter aria2c.exe | Select-Object -First 1
            if (-not $src) { throw 'aria2c.exe not found in archive' }
            New-Item -ItemType Directory -Path $Config.Aria2.Dir -Force | Out-Null
            Copy-Item -Path (Join-Path $src.DirectoryName '*') -Destination $Config.Aria2.Dir -Recurse -Force
            "upstream $($Config.Aria2.Version)"
        }

        # Guarantee it is on the machine PATH for every user, whichever route installed it.
        Update-SessionEnv
        $cmd = Get-Command aria2c.exe -ErrorAction SilentlyContinue
        $dir = if ($cmd) { Split-Path $cmd.Source } else {
            @("$env:ProgramData\chocolatey\bin", $Config.Aria2.Dir) |
                Where-Object { Test-Path -LiteralPath (Join-Path $_ 'aria2c.exe') } | Select-Object -First 1
        }
        if (-not $dir) { throw 'aria2c.exe not found after install' }
        $added = Add-MachinePath $dir
        $ver = Get-ToolVersion 'aria2c.exe'
        if (-not $ver) { throw 'aria2c.exe does not run' }
        Ok "$ver via $via$(if ($added) { '; PATH += ' + $dir })"
    }
}

# Newest file matching any of the globs (version folders sorted numerically).
function Find-Exe([string[]]$Globs) {
    $hits = foreach ($g in $Globs) { Get-ChildItem -Path $g -ErrorAction SilentlyContinue }
    $hits | Sort-Object @{ Expression = {
        $v = [regex]::Match($_.FullName, '\\(\d+(\.\d+)*)\\').Groups[1].Value
        if ($v) { [version]($v + $(if ($v -notmatch '\.') { '.0' })) } else { [version]'0.0' }
    } } -Descending | Select-Object -First 1
}

# Generic "install via winget/choco, then make sure the exe is on machine PATH".
function Install-PathTool([string]$WingetId, [string]$ChocoId, [string]$Exe, [string[]]$Globs, [string[]]$VersionArgs = @('--version')) {
    $existing = Get-Command $Exe -ErrorAction SilentlyContinue
    $file = if ($existing) { Get-Item -LiteralPath $existing.Source } else { Find-Exe $Globs }
    $via  = $null
    if (-not $file) {
        $via = Install-WithFallback $WingetId $ChocoId $null
        Update-SessionEnv
        $file = Find-Exe $Globs
        if (-not $file) { $c = Get-Command $Exe -ErrorAction SilentlyContinue; if ($c) { $file = Get-Item -LiteralPath $c.Source } }
        if (-not $file) { throw "installed via $via, but $Exe was not found" }
    }
    $added = Add-MachinePath $file.DirectoryName
    $ver = Get-ToolVersion $file.FullName $VersionArgs
    if (-not $ver) { throw "$Exe does not run ($($file.FullName))" }
    $msg = if ($via) { "$ver via $via" } else { "$ver (already installed)" }
    if ($added) { $msg += "; PATH += $($file.DirectoryName)" }
    if ($via -or $added) { Ok $msg } else { Skip $msg }
}

function Install-MongoDB {
    Write-Section 'MongoDB'

    Invoke-Step 'MongoDB Server' {
        Install-PathTool 'MongoDB.Server' 'mongodb' 'mongod.exe' @("$env:ProgramFiles\MongoDB\Server\*\bin\mongod.exe")
    }
    $serverStatus = $script:LastStatus

    if ($serverStatus -ne 'FAIL') {
        Invoke-Step 'MongoDB: PATH cleanup' {
            $exe = Find-Exe @("$env:ProgramFiles\MongoDB\Server\*\bin\mongod.exe")
            if (-not $exe) { return Skip 'mongod not under Program Files -- nothing to clean' }
            $cur = $exe.DirectoryName
            $n = Remove-MachinePathLike '*\MongoDB\Server\*\bin*' -Except $cur
            if ($n) { Ok "removed $n old Server bin entr(y/ies)" } else { Skip 'no stale entries' }
        }

        Invoke-Step 'MongoDB: service' {
            $svc = Get-Service -Name MongoDB -ErrorAction SilentlyContinue
            if (-not $svc) { return Warn "no 'MongoDB' service -- run mongod manually or reinstall with the service feature" }
            $did = @()
            if ($svc.StartType -ne 'Automatic') { Set-Service -Name MongoDB -StartupType Automatic; $did += 'set Automatic' }
            if ($svc.Status -ne 'Running') {
                Start-Service -Name MongoDB
                (Get-Service -Name MongoDB).WaitForStatus('Running', [TimeSpan]::FromSeconds(60))
                $did += 'started'
            }
            $port = Get-NetTCPConnection -State Listen -LocalPort 27017 -ErrorAction SilentlyContinue | Select-Object -First 1
            $state = "running, automatic$(if ($port) { ', listening :27017' } else { ' (port 27017 not listening yet)' })"
            if ($did) { Ok "$state ($($did -join ', '))" } else { Skip $state }
        }
    }

    Invoke-Step 'MongoDB Shell (mongosh)' {
        Install-PathTool 'MongoDB.Shell' 'mongodb-shell' 'mongosh.exe' @(
            "$env:ProgramFiles\mongosh\mongosh.exe", "$env:LOCALAPPDATA\Programs\mongosh\mongosh.exe")
    }

    Invoke-Step 'MongoDB Database Tools' {
        Install-PathTool 'MongoDB.DatabaseTools' 'mongodb-database-tools' 'mongodump.exe' @(
            "$env:ProgramFiles\MongoDB\Tools\*\bin\mongodump.exe")
    }

    # Compass "Full" is the current free edition; the separate Community package
    # stopped at 1.41.0. An existing Community install is accepted as-is.
    Invoke-Step 'MongoDB Compass' {
        $app = Get-InstalledApp 'MongoDB Compass*' | Select-Object -First 1
        if ($app) { return Skip "already installed ($($app.Name) $($app.Version))" }
        $via = Install-WithFallback 'MongoDB.Compass.Full' 'mongodb-compass' $null
        $app = Get-InstalledApp 'MongoDB Compass*' | Select-Object -First 1
        if (-not $app) { throw "installer reported success ($via) but Compass is not registered" }
        Ok "$($app.Version) via $via"
    }
}

function Find-Python {
    $tag = $Config.PythonVersion -replace '\.', ''
    $exe = @("$env:ProgramFiles\Python$tag\python.exe", "$env:SystemDrive\Python$tag\python.exe",
             "$env:LOCALAPPDATA\Programs\Python\Python$tag\python.exe") |
           Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($exe) { return $exe }
    # py launcher knows about any registered install of this version
    if (Test-Cmd 'py.exe') {
        $r = Invoke-Native 'py.exe' @("-$($Config.PythonVersion)", '-c', 'import sys; print(sys.executable)')
        $p = $r.Lines | Where-Object { $_ -like '*python.exe' } | Select-Object -First 1
        if ($r.ExitCode -eq 0 -and $p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    $null
}

function Invoke-Pip([string[]]$PipArgs) {
    Invoke-Native $script:Python (@('-m', 'pip') + $PipArgs + @('--disable-pip-version-check', '--no-input'))
}

function Install-Python {
    Write-Section 'Python'
    $script:Python = $null

    Invoke-Step "Python $($Config.PythonVersion)" {
        $script:Python = Find-Python
        $via = $null
        if (-not $script:Python) {
            $via = Install-WithFallback $Config.PythonWinget $Config.PythonChoco $null
            $script:Python = Find-Python
            if (-not $script:Python) { throw "installed via $via, but python $($Config.PythonVersion) was not found" }
        }
        # Prepend so this interpreter wins over older Pythons and the Store alias stub.
        $dir = Split-Path $script:Python
        $changed = Add-MachinePath $dir -Prepend
        $scripts = Join-Path $dir 'Scripts'
        if (Test-Path -LiteralPath $scripts) { $changed = (Add-MachinePath $scripts) -or $changed }
        $ver = Get-ToolVersion $script:Python
        if (-not $ver) { throw "$script:Python does not run" }
        $msg = "$ver at $dir$(if ($via) { " via $via" })$(if ($changed) { '; PATH updated' })"
        if ($via -or $changed) { Ok $msg } else { Skip $msg }
    }
    if (-not $script:Python) { return }

    Invoke-Step 'pip / setuptools / wheel' {
        $r = Invoke-Pip @('install', '--upgrade', '--progress-bar', 'off', 'pip', 'setuptools', 'wheel')
        if ($r.ExitCode -ne 0) { throw "pip exit $($r.ExitCode) -- $(Get-LastMeaningfulLine $r.Lines)" }
        Ok ((Get-ToolVersion $script:Python @('-m', 'pip', '--version')) -replace ' from .*$', '')
    }

    Invoke-Step "Project packages ($($Config.PipPackages.Count))" {
        $common = @('install', '--upgrade', '--progress-bar', 'off', '--prefer-binary', '--no-warn-script-location')
        $r = Invoke-Pip ($common + $Config.PipPackages)
        if ($r.ExitCode -eq 0) { return Ok "$($Config.PipPackages.Count) packages installed/up to date" }

        # Bulk install failed: isolate the offenders so the rest still get installed.
        Write-Note 'bulk install failed -- retrying one by one'
        $failed = @(foreach ($p in $Config.PipPackages) {
            $one = Invoke-Pip ($common + $p)
            if ($one.ExitCode -ne 0) { $p }
        })
        if ($failed.Count) { throw "failed: $($failed -join ', ') (details in log)" }
        Ok 'installed (after per-package retry)'
    }

    Invoke-Step 'pip check' {
        $r = Invoke-Pip @('check')
        if ($r.ExitCode -eq 0) { return Ok 'no dependency conflicts' }
        $n = @($r.Lines | Where-Object { $_ -match ' has requirement | requires ' }).Count
        Warn "$n dependency conflict(s) -- see log"
    }

    # Shared browser store so all RDP users can run Playwright.
    Invoke-Step 'Playwright browsers' {
        New-Item -ItemType Directory -Path $Config.PlaywrightPath -Force | Out-Null
        Set-MachineEnv 'PLAYWRIGHT_BROWSERS_PATH' $Config.PlaywrightPath
        $r = Invoke-Native $script:Python @('-m', 'playwright', 'install')
        if ($r.ExitCode -ne 0) { throw "playwright exit $($r.ExitCode) -- $(Get-LastMeaningfulLine $r.Lines)" }
        $browsers = @(Get-ChildItem -LiteralPath $Config.PlaywrightPath -Directory -ErrorAction SilentlyContinue |
                      ForEach-Object { $_.Name -replace '-\d+$', '' } |
                      Where-Object { $_ -in 'chromium', 'firefox', 'webkit' } | Sort-Object -Unique)
        Ok "$($browsers -join ', ') in $($Config.PlaywrightPath)"
    }
}

function Invoke-Verification {
    Write-Section 'Verification'
    Write-Note 'PATH rebuilt from the registry -- results match what a new session sees'

    # Rebuild PATH from the registry only, so tools that work only because of
    # this session's in-memory PATH edits are caught.
    $env:Path = (@('Machine', 'User') | ForEach-Object {
        [Environment]::GetEnvironmentVariable('Path', $_) -split ';' | Where-Object { $_ } |
            ForEach-Object { [Environment]::ExpandEnvironmentVariables($_) }
    }) -join ';'

    $tools = @(
        @('Chocolatey',      'choco.exe',     @('--version')),
        @('winget',          'winget.exe',    @('--version')),
        @('Scoop',           'scoop.cmd',     @('--version')),
        @('git',             'git.exe',       @('--version')),
        @('ffmpeg',          'ffmpeg.exe',    @('-version')),
        @('7-Zip',           '7z.exe',        @('i')),
        @('jq',              'jq.exe',        @('--version')),
        @('curl',            'curl.exe',      @('--version')),
        @('wget',            'wget.exe',      @('--version')),
        @('gifsicle',        'gifsicle.exe',  @('--version')),
        @('aria2',           'aria2c.exe',    @('--version')),
        @('mongod',          'mongod.exe',    @('--version')),
        @('mongosh',         'mongosh.exe',   @('--version')),
        @('mongodump',       'mongodump.exe', @('--version'))
    )
    foreach ($t in $tools) {
        $label, $exe, $vargs = $t
        Invoke-Step $label {
            $cmd = Get-Command $exe -ErrorAction SilentlyContinue
            if (-not $cmd) { throw "$exe not on PATH" }
            $ver = Get-ToolVersion $cmd.Source $vargs
            if (-not $ver) { throw "$exe found but did not run ($($cmd.Source))" }
            Ok $ver
        }
    }

    Invoke-Step 'python' {
        $cmd = Get-Command python.exe -ErrorAction SilentlyContinue
        if (-not $cmd) { throw 'python.exe not on PATH' }
        $ver = Get-ToolVersion $cmd.Source
        if ($cmd.Source -like '*\Microsoft\WindowsApps\*') { throw 'python.exe resolves to the Microsoft Store alias stub' }
        if ($ver -notlike "Python $($Config.PythonVersion).*") { return Warn "python.exe is $ver ($($cmd.Source)), expected $($Config.PythonVersion)" }
        Ok "$ver ($(Split-Path $cmd.Source))"
    }

    Invoke-Step 'Python packages' {
        $py = if ($script:Python) { $script:Python } else {
            $c = Get-Command python.exe -ErrorAction SilentlyContinue; if ($c) { $c.Source } }
        if (-not $py) { throw 'python.exe not found' }
        $checker = Join-Path $script:WorkDir 'pkgcheck.py'
        Set-Content -LiteralPath $checker -Encoding ASCII -Value @(
            'import sys, importlib.metadata as md'
            'missing = []'
            'for name in sys.argv[1:]:'
            '    try: md.version(name)'
            '    except md.PackageNotFoundError: missing.append(name)'
            'print("MISSING:" + ",".join(missing) if missing else "ALL-OK")'
        )
        $names = $Config.PipPackages | ForEach-Object { $_ -replace '\[.*\]$', '' }
        $r = Invoke-Native $py (@('-I', $checker) + $names)
        $line = $r.Lines | Where-Object { $_ -match '^(ALL-OK|MISSING:)' } | Select-Object -Last 1
        if (-not $line) { throw "package check did not run (exit $($r.ExitCode))" }
        if ($line -like 'MISSING:*') { throw "missing: $($line.Substring(8) -replace ',', ', ')" }
        Ok "all $($names.Count) present"
    }

    Invoke-Step 'Playwright browsers' {
        $store = [Environment]::GetEnvironmentVariable('PLAYWRIGHT_BROWSERS_PATH', 'Machine')
        if (-not $store) { throw 'PLAYWRIGHT_BROWSERS_PATH not set' }
        $found = @(Get-ChildItem -LiteralPath $store -Directory -Filter 'chromium-*' -ErrorAction SilentlyContinue)
        if (-not $found.Count) { throw "no Chromium build in $store" }
        Ok "Chromium present in $store"
    }

    Invoke-Step 'Google Chrome' {
        $exe = Find-Chrome
        if (-not $exe) { throw 'chrome.exe not found' }
        Ok "v$((Get-Item -LiteralPath $exe).VersionInfo.ProductVersion)"
    }

    Invoke-Step 'MongoDB service' {
        $svc = Get-Service -Name MongoDB -ErrorAction SilentlyContinue
        if (-not $svc) { throw "service 'MongoDB' not found" }
        if ($svc.Status -ne 'Running') { throw "service is $($svc.Status)" }
        Ok "Running ($($svc.StartType))"
    }

    Invoke-Step 'MongoDB Compass' {
        $app = Get-InstalledApp 'MongoDB Compass*' | Select-Object -First 1
        if (-not $app) { throw 'not installed' }
        Ok "$($app.Name) $($app.Version)"
    }

    Invoke-Step 'Windows Terminal' {
        $pkg = Get-AppxX64 'Microsoft.WindowsTerminal'
        if (-not $pkg) { throw 'not registered for this user' }
        if (-not (Test-Path -LiteralPath "$env:LOCALAPPDATA\Microsoft\WindowsApps\wt.exe")) { return Warn "v$($pkg.Version), wt.exe alias missing (sign out/in)" }
        Ok "v$($pkg.Version), wt.exe alias OK"
    }
}

# ============================================================
# SUMMARY
# ============================================================

function Show-Summary {
    Close-PendingLine
    $elapsed = (Get-Date) - $script:StartTime
    $count = { param($rows, $s) @($rows | Where-Object Status -eq $s).Count }

    Write-Host ''
    Write-Host ' SUMMARY'.PadRight(70) -ForegroundColor White -BackgroundColor DarkMagenta
    Write-Host ''
    Write-Host ('  {0,-26} {1,5} {2,5} {3,5} {4,5}' -f 'Section', 'OK', 'SKIP', 'WARN', 'FAIL') -ForegroundColor Gray
    Write-Host ('  ' + ('-' * 50)) -ForegroundColor DarkGray

    $sections = $script:Results | Select-Object -ExpandProperty Section -Unique
    foreach ($sec in $sections) {
        $rows = @($script:Results | Where-Object Section -eq $sec)
        $ok, $sk, $wn, $fl = 'OK', 'SKIP', 'WARN', 'FAIL' | ForEach-Object { & $count $rows $_ }
        $name = if ($sec.Length -gt 26) { $sec.Substring(0, 23) + '...' } else { $sec }
        $color = if ($fl) { 'Red' } elseif ($wn) { 'Yellow' } else { 'Green' }
        Write-Host ('  {0,-26}' -f $name) -ForegroundColor $color -NoNewline
        Write-Host (' {0,5}' -f $ok) -ForegroundColor $(if ($ok) { 'Green'    } else { 'DarkGray' }) -NoNewline
        Write-Host (' {0,5}' -f $sk) -ForegroundColor DarkGray -NoNewline
        Write-Host (' {0,5}' -f $wn) -ForegroundColor $(if ($wn) { 'Yellow'   } else { 'DarkGray' }) -NoNewline
        Write-Host (' {0,5}' -f $fl) -ForegroundColor $(if ($fl) { 'Red'      } else { 'DarkGray' })
    }

    $all = $script:Results
    $tOk, $tSk, $tWn, $tFl = 'OK', 'SKIP', 'WARN', 'FAIL' | ForEach-Object { & $count $all $_ }
    Write-Host ('  ' + ('-' * 50)) -ForegroundColor DarkGray
    Write-Host ('  {0,-26} {1,5} {2,5} {3,5} {4,5}' -f 'Total', $tOk, $tSk, $tWn, $tFl) -ForegroundColor White

    foreach ($s in 'FAIL', 'WARN') {
        $rows = @($all | Where-Object Status -eq $s)
        if (-not $rows.Count) { continue }
        Write-Host ''
        Write-Host $(if ($s -eq 'FAIL') { '  Failures' } else { '  Warnings' }) -ForegroundColor $script:Tags[$s][1]
        foreach ($r in $rows) {
            Write-Host "   $($script:Tags[$s][0]) " -ForegroundColor $script:Tags[$s][1] -NoNewline
            Write-Host "$($r.Section) > $($r.Item)" -NoNewline
            if ($r.Detail) { Write-Host "  $($r.Detail)" -ForegroundColor DarkGray } else { Write-Host '' }
        }
    }

    Write-Host ''
    $reboot = $script:RebootNeeded -or (Test-PendingReboot)
    Write-Host '  Reboot   : ' -ForegroundColor Gray -NoNewline
    if ($reboot) { Write-Host 'REQUIRED -- reboot, then re-run to confirm' -ForegroundColor Yellow }
    else         { Write-Host 'not required' -ForegroundColor Green }
    Write-Host '  Duration : ' -ForegroundColor Gray -NoNewline
    Write-Host ('{0:%h}h {0:%m}m {0:%s}s' -f $elapsed)
    Write-Host '  Log      : ' -ForegroundColor Gray -NoNewline
    Write-Host $script:LogFile
    Write-Host ''

    if ($tFl) {
        Write-Host "  Finished with $tFl failure(s). Fix the items above and re-run -- completed steps are skipped." -ForegroundColor Red
    } else {
        Write-Host '  Setup complete. Open a NEW terminal (wt) so PATH changes apply.' -ForegroundColor Green
    }
    Write-Host ''

    Write-Log "SUMMARY ok=$tOk skip=$tSk warn=$tWn fail=$tFl reboot=$reboot elapsed=$elapsed"
    [int]($tFl -gt 0)
}

# ============================================================
# MAIN
# ============================================================

$sections = @(
    'Install-PackageManagers', 'Install-CoreTools', 'Install-ScoopPackages', 'Install-WindowsTerminal',
    'Install-Applications', 'Install-MongoDB', 'Install-Python', 'Invoke-Verification'
)
$script:SectionCount = $sections.Count + 1   # + Pre-flight

# One run at a time (two parallel runs would fight over msiexec / choco locks).
$mutex = New-Object System.Threading.Mutex($false, 'Global\RdpSetupScript')
$haveLock = $false
try { $haveLock = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $haveLock = $true }
if (-not $haveLock) { Write-Host 'Another instance of this setup script is already running.' -ForegroundColor Red; exit 1 }

$exitCode = 1
try {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
    $script:LogFile = Join-Path $LogPath ('setup_{0:yyyyMMdd_HHmmss}.log' -f (Get-Date))
    $script:WorkDir = Join-Path $env:TEMP ('rdp-setup-{0:yyyyMMddHHmmss}' -f (Get-Date))
    New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null
    Write-Log "START $($MyInvocation.MyCommand.Path) as $($identity.Name) on $env:COMPUTERNAME"

    try { $Host.UI.RawUI.WindowTitle = 'Server setup' } catch { }
    Write-Host ''
    Write-Host '  SERVER SETUP' -ForegroundColor Cyan -NoNewline
    Write-Host ("  $env:COMPUTERNAME  |  $($identity.Name)  |  {0:yyyy-MM-dd HH:mm}" -f (Get-Date)) -ForegroundColor DarkGray
    Write-Host "  Log: $script:LogFile" -ForegroundColor DarkGray

    try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { }
    $env:PYTHONIOENCODING = 'utf-8'

    Update-SessionEnv
    Invoke-Preflight
    $fatal = @($script:Results | Where-Object { $_.Section -eq 'Pre-flight' -and $_.Status -eq 'FAIL' })
    if ($fatal.Count) {
        Write-Host ''
        Write-Host '  Pre-flight failed -- nothing was installed.' -ForegroundColor Red
    } else {
        foreach ($s in $sections) {
            # Steps never throw; this only catches bugs in section glue code.
            try { & $s }
            catch {
                Close-PendingLine
                Write-Log "ERROR section $s crashed: $($_.Exception.Message) $($_.InvocationInfo.PositionMessage)"
                $script:Results.Add([pscustomobject]@{ Section = $script:Section; Item = "$s (section aborted)"; Status = 'FAIL'; Detail = (Format-Error $_) })
                Write-Status 'FAIL' "$s aborted" (Format-Error $_)
            }
        }
    }
    $exitCode = Show-Summary
} catch {
    Close-PendingLine
    Write-Host ''
    Write-Host "  Fatal error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  $($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkGray
    Write-Log "FATAL $($_.Exception.Message) $($_.ScriptStackTrace)"
    $exitCode = 1
} finally {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir)) {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($haveLock) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
exit $exitCode
