<#
.SYNOPSIS
    Portable PowerShell script to set up Suno Automation development environment.
.DESCRIPTION
    This script provides a robust, portable, and idempotent solution for setting up
    'suno-automation' project. It performs the following actions:
    1.  Sets up a dual-channel logging framework (File and Windows Event Viewer).
    2.  Validates prerequisites (Git, Node.js, Python) against minimum versions.
    3.  Automatically installs or upgrades missing/outdated prerequisites using winget.
    4.  Clones 'suno-automation' repository from GitHub.
    5.  Creates a Python virtual environment and installs dependencies without requiring activation.
    6.  Installs frontend dependencies using npm.
    7.  Supports a -NonInteractive switch for CI/CD environments.
.PARAMETER NonInteractive
    If specified, script will not prompt for user input at the end of execution.
.EXAMPLE
   .\setup-windows.ps1
.EXAMPLE
   .\setup-windows.ps1 -NonInteractive
#>

param(
    [switch]$NonInteractive
)

# --- Script Configuration ---
$RepoUrl = "https://github.com/vnmw7/suno-automation.git"
$RepoName = "suno-automation"
$MinNodeVersion = [version]'24.10.0'
$MinPythonVersion = [version]'3.14.0'
$EventSource = "Suno Automation Setup"

# NVM Configuration
$NvmVersion = "1.1.12"
$NvmDownloadUrl = "https://github.com/coreybutler/nvm-windows/releases/download/$NvmVersion/nvm-setup.exe"

# --- Path and Logging Initialization ---
# Use $PSScriptRoot for reliable, portable pathing.
$ScriptRoot = $PSScriptRoot
$ProjectRoot = Join-Path $ScriptRoot $RepoName
$LogDir = Join-Path $ScriptRoot "logs"

# Set up logging immediately.
try {
    if (-not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction Stop | Out-Null
    }
    $Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $LogFile = Join-Path $LogDir "setup-windows-$($Timestamp).log"
    "Script started at $(Get-Date)" | Out-File -FilePath $LogFile -Encoding UTF8 -ErrorAction Stop
} catch {
    Write-Host " CRITICAL: Failed to initialize file logging at '$LogDir'. Please check permissions. Aborting." -ForegroundColor Red
    exit 1
}

# --- Core Functions ---

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$Level
    )
    $logEntry = "[$Level] $Message"
    $color = @{
        INFO    = "White"
        WARN    = "Yellow"
        ERROR   = "Red"
        SUCCESS = "Green"
        DEBUG   = "Gray"
    }[$Level]

    Write-Host $logEntry -ForegroundColor $color
    Add-Content -Path $LogFile -Value $logEntry

    # Write to Event Viewer, failing gracefully if permissions are insufficient.
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($EventSource)) {
            # This operation requires elevation.
            New-EventLog -LogName Application -Source $EventSource -ErrorAction Stop
        }
        $eventType = @{
            ERROR = "Error"
            WARN  = "Warning"
        }.GetEnumerator() | Where-Object { $_.Key -eq $Level } | ForEach-Object { $_.Value }
        if (-not $eventType) { $eventType = "Information" }

        Write-EventLog -LogName Application -Source $EventSource -EventId 1 -EntryType $eventType -Message $Message -ErrorAction SilentlyContinue
    } catch {
        # Non-critical failure, log to file and continue.
        $eventViewerError = " Could not write to Windows Event Viewer. Error: $($_.Exception.Message)"
        Add-Content -Path $LogFile -Value $eventViewerError
    }
}

function Run-Exe {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$SuccessMessage = "",
        [string]$FailureMessage = "",
        [switch]$ContinueOnError,
        [switch]$AttachConsole   # NEW: Allow console-attached execution
    )
    Write-Log "Executing: $FilePath $($ArgumentList -join ' ')" "DEBUG"
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $FilePath

        if ($AttachConsole) {
            # Share current console and DO NOT redirect.
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $false
            $psi.RedirectStandardError  = $false
            $psi.CreateNoWindow = $true   # don't spawn a new console
        } else {
            # Old behavior: capture output for logging.
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.CreateNoWindow = $true
        }

        foreach ($arg in $ArgumentList) { [void]$psi.ArgumentList.Add($arg) }

        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        $null = $p.Start()
        if (-not $AttachConsole) {
            $stdout = $p.StandardOutput.ReadToEnd()
            $stderr = $p.StandardError.ReadToEnd()
        }
        $p.WaitForExit()
        $code = $p.ExitCode
        if ($code -eq 0) {
            if ($SuccessMessage) { Write-Log $SuccessMessage "SUCCESS" }
            if (-not $AttachConsole) {
                if ($stdout.Trim()) { Write-Log "Out: $($stdout.Trim())" "DEBUG" }
                if ($stderr.Trim()) { Write-Log "Err: $($stderr.Trim())" "DEBUG" }
            }
            return $true
        } else {
            Write-Log "$FailureMessage (Exit Code: $code)" "ERROR"
            if (-not $AttachConsole) {
                if ($stdout.Trim()) { Write-Log "Out: $($stdout.Trim())" "ERROR" }
                if ($stderr.Trim()) { Write-Log "Err: $($stderr.Trim())" "ERROR" }
            }
            if (-not $ContinueOnError) {
                $script:blnSuccess = $false
                $script:strInstallReport += "$FailureMessage`n"
            }
            return $false
        }
    } catch {
        Write-Log "$FailureMessage (Exception: $($_.Exception.Message))" "ERROR"
        if (-not $ContinueOnError) {
            $script:blnSuccess = $false
            $script:strInstallReport += "$FailureMessage`n"
        }
        return $false
    }
}

function Get-CommandVersion {
    param([string]$Command, [string]$VersionArgument)
    try {
        $output = & $Command $VersionArgument 2>&1 | Out-String
        if ($output -match '(\d+\.\d+\.\d+)') {
            return [version]$matches[1]
        }
        return $null
    } catch {
        return $null
    }
}

function Get-WingetPackage {
    param([Parameter(Mandatory=$true)][string]$Id)
    $args = @("list", "-e", "--id", $Id)
    Write-Log "winget $($args -join ' ')" "DEBUG"
    $psi = (Run-Exe -FilePath "winget" -ArgumentList $args -SuccessMessage "" -FailureMessage "winget list failed" -ContinueOnError)
    if (-not $psi) {
        return $null
    }
    # Re-run to capture output
    $p = Start-Process -FilePath "winget" -ArgumentList $args -NoNewWindow -PassThru -Wait -RedirectStandardOutput ([IO.Path]::GetTempFileName()) -RedirectStandardError ([IO.Path]::GetTempFileName())
    $out = Get-Content $p.StandardOutput -Raw
    if ($p.ExitCode -ne 0 -or -not $out) { return $null }
    # Heuristic: any non-header line indicates presence
    if ($out -match "^\s*\S+" -and $out -match "Version") { return $out }
    return $null
}

function InstallOrUpgrade-Package {
    param(
        [Parameter(Mandatory=$true)][string]$Id,
        [string]$FriendlyName = $Id
    )
    $present = Get-WingetPackage -Id $Id
    if (-not $present) {
        Write-Log "$FriendlyName not tracked by winget. Installing..." "INFO"
        if (-not (Run-Exe -FilePath "winget" -ArgumentList @("install","-e","--id",$Id,"--accept-package-agreements","--accept-source-agreements") -SuccessMessage "$FriendlyName installed." -FailureMessage "Failed to install $FriendlyName.")) {
            return $false
        }
        return $true
    } else {
        Write-Log "$FriendlyName tracked by winget. Upgrading if needed..." "INFO"
        # First try a normal upgrade
        $ok = Run-Exe -FilePath "winget" -ArgumentList @("upgrade","-e","--id",$Id,"--accept-package-agreements","--accept-source-agreements") -SuccessMessage "$FriendlyName upgraded (or already up-to-date)." -FailureMessage "Failed to upgrade $FriendlyName." -ContinueOnError
        if (-not $ok) {
            # Retry with include-unknown (for MSI installs winget doesn't map)
            Write-Log "Retrying $FriendlyName upgrade with --include-unknown..." "WARNING"
            $ok2 = Run-Exe -FilePath "winget" -ArgumentList @("upgrade","-e","--id",$Id,"--include-unknown","--accept-package-agreements","--accept-source-agreements") -SuccessMessage "$FriendlyName upgraded (include-unknown)." -FailureMessage "Failed to upgrade $FriendlyName (include-unknown)." -ContinueOnError
            if (-not $ok2) {
                # Final fallback: install (winget may treat this as "install or upgrade")
                Write-Log "Falling back to install for $FriendlyName..." "WARNING"
                $ok3 = Run-Exe -FilePath "winget" -ArgumentList @("install","-e","--id",$Id,"--accept-package-agreements","--accept-source-agreements") -SuccessMessage "$FriendlyName installed via fallback." -FailureMessage "Failed to install $FriendlyName (fallback)."
                return $ok3
            }
        }
        return $true
    }
}

function Refresh-NodePath {
    $nodeLocations = @(
        "$env:ProgramFiles\nodejs\node.exe",
        "$env:ProgramFiles(x86)\nodejs\node.exe",
        "$env:LOCALAPPDATA\Programs\nodejs\node.exe"
    )
    
    foreach ($nodeExe in $nodeLocations) {
        if (Test-Path $nodeExe) {
            $nodeDir = Split-Path -Parent $nodeExe
            Write-Log "Adding Node.js install location to PATH: $nodeDir" "DEBUG"
            $env:Path = "$nodeDir;$($env:Path)"
            break
        }
    }
}

function Refresh-PythonPath {
    $pyLocations = @(
        "$env:LocalAppData\Programs\Python\Python314\python.exe",
        "$env:ProgramFiles\Python314\python.exe",
        "$env:ProgramFiles\Python\Python314\python.exe",
        "$env:ProgramFiles(x86)\Python314\python.exe"
    )
    
    foreach ($pyExe in $pyLocations) {
        if (Test-Path $pyExe) {
            $pyDir = Split-Path -Parent $pyExe
            Write-Log "Adding Python install location to PATH: $pyDir" "DEBUG"
            $env:Path = "$pyDir;$($env:Path)"
            break
        }
    }
}

function Refresh-EnvironmentPath {
    Write-Log "Refreshing environment PATH..." "DEBUG"
    try {
        $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
        $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
        $env:Path = "$machinePath;$userPath"
        Write-Log "PATH refreshed successfully." "DEBUG"
    } catch {
        Write-Log "Failed to refresh PATH: $($_.Exception.Message)" "WARN"
    }
}

function Get-NvmPath {
    $candidates = @(
        "$env:ProgramFiles\nvm\nvm.exe",
        "$env:ProgramFiles(x86)\nvm\nvm.exe",
        "$env:LOCALAPPDATA\Programs\nvm\nvm.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    $nvm = Get-Command "nvm" -ErrorAction SilentlyContinue
    if ($nvm) { return $nvm.Source }
    return $null
}

function Ensure-Nvm {
    $nvm = Get-NvmPath
    if ($nvm) {
        Write-Log "NVM detected at: $nvm" "SUCCESS"
        return $nvm
    }

    Write-Log "NVM for Windows not found. Installing via Winget..." "INFO"
    if (-not (Run-Exe -FilePath "winget" -ArgumentList @(
        "install","-e","--id","CoreyButler.NVMforWindows",
        "--accept-package-agreements","--accept-source-agreements"
    ) -SuccessMessage "NVM for Windows installed." -FailureMessage "Failed to install NVM for Windows.")) {
        return $null
    }

    # Re-resolve after install
    $nvm = Get-NvmPath
    if ($nvm) {
        Write-Log "NVM installed and resolved at: $nvm" "SUCCESS"
    } else {
        Write-Log "NVM install completed but nvm.exe was not found on disk." "ERROR"
    }
    return $nvm
}

function Ensure-Node-WithNvm {
    param(
        [Parameter(Mandatory)][string]$TargetNodeVersion # e.g., '24.10.0'
    )

    # Install/resolve NVM first
    $nvm = Ensure-Nvm
    if (-not $nvm) {
        $script:blnSuccess = $false
        $script:strInstallReport += "NVM installation failed`n"
        return
    }

    # Ensure the NVM symlink directory exists and is on PATH (nvm 'use' points C:\Program Files\nodejs to a specific version)
    $symlink = "${env:ProgramFiles}\nodejs"
    if (-not (Test-Path $symlink)) { New-Item -ItemType Directory -Path $symlink -Force | Out-Null }
    if (-not ($env:Path -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ieq $symlink })) {
        Write-Log "Adding Node.js symlink to PATH for current session: $symlink" "DEBUG"
        $env:Path = "$symlink;$env:Path"
    }

    # If Node already meets min version, keep it
    $existing = Get-CommandVersion "node" "-v"
    if ($existing -and $existing -ge [version]'24.10.0') {
        Write-Log "Node.js is available ($existing) and meets the minimum version." "SUCCESS"
        return
    }

    # Install specific Current version (24.10.x). NVM expects full semver; try exact, then minor if needed.
    $installed = $false
    foreach ($candidate in @($TargetNodeVersion, ($TargetNodeVersion -replace '\.0$',''))) {
        Write-Log "Ensuring Node.js $candidate via NVM..." "INFO"
        # Try install (idempotent if already present)
        Run-Exe -FilePath $nvm -ArgumentList @("install", $candidate, "64") `
            -SuccessMessage "Node $candidate downloaded." `
            -FailureMessage "Failed to download Node $candidate." -ContinueOnError -AttachConsole | Out-Null

        # Select the version
        if (Run-Exe -FilePath $nvm -ArgumentList @("use", $candidate) `
            -SuccessMessage "Using Node $candidate." -FailureMessage "Failed to switch to Node $candidate." -ContinueOnError -AttachConsole) {
            $installed = $true
            break
        }
    }

    if (-not $installed) {
        Write-Log "NVM could not set Node to the required version ($TargetNodeVersion)." "ERROR"
        $script:blnSuccess = $false
        $script:strInstallReport += "Node 24.10+ not available via NVM`n"
        return
    }

    # Verify in current process
    Refresh-NodePath
    $now = Get-CommandVersion "node" "-v"
    if (-not $now -or $now -lt [version]'24.10.0') {
        Write-Log "Node.js is not available at the required version after NVM switch." "ERROR"
        $script:blnSuccess = $false
        $script:strInstallReport += "Node 24.10+ unavailable in current session`n"
    } else {
        Write-Log "Node.js is available ($now)." "SUCCESS"
    }
}

function Resolve-Python314 {
    Write-Log "Resolving Python 3.14 executable..." "DEBUG"
    
    # Method 1: Use py launcher (most reliable)
    try {
        $pyLauncher = Get-Command "py" -ErrorAction SilentlyContinue
        if ($pyLauncher) {
            $pythonExe = & py -3.14 -c "import sys; print(sys.executable)" 2>$null
            if ($LASTEXITCODE -eq 0 -and $pythonExe -and (Test-Path $pythonExe.Trim())) {
                Write-Log "Resolved Python 3.14 via py launcher: $pythonExe" "DEBUG"
                return $pythonExe.Trim()
            }
        }
    } catch {
        Write-Log "py launcher method failed: $($_.Exception.Message)" "DEBUG"
    }
    
    # Method 2: Check common installation paths
    $candidates = @(
        "$env:LocalAppData\Programs\Python\Python314\python.exe",
        "$env:ProgramFiles\Python314\python.exe",
        "$env:ProgramFiles\Python\Python314\python.exe",
        "$env:ProgramFiles(x86)\Python314\python.exe"
    )
    
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            Write-Log "Resolved Python 3.14 at: $candidate" "DEBUG"
            return $candidate
        }
    }
    
    # Method 3: Search PATH after refresh
    Refresh-EnvironmentPath
    $pythonCmd = Get-Command "python" -ErrorAction SilentlyContinue
    if ($pythonCmd) {
        $version = Get-CommandVersion "python" "--version"
        if ($version -and $version -ge $MinPythonVersion) {
            Write-Log "Resolved Python $version from PATH: $($pythonCmd.Source)" "DEBUG"
            return $pythonCmd.Source
        }
    }
    
    Write-Log "Failed to resolve Python 3.14 executable." "ERROR"
    return $null
}

# --- Prerequisite Installation Functions ---

function Install-NodeJS {
    Write-Log "Checking Node.js installation..." "INFO"
    $current = Get-CommandVersion "node" "-v"
    if ($current -and $current -ge [version]'24.10.0') {
        Write-Log "Node.js is available ($current)." "SUCCESS"
        return
    }

    # Node 24.10+ is a Current line, not LTS. Use NVM for a precise version.
    Ensure-Node-WithNvm -TargetNodeVersion "24.10.0"
}

function Install-Python {
    Write-Log "Checking Python 3.14 installation..." "INFO"
    $pythonVersion = Get-CommandVersion "python" "--version"

    # Ensure winget has Python 3.14 installed (side-by-side is OK)
    $ok = InstallOrUpgrade-Package -Id "Python.Python.3.14" -FriendlyName "Python 3.14"
    if (-not $ok) {
        $script:blnSuccess = $false
        $script:strInstallReport += "Failed to install/upgrade Python 3.14`n"
        return
    }
    Refresh-PythonPath

    $exe314 = Resolve-Python314
    if (-not $exe314) {
        Write-Log "Python 3.14 executable not found after installation." "ERROR"
        $script:blnSuccess = $false
        $script:strInstallReport += "Python 3.14 unavailable in current session`n"
        return
    }
    Write-Log "Python 3.14 resolved at: $exe314" "SUCCESS"
}

function Install-Git {
    Write-Log "Checking Git installation..." "INFO"
    $gitVersion = Get-CommandVersion "git" "--version"
    if ($gitVersion) {
        Write-Log "Git is already installed ($gitVersion)." "SUCCESS"
    } else {
        Write-Log "Installing Git via Winget..." "INFO"
        if (-not (InstallOrUpgrade-Package -Id "Git.Git" -FriendlyName "Git")) {
            $script:blnSuccess = $false
            $script:strInstallReport += "Failed to install Git`n"
        }
    }
}

# --- Network and Other Checks ---

function Test-Network {
    Write-Log "Checking network connectivity..." "INFO"
    try {
        $resp = Invoke-WebRequest -UseBasicParsing -Method Head "https://github.com" -TimeoutSec 10
        if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 500) {
            Write-Log "Network connectivity confirmed." "SUCCESS"
            return $true
        }
        Write-Log "Network check returned HTTP $($resp.StatusCode)." "ERROR"
        return $false
    } catch {
        Write-Log "Network check failed: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Ensure-Admin {
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            Write-Log "This script requires administrator privileges for installing software." "ERROR"
            Write-Log "Please right-click this script and select 'Run as administrator.'" "INFO"
            return $false
        }
        Write-Log "Running with administrator privileges." "SUCCESS"
        return $true
    } catch {
        Write-Log "Failed to check administrator privileges: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# --- Repository and Environment Setup ---

function Setup-Repository {
    Write-Log "Setting up repository at $ProjectRoot..." "INFO"
    
    # Create parent directory if it doesn't exist
    $parent = Split-Path -Parent $ProjectRoot
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    
    if (Test-Path (Join-Path $ProjectRoot ".git")) {
        Write-Log "Existing repository found. Updating..." "INFO"
        if (-not (Run-Exe -FilePath "git" -ArgumentList @("-C",$ProjectRoot,"pull") -SuccessMessage "Repository updated successfully." -FailureMessage "Failed to pull updates." -ContinueOnError)) {
            $script:blnSuccess = $false
            $script:strInstallReport += "Failed to pull updates`n"
        }
    } elseif (Test-Path $ProjectRoot) {
        Write-Log "Project directory '$ProjectRoot' already exists and is not a git repository." "ERROR"
        $script:blnSuccess = $false
        $script:strInstallReport += "Failed to clone repository - directory exists without .git`n"
    } else {
        Write-Log "No existing repository found. Cloning a fresh copy..." "INFO"
        if (-not (Run-Exe -FilePath "git" -ArgumentList @("clone",$RepoUrl,$ProjectRoot) -SuccessMessage "Repository cloned to $ProjectRoot" -FailureMessage "Failed to clone repository.")) {
            $script:blnSuccess = $false
            $script:strInstallReport += "Failed to clone repository`n"
        }
    }
}

function Setup-Backend {
    Write-Log "Setting up backend environment..." "INFO"
    $backendPath = Join-Path $ProjectRoot "backend"
    
    if (-not (Test-Path $backendPath)) {
        Write-Log "Backend directory not found at '$backendPath'." "ERROR"
        $script:blnSuccess = $false
        $script:strInstallReport += "Backend directory not found`n"
        return
    }
    
    Write-Log "Changing directory to '$backendPath'." "DEBUG"
    Push-Location $backendPath
    
    # Resolve Python 3.14 path (installed by Install-Python)
    $exe314 = Resolve-Python314
    if (-not $exe314) {
        Write-Log "Python 3.14 could not be resolved. Backend setup aborted." "ERROR"
        $script:blnSuccess = $false
        $script:strInstallReport += "Python 3.14 resolver failed`n"
        Pop-Location
        return
    }

    # Create venv with Python 3.14
    if (-not (Test-Path ".venv")) {
        Write-Log "Creating Python 3.14 virtual environment..." "INFO"
        if (-not (Run-Exe -FilePath $exe314 -ArgumentList @("-m", "venv", ".venv") -SuccessMessage "Virtual environment created." -FailureMessage "Failed to create virtual environment.")) {
            Pop-Location
            return
        }
    } else {
        Write-Log "Virtual environment already exists." "SUCCESS"
    }

    # Use venv's python -m pip (most robust)
    $venvPy = Join-Path (Resolve-Path ".\.venv\Scripts").Path "python.exe"
    if (-not (Test-Path $venvPy)) {
        Write-Log "venv python.exe not found." "ERROR"
        $script:blnSuccess = $false
        $script:strInstallReport += "Failed to activate virtual environment`n"
        Pop-Location
        return
    }

    # Upgrade pip
    Run-Exe -FilePath $venvPy -ArgumentList @("-m", "pip", "install", "--upgrade", "pip") -SuccessMessage "Pip upgraded." -FailureMessage "Failed to upgrade pip." -ContinueOnError

    # Install requirements
    if (Test-Path "requirements.txt") {
        if (-not (Run-Exe -FilePath $venvPy -ArgumentList @("-m", "pip", "install", "-r", "requirements.txt") -SuccessMessage "Python dependencies installed." -FailureMessage "Failed to install Python dependencies.")) {
            Pop-Location
            return
        }
    } else {
        Write-Log "requirements.txt not found in backend directory." "WARNING"
    }

    # Camoufox fetch (if present)
    $camouPath = Join-Path (Split-Path $venvPy -Parent) "camoufox.exe"
    if (-not (Test-Path $camouPath)) { $camouPath = Join-Path (Split-Path $venvPy -Parent) "camoufox" }
    if (Test-Path $camouPath) {
        Run-Exe -FilePath $camouPath -ArgumentList @("fetch") -SuccessMessage "Camoufox payload downloaded." -FailureMessage "Failed to download Camoufox payload." -ContinueOnError
    } else {
        Write-Log "Camoufox tool not found in the virtual environment. Skipping payload download." "WARNING"
    }
    
    Pop-Location
    Write-Log "Backend setup completed." "SUCCESS"
}

function Setup-Frontend {
    Write-Log "Setting up frontend dependencies..." "INFO"
    $frontendPath = Join-Path $ProjectRoot "frontend"
    
    if (-not (Test-Path $frontendPath)) {
        Write-Log "Frontend directory not found at '$frontendPath'." "ERROR"
        $script:blnSuccess = $false
        $script:strInstallReport += "Frontend directory not found`n"
        return
    }
    
    Write-Log "Changing directory to '$frontendPath'." "DEBUG"
    Push-Location $frontendPath
    
    # Check npm availability
    if (-not (Get-Command "npm" -ErrorAction SilentlyContinue)) {
        Write-Log "npm not found on PATH. Please restart your terminal." "ERROR"
        $script:blnSuccess = $false
        $script:strInstallReport += "npm unavailable in current session`n"
        Pop-Location
        return
    }
    
    # Configure npm
    Run-Exe -FilePath "npm" -ArgumentList @("config","set","fund","false") -SuccessMessage "npm configured." -FailureMessage "Failed to configure npm." -ContinueOnError
    
    # Install dependencies (use ci if lockfile exists)
    if (Test-Path "package-lock.json") {
        if (-not (Run-Exe -FilePath "npm" -ArgumentList @("ci") -SuccessMessage "Node.js dependencies installed (ci)." -FailureMessage "Failed to install Node.js dependencies.")) {
            Pop-Location
            return
        }
    } else {
        if (-not (Run-Exe -FilePath "npm" -ArgumentList @("install") -SuccessMessage "Node.js dependencies installed." -FailureMessage "Failed to install Node.js dependencies.")) {
            Pop-Location
            return
        }
    }
    
    Pop-Location
    Write-Log "Frontend setup completed." "SUCCESS"
}

function Setup-EnvironmentFiles {
    Write-Log "Setting up environment files..." "INFO"
    
    if (-not (Test-Path $ProjectRoot)) {
        Write-Log "Project root directory '$ProjectRoot' not found." "ERROR"
        $script:blnSuccess = $false
        $script:strInstallReport += "Project root directory not found for environment files`n"
        return
    }
    
    # Root .env
    $rootEnvPath = Join-Path $ProjectRoot ".env"
    if (-not (Test-Path $rootEnvPath)) {
        Write-Log "Creating root .env file at '$rootEnvPath'..." "INFO"
        @"
TAG=latest
CAMOUFOX_SOURCE=auto
"@ | Out-File -FilePath $rootEnvPath -Encoding ascii
        Write-Log "Root .env file created." "SUCCESS"
    } else {
        Write-Log "Root .env file already exists at '$rootEnvPath'. Skipping creation." "INFO"
    }
    
    # Backend .env
    $backendEnvPath = Join-Path $ProjectRoot "backend\.env"
    $backendEnvExample = Join-Path $ProjectRoot "backend\.env.example"
    if (-not (Test-Path $backendEnvPath)) {
        Write-Log "Creating backend .env file at '$backendEnvPath'..." "INFO"
        if (Test-Path $backendEnvExample) {
            Copy-Item $backendEnvExample $backendEnvPath
            Write-Log "Backend .env file created from example." "SUCCESS"
        } else {
            @"
SUPABASE_URL=your-supabase-url
SUPABASE_KEY=your-supabase-key
VITE_SUPABASE_URL=https://your-project.supabase.co
VITE_SUPABASE_KEY=your-vite-supabase-key
USER=your-database-user
PASSWORD=your-database-password
HOST=your-database-host
PORT=5432
DBNAME=postgres
GOOGLE_AI_API_KEY=your-google-ai-api-key
"@ | Out-File -FilePath $backendEnvPath -Encoding ascii
            Write-Log "Backend .env file created with defaults." "SUCCESS"
        }
    } else {
        Write-Log "Backend .env file already exists at '$backendEnvPath'. Skipping creation." "INFO"
    }
    
    # Frontend .env
    $frontendEnvPath = Join-Path $ProjectRoot "frontend\.env"
    $frontendEnvExample = Join-Path $ProjectRoot "frontend\.env.example"
    if (-not (Test-Path $frontendEnvPath)) {
        Write-Log "Creating frontend .env file at '$frontendEnvPath'..." "INFO"
        if (Test-Path $frontendEnvExample) {
            Copy-Item $frontendEnvExample $frontendEnvPath
            Write-Log "Frontend .env file created from example." "SUCCESS"
        } else {
            @"
VITE_SUPABASE_URL=your_supabase_url_here
VITE_SUPABASE_KEY=your_supabase_key_here
VITE_API_URL=http://localhost:8000
NODE_ENV=production
"@ | Out-File -FilePath $frontendEnvPath -Encoding ascii
            Write-Log "Frontend .env file created with defaults." "SUCCESS"
        }
    } else {
        Write-Log "Frontend .env file already exists at '$frontendEnvPath'. Skipping creation." "INFO"
    }
    
    Write-Log "Environment files have been created with default values." "INFO"
    Write-Log "IMPORTANT: Please edit the .env files to add your actual credentials and API keys." "IMPORTANT"
}

function Display-FinalStatus {
    Write-Host "`n========================================"
    if ($script:blnSuccess) {
        Write-Host " Setup Complete" -ForegroundColor Green
        Write-Host "========================================"
        Write-Log -Level SUCCESS -Message "All components have been installed and configured successfully!"
        Write-Host "`nYour Suno Automation environment is ready to use."
        Write-Host "`nNext steps:"
        Write-Host "1. Edit the .env files to add your credentials:"
        Write-Host "   - backend\.env: Add your Supabase and Google AI API keys"
        Write-Host "   - frontend\.env: Add your Supabase URL and keys"
        Write-Host "2. Run 'scripts\windows\start.bat' to launch the application"
        Write-Host "3. Run 'scripts\windows\stop.bat' to stop the application"
        Write-Host ""
        
        if (-not $NonInteractive) {
            $startScript = Join-Path $ProjectRoot "scripts\windows\start.bat"
            if (-not (Test-Path $startScript)) {
                $startScript = Join-Path $ScriptRoot "start.bat"
            }
            $response = Read-Host "Would you like to start the application now? (y/n)"
            if ($response -match '^(Y|y)') {
                Write-Log "Starting application..." "INFO"
                if (Test-Path $startScript) {
                    Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$startScript`""
                } else {
                    Write-Log "start.bat not found at '$startScript'. Please run it manually when ready." "WARNING"
                }
            }
        }
    } else {
        Write-Host " Setup Failed" -ForegroundColor Red
        Write-Host "========================================"
        Write-Log -Level ERROR -Message "Setup failed."
        Write-Host "`nThe following critical issue was reported:"
        Write-Host "- $script:strInstallReport" -ForegroundColor Yellow
    }
    Write-Host "`nPlease check the log file for a complete execution trace:`n$LogFile"
    Write-Host "You can also check the Windows Event Viewer for '$EventSource' events."
}

# --- Main Execution Flow ---

# Initialize global variables for status tracking
$script:blnSuccess = $true
$script:strInstallReport = ""

Write-Log -Level INFO -Message "========================================"
Write-Log -Level INFO -Message "Suno Automation - Windows Setup Script"
Write-Log -Level INFO -Message "========================================"

# Display header
Write-Host ""
Write-Host "========================================"
Write-Host " Suno Automation - Windows Setup Script"
Write-Host "========================================"
Write-Host ""
Write-Host "This script will install Git, Node.js, and Python 3.14,"
Write-Host "then set up Suno Automation project environment."
Write-Host ""

# 1. Prerequisite System Checks
Write-Log -Level INFO -Message "--- Stage 1: System Prerequisite Checks ---"
if (-not (Ensure-Admin)) {
    if (-not $NonInteractive) {
        Write-Host "Press Enter to exit..."
        Read-Host
    }
    exit 1
}
if (-not (Test-Network)) {
    if (-not $NonInteractive) {
        Write-Host "Press Enter to exit..."
        Read-Host
    }
    exit 1
}
if (-not (Get-Command "winget" -ErrorAction SilentlyContinue)) {
    Write-Log -Level ERROR -Message "Windows Package Manager (winget) not found. Aborting."
    if (-not $NonInteractive) {
        Write-Host "Press Enter to exit..."
        Read-Host
    }
    exit 1
}
Write-Log -Level SUCCESS -Message "Winget is available."

# 2. Toolchain Installation
Write-Log -Level INFO -Message "--- Stage 2: Installing Developer Toolchain ---"
Install-Git
Install-NodeJS
Install-Python

# 3. Repository Setup
Write-Log -Level INFO -Message "--- Stage 3: Setting up Project Repository ---"
Setup-Repository

# 4. Backend, Frontend, and Environment Setup (only if repo setup succeeded)
if ($script:blnSuccess -and (Test-Path $ProjectRoot)) {
    Write-Log -Level INFO -Message "--- Stage 4: Configuring Backend Environment ---"
    Setup-Backend
    
    Write-Log -Level INFO -Message "--- Stage 5: Configuring Frontend Environment ---"
    Setup-Frontend
    
    Write-Log -Level INFO -Message "--- Stage 6: Setting up Environment Files ---"
    Setup-EnvironmentFiles
}

# 7. Finalization
Display-FinalStatus

if (-not $NonInteractive) {
    Write-Host "`nPress any key to exit..."
    $null = [System.Console]::ReadKey($true)
}

exit $(if ($script:blnSuccess) { 0 } else { 1 })