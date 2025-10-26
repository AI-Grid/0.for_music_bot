<#
System: Suno Automation
Module: Windows Setup Automation
File URL: scripts/windows/setup-windows.ps1
Purpose: Portable PowerShell bootstrap script that provisions all project prerequisites
#>

[CmdletBinding()]
param(
    [switch]$NoPrompt
)

# Set error action preference
$ErrorActionPreference = 'Stop'

# Initialize script paths and variables
$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrEmpty($scriptRoot)) { 
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path 
}

$repoName = "suno-automation"
$repoUrl = "https://github.com/vnmw7/suno-automation.git"
$projectRoot = Join-Path $scriptRoot $repoName

# Logging setup
$logDir = Join-Path $scriptRoot "logs"
if (-not (Test-Path $logDir)) { 
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null 
}

$timeStamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
$logFile = Join-Path $logDir "setup-windows-$timeStamp.log"
$eventSource = "Suno Automation Setup"

# Global variables for tracking
$global:blnSuccess = $true
$global:blnNeedsInstall = $false
$global:installReport = ""

# Minimum version requirements
$MIN_NODE_MAJOR = 24
$MIN_NODE_MINOR = 10
$MIN_PYTHON_MAJOR = 3
$MIN_PYTHON_MINOR = 14

# Write-Log function for dual-channel logging
function Write-Log {
    param(
        [string]$Level,
        [string]$Message
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "$timestamp [$Level] $Message"
    
    # Console output with color coding
    $color = switch ($Level.ToUpper()) {
        "INFO" { "White" }
        "SUCCESS" { "Green" }
        "WARNING" { "Yellow" }
        "ERROR" { "Red" }
        "DEBUG" { "Magenta" }
        default { "White" }
    }
    Write-Host "[$Level] $Message" -ForegroundColor $color
    
    # File output
    Add-Content -Path $logFile -Value $logEntry -Encoding UTF8
    
    # Event Viewer output (with graceful degradation)
    try {
        $eventType = switch ($Level.ToUpper()) {
            "INFO" { "Information" }
            "SUCCESS" { "Information" }
            "WARNING" { "Warning" }
            "ERROR" { "Error" }
            default { "Information" }
        }
        
        # Try to register event source if needed
        if (-not [System.Diagnostics.EventLog]::SourceExists($eventSource)) {
            try {
                New-EventLog -LogName Application -Source $eventSource -ErrorAction Stop
            } catch {
                # Fallback to eventcreate if New-EventLog fails
                & eventcreate /ID 1 /L Application /T INFORMATION /SO "$eventSource" /D "Event source registration attempted" 2>$null
            }
        }
        
        Write-EventLog -LogName Application -Source $eventSource -EntryType $eventType -EventId 1 -Message $Message -ErrorAction SilentlyContinue
    } catch {
        # Fallback to eventcreate if Write-EventLog fails
        try {
            $eventCreateType = switch ($Level.ToUpper()) {
                "ERROR" { "ERROR" }
                "WARNING" { "WARNING" }
                default { "INFORMATION" }
            }
            & eventcreate /ID 1 /L Application /T $eventCreateType /SO "$eventSource" /D "$Message" 2>$null
        } catch {
            # Silently fail if both logging methods fail
        }
    }
}

# Ensure-Admin function
function Ensure-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "ERROR" "This script requires administrator privileges to run."
        Write-Log "INFO" "Please right-click this script and select 'Run as administrator'."
        if (-not $NoPrompt) {
            Write-Host "Press Enter to exit..."
            Read-Host
        }
        exit 1
    }
}

# Test-Network function
function Test-Network {
    Write-Log "INFO" "Checking network connectivity..."
    try {
        $ping = Test-Connection -ComputerName "google.com" -Count 1 -Quiet
        if ($ping) {
            Write-Log "SUCCESS" "Network connectivity confirmed."
        } else {
            Write-Log "ERROR" "No internet connection detected. Please check your network and try again."
            if (-not $NoPrompt) {
                Write-Host "Press Enter to exit..."
                Read-Host
            }
            exit 1
        }
    } catch {
        Write-Log "ERROR" "Network check failed: $($_.Exception.Message)"
        if (-not $NoPrompt) {
            Write-Host "Press Enter to exit..."
            Read-Host
        }
        exit 1
    }
}

# Test-Winget function
function Test-Winget {
    Write-Log "INFO" "Checking for Winget..."
    try {
        $null = Get-Command "winget" -ErrorAction Stop
        Write-Log "SUCCESS" "Winget is available."
    } catch {
        Write-Log "ERROR" "Winget is not available on this system."
        Write-Log "INFO" "Please install Windows Package Manager or update your Windows installation."
        if (-not $NoPrompt) {
            Write-Host "Press Enter to exit..."
            Read-Host
        }
        exit 1
    }
}

# Get-CommandVersion function
function Get-CommandVersion {
    param(
        [string]$Command,
        [string]$VersionArgument
    )
    
    try {
        $output = & $Command $VersionArgument 2>&1
        if ($LASTEXITCODE -ne 0) {
            return $null
        }
        
        # Extract version using regex
        if ($output -match '(\d+)\.(\d+)\.(\d+)') {
            return [version]("$($Matches[1]).$($Matches[2]).$($Matches[3])")
        } elseif ($output -match '(\d+)\.(\d+)') {
            return [version]("$($Matches[1]).$($Matches[2]).0")
        } else {
            return $null
        }
    } catch {
        return $null
    }
}

# Install-Prerequisite function
function Install-Prerequisite {
    param(
        [string]$ToolName,
        [string]$PackageId,
        [string]$Action = "install"
    )
    
    Write-Log "INFO" "$Action $ToolName via Winget..."
    try {
        $wingetArgs = @($Action, "--exact", "--accept-package-agreements", "--accept-source-agreements", $PackageId)
        $process = Start-Process -FilePath "winget" -ArgumentList $wingetArgs -Wait -PassThru -NoNewWindow
        
        if ($process.ExitCode -eq 0) {
            Write-Log "SUCCESS" "$ToolName $action completed successfully."
            $global:blnNeedsInstall = $true
            return $true
        } else {
            Write-Log "ERROR" "Failed to $action $ToolName (Exit Code: $($process.ExitCode))."
            return $false
        }
    } catch {
        Write-Log "ERROR" "Failed to $action $ToolName: $($_.Exception.Message)"
        return $false
    }
}

# Refresh-NodePath function
function Refresh-NodePath {
    $nodeLocations = @(
        "$env:ProgramFiles\nodejs\node.exe",
        "${env:ProgramFiles(x86)}\nodejs\node.exe",
        "$env:LOCALAPPDATA\Programs\nodejs\node.exe"
    )
    
    foreach ($nodeExe in $nodeLocations) {
        if (Test-Path $nodeExe) {
            $nodeDir = Split-Path -Parent $nodeExe
            Write-Log "DEBUG" "Adding Node.js install location to PATH: $nodeDir"
            $env:Path = "$nodeDir;$($env:Path)"
            break
        }
    }
}

# Refresh-PythonPath function
function Refresh-PythonPath {
    $pythonLocations = @(
        "$env:LocalAppData\Programs\Python\Python314\python.exe",
        "$env:ProgramFiles\Python314\python.exe",
        "$env:ProgramFiles\Python\Python314\python.exe"
    )
    
    foreach ($pythonExe in $pythonLocations) {
        if (Test-Path $pythonExe) {
            $pythonDir = Split-Path -Parent $pythonExe
            Write-Log "DEBUG" "Adding Python install location to PATH: $pythonDir"
            $env:Path = "$pythonDir;$($env:Path)"
            break
        }
    }
}

# Ensure-Git function
function Ensure-Git {
    Write-Log "INFO" "Checking Git installation..."
    $gitVersion = Get-CommandVersion -Command "git" -VersionArgument "--version"
    
    if ($null -eq $gitVersion) {
        if (-not (Install-Prerequisite -ToolName "Git" -PackageId "Git.Git")) {
            $global:blnSuccess = $false
            $global:installReport += "Failed to install Git`n"
        }
    } else {
        Write-Log "SUCCESS" "Git is already installed (Version: $gitVersion)."
    }
}

# Ensure-NodeJS function
function Ensure-NodeJS {
    Write-Log "INFO" "Checking Node.js installation..."
    $nodeVersion = Get-CommandVersion -Command "node" -VersionArgument "-v"
    
    if ($null -eq $nodeVersion) {
        if (Install-Prerequisite -ToolName "Node.js" -PackageId "OpenJS.NodeJS.LTS") {
            Refresh-NodePath
            $nodeVersion = Get-CommandVersion -Command "node" -VersionArgument "-v"
        } else {
            $global:blnSuccess = $false
            $global:installReport += "Failed to install Node.js`n"
        }
    } else {
        $major = $nodeVersion.Major
        $minor = $nodeVersion.Minor
        
        if ($major -lt $MIN_NODE_MAJOR -or ($major -eq $MIN_NODE_MAJOR -and $minor -lt $MIN_NODE_MINOR)) {
            Write-Log "INFO" "Node.js version $major.$minor does not meet the required $MIN_NODE_MAJOR.$MIN_NODE_MINOR. Upgrading..."
            if (Install-Prerequisite -ToolName "Node.js" -PackageId "OpenJS.NodeJS.LTS" -Action "upgrade") {
                Refresh-NodePath
                $nodeVersion = Get-CommandVersion -Command "node" -VersionArgument "-v"
            } else {
                Write-Log "WARNING" "Node.js upgrade failed. Continuing with existing version."
            }
        } else {
            Write-Log "SUCCESS" "Node.js is available ($nodeVersion)."
        }
    }
    
    # Verify Node.js availability
    $finalVersion = Get-CommandVersion -Command "node" -VersionArgument "-v"
    if ($null -eq $finalVersion) {
        $global:blnSuccess = $false
        $global:installReport += "Node.js unavailable in current session`n"
        Write-Log "ERROR" "Node.js is not available in this session after installation. Please restart your terminal and try again."
    }
}

# Ensure-Python function
function Ensure-Python {
    Write-Log "INFO" "Checking Python 3.14 installation..."
    $pythonVersion = Get-CommandVersion -Command "python" -VersionArgument "--version"
    
    if ($null -eq $pythonVersion) {
        if (Install-Prerequisite -ToolName "Python 3.14" -PackageId "Python.Python.3.14") {
            Refresh-PythonPath
            $pythonVersion = Get-CommandVersion -Command "python" -VersionArgument "--version"
        } else {
            $global:blnSuccess = $false
            $global:installReport += "Failed to install Python 3.14`n"
        }
    } else {
        $major = $pythonVersion.Major
        $minor = $pythonVersion.Minor
        
        if ($major -lt $MIN_PYTHON_MAJOR -or ($major -eq $MIN_PYTHON_MAJOR -and $minor -lt $MIN_PYTHON_MINOR)) {
            Write-Log "INFO" "Python version $major.$minor does not meet the required $MIN_PYTHON_MAJOR.$MIN_PYTHON_MINOR. Upgrading..."
            if (Install-Prerequisite -ToolName "Python 3.14" -PackageId "Python.Python.3.14" -Action "upgrade") {
                Refresh-PythonPath
                $pythonVersion = Get-CommandVersion -Command "python" -VersionArgument "--version"
            } else {
                Write-Log "WARNING" "Python upgrade failed. Continuing with existing version."
            }
        } else {
            Write-Log "SUCCESS" "Python is available ($pythonVersion)."
        }
    }
    
    # Verify Python availability
    $finalVersion = Get-CommandVersion -Command "python" -VersionArgument "--version"
    if ($null -eq $finalVersion) {
        $global:blnSuccess = $false
        $global:installReport += "Python unavailable in current session`n"
        Write-Log "ERROR" "Python is not available in this session after installation. Please restart your terminal and try again."
    }
}

# Setup-Repository function
function Setup-Repository {
    Write-Log "INFO" "Setting up repository at $projectRoot..."
    
    if (Test-Path "$projectRoot\.git") {
        Write-Log "INFO" "Existing repository found. Updating..."
        try {
            Push-Location $projectRoot
            $null = git -C $projectRoot fetch --all --prune 2>&1
            $null = git -C $projectRoot pull --ff-only 2>&1
            Pop-Location
            
            if ($LASTEXITCODE -eq 0) {
                Write-Log "SUCCESS" "Repository updated successfully."
            } else {
                Write-Log "WARNING" "Failed to pull updates. Continuing with local version."
            }
        } catch {
            Write-Log "WARNING" "Failed to update repository: $($_.Exception.Message)"
        }
    } elseif (Test-Path $projectRoot) {
        Write-Log "ERROR" "Project directory '$projectRoot' already exists and is not a git repository."
        $global:blnSuccess = $false
        $global:installReport += "Failed to clone repository`n"
    } else {
        Write-Log "INFO" "No existing repository found. Cloning a fresh copy..."
        try {
            New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
            $null = git clone $repoUrl $projectRoot 2>&1
            
            if ($LASTEXITCODE -eq 0) {
                Write-Log "SUCCESS" "Repository cloned to $projectRoot"
            } else {
                Write-Log "ERROR" "Failed to clone repository."
                $global:blnSuccess = $false
                $global:installReport += "Failed to clone repository`n"
            }
        } catch {
            Write-Log "ERROR" "Failed to clone repository: $($_.Exception.Message)"
            $global:blnSuccess = $false
            $global:installReport += "Failed to clone repository`n"
        }
    }
}

# Setup-Backend function
function Setup-Backend {
    Write-Log "INFO" "Setting up backend environment..."
    $backendPath = Join-Path $projectRoot "backend"
    
    if (-not (Test-Path $backendPath)) {
        Write-Log "ERROR" "Backend directory not found at '$backendPath'."
        $global:blnSuccess = $false
        $global:installReport += "Backend directory not found`n"
        return
    }
    
    Push-Location $backendPath
    
    # Create virtual environment if not exists
    if (-not (Test-Path ".venv")) {
        Write-Log "INFO" "Creating Python virtual environment..."
        try {
            $null = python -m venv .venv 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Log "SUCCESS" "Virtual environment created."
            } else {
                Write-Log "ERROR" "Failed to create virtual environment."
                $global:blnSuccess = $false
                $global:installReport += "Failed to create virtual environment`n"
                Pop-Location
                return
            }
        } catch {
            Write-Log "ERROR" "Failed to create virtual environment: $($_.Exception.Message)"
            $global:blnSuccess = $false
            $global:installReport += "Failed to create virtual environment`n"
            Pop-Location
            return
        }
    } else {
        Write-Log "SUCCESS" "Virtual environment already exists."
    }
    
    # Use venv pip directly (no activation needed)
    $pipPath = ".venv\Scripts\pip.exe"
    if (-not (Test-Path $pipPath)) {
        Write-Log "ERROR" "Failed to locate pip in virtual environment."
        $global:blnSuccess = $false
        $global:installReport += "Failed to activate virtual environment`n"
        Pop-Location
        return
    }
    
    # Upgrade pip
    Write-Log "INFO" "Upgrading pip in virtual environment..."
    $null = & $pipPath install --upgrade pip 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "WARNING" "Failed to upgrade pip (non-critical). Continuing."
    } else {
        Write-Log "SUCCESS" "Pip upgraded (if not already latest)."
    }
    
    # Install Python requirements
    Write-Log "INFO" "Installing Python dependencies..."
    if (Test-Path "requirements.txt") {
        $null = & $pipPath install -r requirements.txt 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Log "SUCCESS" "Python dependencies installed."
        } else {
            Write-Log "ERROR" "Failed to install Python dependencies."
            $global:blnSuccess = $false
            $global:installReport += "Failed to install Python dependencies`n"
        }
    } else {
        Write-Log "WARNING" "requirements.txt not found in backend directory."
    }
    
    # Download Camoufox payload
    Write-Log "INFO" "Downloading Camoufox browser payload..."
    $camoufoxCmd = ".venv\Scripts\camoufox.exe"
    if (-not (Test-Path $camoufoxCmd)) { 
        $camoufoxCmd = ".venv\Scripts\camoufox" 
    }
    
    if (Test-Path $camoufoxCmd) {
        $null = & $camoufoxCmd fetch 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Log "SUCCESS" "Camoufox payload downloaded."
        } else {
            Write-Log "WARNING" "Failed to download Camoufox payload. You may need to run 'camoufox fetch' manually."
        }
    } else {
        Write-Log "WARNING" "Camoufox tool not found in the virtual environment. Skipping payload download."
    }
    
    Pop-Location
    Write-Log "SUCCESS" "Backend setup completed."
}

# Setup-Frontend function
function Setup-Frontend {
    Write-Log "INFO" "Setting up frontend dependencies..."
    $frontendPath = Join-Path $projectRoot "frontend"
    
    if (-not (Test-Path $frontendPath)) {
        Write-Log "ERROR" "Frontend directory not found at '$frontendPath'."
        $global:blnSuccess = $false
        $global:installReport += "Frontend directory not found`n"
        return
    }
    
    Push-Location $frontendPath
    
    # Ensure npm is available
    if (-not (Get-Command "npm" -ErrorAction SilentlyContinue)) {
        Write-Log "ERROR" "npm not found on PATH. Please restart your terminal or rerun this script."
        $global:blnSuccess = $false
        $global:installReport += "npm unavailable in current session`n"
        Pop-Location
        return
    }
    
    # Configure npm to reduce output
    $null = npm config set fund false 2>$null
    
    # Install dependencies
    Write-Log "INFO" "Installing Node.js dependencies..."
    if (Test-Path "package-lock.json") {
        Write-Log "INFO" "Using npm ci (lockfile detected)..."
        $null = npm ci 2>&1
    } else {
        Write-Log "INFO" "Using npm install (no lockfile)..."
        $null = npm install 2>&1
    }
    
    if ($LASTEXITCODE -eq 0) {
        Write-Log "SUCCESS" "Node.js dependencies installed."
    } else {
        Write-Log "ERROR" "Failed to install Node.js dependencies."
        $global:blnSuccess = $false
        $global:installReport += "Failed to install Node.js dependencies`n"
    }
    
    Pop-Location
    Write-Log "SUCCESS" "Frontend setup completed."
}

# Ensure-EnvFiles function
function Ensure-EnvFiles {
    Write-Log "INFO" "Setting up environment files..."
    
    if (-not (Test-Path $projectRoot)) {
        Write-Log "ERROR" "Project root directory '$projectRoot' not found. Unable to create environment files."
        $global:blnSuccess = $false
        $global:installReport += "Project root directory not found for environment files`n"
        return
    }
    
    # Root .env
    $rootEnvPath = Join-Path $projectRoot ".env"
    if (-not (Test-Path $rootEnvPath)) {
        Write-Log "INFO" "Creating root .env file..."
        @"
TAG=latest
CAMOUFOX_SOURCE=auto
"@ | Out-File -FilePath $rootEnvPath -Encoding ascii
        Write-Log "SUCCESS" "Root .env file created."
    }
    
    # Backend .env
    $backendEnvPath = Join-Path $projectRoot "backend\.env"
    $backendEnvExample = Join-Path $projectRoot "backend\.env.example"
    if (-not (Test-Path $backendEnvPath)) {
        Write-Log "INFO" "Creating backend .env file..."
        if (Test-Path $backendEnvExample) {
            Copy-Item $backendEnvExample $backendEnvPath
            Write-Log "SUCCESS" "Backend .env file created from example."
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
            Write-Log "SUCCESS" "Backend .env file created with defaults."
        }
    }
    
    # Frontend .env
    $frontendEnvPath = Join-Path $projectRoot "frontend\.env"
    $frontendEnvExample = Join-Path $projectRoot "frontend\.env.example"
    if (-not (Test-Path $frontendEnvPath)) {
        Write-Log "INFO" "Creating frontend .env file..."
        if (Test-Path $frontendEnvExample) {
            Copy-Item $frontendEnvExample $frontendEnvPath
            Write-Log "SUCCESS" "Frontend .env file created from example."
        } else {
            @"
VITE_SUPABASE_URL=your_supabase_url_here
VITE_SUPABASE_KEY=your_supabase_key_here
VITE_API_URL=http://localhost:8000
NODE_ENV=production
"@ | Out-File -FilePath $frontendEnvPath -Encoding ascii
            Write-Log "SUCCESS" "Frontend .env file created with defaults."
        }
    }
    
    Write-Log "INFO" "Environment files have been created with default values."
    Write-Log "IMPORTANT" "Please edit the .env files to add your actual credentials and API keys."
}

# Display-FinalStatus function
function Display-FinalStatus {
    Write-Host ""
    Write-Host "========================================"
    
    if ($global:blnSuccess) {
        Write-Host " Setup Complete"
        Write-Host "========================================"
        Write-Host ""
        Write-Log "SUCCESS" "All components have been installed and configured successfully!"
        Write-Host "Your Suno Automation environment is ready to use."
        Write-Host ""
        Write-Host "Next steps:"
        Write-Host "1. Edit the .env files to add your credentials:"
        Write-Host "   - backend\.env: Add your Supabase and Google AI API keys"
        Write-Host "   - frontend\.env: Add your Supabase URL and keys"
        Write-Host "2. Run 'scripts\windows\start.bat' to launch the application"
        Write-Host "3. Run 'scripts\windows\stop.bat' to stop the application"
        Write-Host ""
        
        if (-not $NoPrompt) {
            $startScript = Join-Path $projectRoot "scripts\windows\start.bat"
            if (-not (Test-Path $startScript)) {
                $startScript = Join-Path $scriptRoot "start.bat"
            }
            
            $response = Read-Host "Would you like to start the application now? (y/n)"
            if ($response -match '^(Y|y)') {
                Write-Log "INFO" "Starting application..."
                if (Test-Path $startScript) {
                    Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$startScript`""
                } else {
                    Write-Log "WARNING" "start.bat not found at '$startScript'. Please run it manually when ready."
                }
            }
        }
    } else {
        Write-Host " Setup Failed"
        Write-Host "========================================"
        Write-Host ""
        Write-Log "ERROR" "Setup failed. See details below."
        Write-Host "The following issues were reported:"
        if ([string]::IsNullOrEmpty($global:installReport)) {
            Write-Host "- An unexpected error occurred."
        } else {
            $global:installReport.Trim() -split "`n" | ForEach-Object { if ($_) { Write-Host $_ } }
        }
        Write-Host ""
        Write-Host "Please check the log file for a complete execution trace:"
        Write-Host "$logFile"
    }
    
    Write-Log "INFO" "Setup script completed. Log file saved to: $logFile"
    Write-Host ""
    Write-Host "Log file saved to: $logFile"
    Write-Host "You can also check the Windows Event Viewer for '$eventSource' events."
    Write-Host ""
    
    if (-not $NoPrompt) {
        Write-Host "Press any key to exit..."
        $null = [System.Console]::ReadKey($true)
    }
}

# Main execution
try {
    # Display header
    Write-Host ""
    Write-Host "========================================"
    Write-Host " Suno Automation - Windows Setup Script"
    Write-Host "========================================"
    Write-Host ""
    Write-Host "This script will install Git, Node.js, and Python 3.14,"
    Write-Host "then set up Suno Automation project environment."
    Write-Host ""
    
    # Initialize logging
    Write-Log "INFO" "Suno Automation - Windows Setup Script started."
    Write-Log "INFO" "Log file: $logFile"
    
    # Prerequisite checks
    Ensure-Admin
    Test-Network
    Test-Winget
    
    # Ensure core toolchain
    Ensure-Git
    Ensure-NodeJS
    Ensure-Python
    
    # Setup repository and project
    if ($global:blnSuccess) {
        Setup-Repository
        
        if ($global:blnSuccess -and (Test-Path $projectRoot)) {
            Setup-Backend
            Setup-Frontend
            Ensure-EnvFiles
        }
    }
    
    # Display final status
    Display-FinalStatus
    
} catch {
    Write-Log "ERROR" "Unexpected error occurred: $($_.Exception.Message)"
    Write-Log "ERROR" "Stack trace: $($_.ScriptStackTrace)"
    $global:blnSuccess = $false
    Display-FinalStatus
}

exit $(if ($global:blnSuccess) { 0 } else { 1 })