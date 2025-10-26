<#
System: Suno Automation
Module: Windows Setup Automation
File URL: scripts/windows/setup-windows.ps1
Purpose: One-click Windows bootstrap script that provisions all project prerequisites
.SYNOPSIS
    Portable PowerShell script to set up Suno Automation development environment
.DESCRIPTION
    This script installs Git, Node.js (>=24.10), and Python 3.14 if needed,
    then sets up the Suno Automation project with proper logging and error handling.
    Uses $PSScriptRoot for portability and supports -NoPrompt for CI/CD.
.PARAMETER NoPrompt
    Skip interactive prompts for automated/CI execution
.EXAMPLE
    .\setup-windows.ps1
.EXAMPLE
    .\setup-windows.ps1 -NoPrompt
#>

[CmdletBinding()]
param(
    [switch]$NoPrompt
)

# Error handling preference
$ErrorActionPreference = 'Stop'

# Initialize global variables
$script:blnSuccess = $true
$script:blnNeedsInstall = $false
$script:strInstallReport = ""

# Core configuration
$script:RepoUrl = "https://github.com/vnmw7/suno-automation.git"
$script:RepoName = "suno-automation"
$script:MinNodeVersion = [version]'24.10.0'
$script:MinPythonVersion = [version]'3.14.0'

# Path resolution with fallback
$script:scriptRoot = $PSScriptRoot
if (-not $script:scriptRoot) { 
    $script:scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path 
}
$script:ProjectRoot = Join-Path $script:scriptRoot $script:RepoName

# Logging setup
$script:logDir = Join-Path $script:scriptRoot "logs"
if (-not (Test-Path $script:logDir)) { 
    New-Item -ItemType Directory -Path $script:logDir -Force | Out-Null 
}
$script:timeStamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
$script:logFile = Join-Path $script:logDir "setup-windows-$($script:timeStamp).log"
$script:eventSource = "Suno Automation Setup"

# Write-Log function - centralized logging
function Write-Log {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        
        [Parameter(Mandatory=$true)]
        [ValidateSet("INFO", "WARNING", "ERROR", "SUCCESS", "DEBUG", "IMPORTANT")]
        [string]$Level
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    
    # Console output with colors
    $color = switch ($Level) {
        "INFO" { "White" }
        "WARNING" { "Yellow" }
        "ERROR" { "Red" }
        "SUCCESS" { "Green" }
        "DEBUG" { "Magenta" }
        "IMPORTANT" { "Cyan" }
        default { "White" }
    }
    Write-Host "[$Level] $Message" -ForegroundColor $color
    
    # File output
    Add-Content -Path $script:logFile -Value $logEntry -Encoding UTF8
    
    # Event Viewer output with graceful degradation
    try {
        $eventType = switch ($Level) {
            "INFO" { "Information" }
            "WARNING" { "Warning" }
            "ERROR" { "Error" }
            "SUCCESS" { "Information" }
            "DEBUG" { "Information" }
            "IMPORTANT" { "Information" }
            default { "Information" }
        }
        
        # Try PowerShell cmdlet first
        if (-not [System.Diagnostics.EventLog]::SourceExists($script:eventSource)) {
            New-EventLog -LogName Application -Source $script:eventSource -ErrorAction SilentlyContinue
        }
        
        if ([System.Diagnostics.EventLog]::SourceExists($script:eventSource)) {
            Write-EventLog -LogName Application -Source $script:eventSource -EventId 1 -EntryType $eventType -Message $Message -ErrorAction SilentlyContinue
        } else {
            # Fallback to eventcreate
            & eventcreate /ID 1 /L Application /T $eventType /SO "$script:eventSource" /D "$Message" 2>$null
        }
    } catch {
        # Silently continue if Event Viewer logging fails
    }
}

# Execute-Command function - unified command execution
function Execute-Command {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Command,
        
        [Parameter(Mandatory=$true)]
        [string]$SuccessMessage,
        
        [Parameter(Mandatory=$true)]
        [string]$FailureMessage,
        
        [switch]$ContinueOnError
    )
    
    Write-Log "Executing: $Command" "DEBUG"
    try {
        $output = Invoke-Expression $Command 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Log $SuccessMessage "SUCCESS"
            return $true
        } else {
            Write-Log "$FailureMessage (Exit Code: $LASTEXITCODE)" "ERROR"
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

# Get-CommandVersion function - robust version parsing
function Get-CommandVersion {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Command,
        
        [Parameter(Mandatory=$true)]
        [string]$VersionArgument
    )
    
    try {
        $output = & $Command $VersionArgument 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            return $null
        }
        
        # Extract version using regex
        if ($output -match '(\d+\.\d+\.\d+)') {
            return [version]$matches[1]
        } elseif ($output -match 'v(\d+\.\d+\.\d+)') {
            return [version]$matches[1]
        } elseif ($output -match '(\d+\.\d+)') {
            return [version]$matches[1]
        } else {
            return $null
        }
    } catch {
        return $null
    }
}

# Ensure-Admin function - check admin privileges
function Ensure-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "This script requires administrator privileges for installing software." "ERROR"
        Write-Log "Please right-click this script and select 'Run as administrator.'" "INFO"
        if (-not $NoPrompt) {
            Write-Host "Press Enter to exit..."
            Read-Host
        }
        exit 1
    }
}

# Test-Network function - check connectivity
function Test-Network {
    Write-Log "Checking network connectivity..." "INFO"
    try {
        $result = Test-Connection -ComputerName "google.com" -Count 1 -Quiet
        if ($result) {
            Write-Log "Network connectivity confirmed." "SUCCESS"
            return $true
        } else {
            Write-Log "No internet connection detected. Please check your network and try again." "ERROR"
            return $false
        }
    } catch {
        Write-Log "Network check failed: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# Test-Winget function - check winget availability
function Test-Winget {
    Write-Log "Checking for Winget..." "INFO"
    try {
        $null = Get-Command "winget" -ErrorAction Stop
        Write-Log "Winget is available." "SUCCESS"
        return $true
    } catch {
        Write-Log "Winget is not available on this system." "ERROR"
        Write-Log "Please install Windows Package Manager or update your Windows 10/11 installation." "INFO"
        return $false
    }
}

# Refresh-NodePath function - update PATH for Node.js
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

# Refresh-PythonPath function - update PATH for Python
function Refresh-PythonPath {
    $pyLocations = @(
        "$env:LocalAppData\Programs\Python\Python314\python.exe",
        "$env:ProgramFiles\Python314\python.exe",
        "$env:ProgramFiles\Python\Python314\python.exe"
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

# Main execution starts here
Write-Log "Suno Automation - Windows Setup Script started." "INFO"
Write-Log "Log file: $script:logFile" "INFO"
Write-Log "Script root: $script:scriptRoot" "DEBUG"
Write-Log "Project root: $script:ProjectRoot" "DEBUG"

# Display header
Write-Host ""
Write-Host "========================================"
Write-Host " Suno Automation - Windows Setup Script"
Write-Host "========================================"
Write-Host ""
Write-Host "This script will install Git, Node.js, and Python 3.14,"
Write-Host "then set up Suno Automation project environment."
Write-Host ""

# Prerequisite checks
if (-not (Ensure-Admin)) { exit 1 }
if (-not (Test-Network)) { 
    if (-not $NoPrompt) {
        Write-Host "Press Enter to exit..."
        Read-Host
    }
    exit 1 
}
if (-not (Test-Winget)) { 
    if (-not $NoPrompt) {
        Write-Host "Press Enter to exit..."
        Read-Host
    }
    exit 1 
}

# Continue with tool installation and setup...
Write-Log "Prerequisites validated. Proceeding with setup..." "SUCCESS"

# --- Tool Installation Functions ---

function Install-Git {
    Write-Log "Checking Git installation..." "INFO"
    $gitVersion = Get-CommandVersion "git" "--version"
    
    if (-not $gitVersion) {
        Write-Log "Installing Git via Winget..." "INFO"
        if (Execute-Command "winget install --exact --accept-package-agreements --accept-source-agreements Git.Git" `
                     "Git installed successfully." "Failed to install Git.") {
            $script:blnNeedsInstall = $true
        }
    } else {
        Write-Log "Git is already installed ($gitVersion)." "SUCCESS"
    }
}

function Install-NodeJS {
    Write-Log "Checking Node.js installation..." "INFO"
    $nodeVersion = Get-CommandVersion "node" "-v"
    
    if (-not $nodeVersion) {
        Write-Log "Node.js not found. Installing Node.js LTS via Winget..." "INFO"
        if (Execute-Command "winget install --exact --accept-package-agreements --accept-source-agreements OpenJS.NodeJS.LTS" `
                     "Node.js installed successfully." "Failed to install Node.js.") {
            $script:blnNeedsInstall = $true
            Refresh-NodePath
        }
    } elseif ($nodeVersion -lt $script:MinNodeVersion) {
        Write-Log "Node.js version $nodeVersion does not meet the required $script:MinNodeVersion. Upgrading..." "INFO"
        if (Execute-Command "winget upgrade --exact --accept-package-agreements --accept-source-agreements OpenJS.NodeJS.LTS" `
                     "Node.js upgraded to latest LTS." "Failed to upgrade Node.js.") {
            $script:blnNeedsInstall = $true
            Refresh-NodePath
        }
    } else {
        Write-Log "Node.js is available ($nodeVersion)." "SUCCESS"
    }
    
    # Verify Node.js availability
    $nodeVersion = Get-CommandVersion "node" "-v"
    if (-not $nodeVersion) {
        Write-Log "Node.js is not available in this session after installation." "ERROR"
        $script:blnSuccess = $false
        $script:strInstallReport += "Node.js unavailable in current session`n"
    }
}

function Install-Python {
    Write-Log "Checking Python 3.14 installation..." "INFO"
    $pythonVersion = Get-CommandVersion "python" "--version"
    
    if (-not $pythonVersion) {
        Write-Log "Python 3.14 not found. Installing via Winget..." "INFO"
        if (Execute-Command "winget install --exact --accept-package-agreements --accept-source-agreements Python.Python.3.14" `
                     "Python 3.14 installed successfully." "Failed to install Python 3.14.") {
            $script:blnNeedsInstall = $true
            Refresh-PythonPath
        }
    } elseif ($pythonVersion -lt $script:MinPythonVersion) {
        Write-Log "Python version $pythonVersion does not meet the required $script:MinPythonVersion. Upgrading..." "INFO"
        if (Execute-Command "winget upgrade --exact --accept-package-agreements --accept-source-agreements Python.Python.3.14" `
                     "Python upgraded to 3.14." "Failed to upgrade Python.") {
            $script:blnNeedsInstall = $true
            Refresh-PythonPath
        }
    } else {
        Write-Log "Python is available ($pythonVersion)." "SUCCESS"
    }
    
    # Verify Python availability
    $pythonVersion = Get-CommandVersion "python" "--version"
    if (-not $pythonVersion) {
        Write-Log "Python is not available in this session after installation." "ERROR"
        $script:blnSuccess = $false
        $script:strInstallReport += "Python unavailable in current session`n"
    }
}

# --- Repository Management ---

function Setup-Repository {
    Write-Log "Setting up repository at $script:ProjectRoot..." "INFO"
    
    if (Test-Path "$script:ProjectRoot\.git") {
        Write-Log "Existing repository found. Updating..." "INFO"
        Push-Location $script:ProjectRoot
        $result = Execute-Command "git pull" "Repository updated successfully." "Failed to pull updates." -ContinueOnError
        Pop-Location
    } elseif (Test-Path $script:ProjectRoot) {
        Write-Log "Project directory '$script:ProjectRoot' already exists and is not a git repository." "ERROR"
        $script:blnSuccess = $false
        $script:strInstallReport += "Failed to clone repository - directory exists without .git`n"
    } else {
        Write-Log "No existing repository found. Cloning a fresh copy..." "INFO"
        if (Execute-Command "git clone `"$script:RepoUrl`" `"$script:ProjectRoot`"" `
                     "Repository cloned to $script:ProjectRoot" "Failed to clone repository.") {
            Write-Log "Repository cloned successfully." "SUCCESS"
        }
    }
}

# Execute tool installations
Write-Log "--- Stage 1: Installing Prerequisites ---" "INFO"
Install-Git
Install-NodeJS
Install-Python

# Setup repository
Write-Log "--- Stage 2: Repository Setup ---" "INFO"
Setup-Repository

# --- Backend and Frontend Setup ---

function Setup-Backend {
    Write-Log "Setting up backend environment..." "INFO"
    $backendPath = Join-Path $script:ProjectRoot "backend"
    
    if (-not (Test-Path $backendPath)) {
        Write-Log "Backend directory not found at '$backendPath'." "ERROR"
        $script:blnSuccess = $false
        $script:strInstallReport += "Backend directory not found`n"
        return
    }
    
    Push-Location $backendPath
    
    # Create virtual environment if not exists
    if (-not (Test-Path ".venv")) {
        Write-Log "Creating Python virtual environment..." "INFO"
        if (-not (Execute-Command "python -m venv .venv" "Virtual environment created." "Failed to create virtual environment.") {
            Pop-Location
            return
        }
    } else {
        Write-Log "Virtual environment already exists." "SUCCESS"
    }
    
    # Use venv pip directly (no activation needed)
    $pipPath = ".venv\Scripts\pip.exe"
    if (-not (Test-Path $pipPath)) {
        Write-Log "Failed to find pip in virtual environment." "ERROR"
        $script:blnSuccess = $false
        $script:strInstallReport += "Failed to activate virtual environment`n"
        Pop-Location
        return
    }
    
    # Upgrade pip
    Execute-Command "$pipPath install --upgrade pip" "Pip upgraded." "Failed to upgrade pip." -ContinueOnError
    
    # Install Python requirements
    if (Test-Path "requirements.txt") {
        if (-not (Execute-Command "$pipPath install -r requirements.txt" "Python dependencies installed." "Failed to install Python dependencies.")) {
            Pop-Location
            return
        }
    } else {
        Write-Log "requirements.txt not found in backend directory." "WARNING"
    }
    
    # Download Camoufox payload
    Write-Log "Downloading Camoufox browser payload..." "INFO"
    $camoufoxCmd = ".venv\Scripts\camoufox.exe"
    if (-not (Test-Path $camoufoxCmd)) { $camoufoxCmd = ".venv\Scripts\camoufox" }
    if (Test-Path $camoufoxCmd) {
        Execute-Command "$camoufoxCmd fetch" "Camoufox payload downloaded." "Failed to download Camoufox payload." -ContinueOnError
    } else {
        Write-Log "Camoufox tool not found in the virtual environment. Skipping payload download." "WARNING"
    }
    
    Pop-Location
    Write-Log "Backend setup completed." "SUCCESS"
}

function Setup-Frontend {
    Write-Log "Setting up frontend dependencies..." "INFO"
    $frontendPath = Join-Path $script:ProjectRoot "frontend"
    
    if (-not (Test-Path $frontendPath)) {
        Write-Log "Frontend directory not found at '$frontendPath'." "ERROR"
        $script:blnSuccess = $false
        $script:strInstallReport += "Frontend directory not found`n"
        return
    }
    
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
    Execute-Command "npm config set fund false" "npm configured." "Failed to configure npm." -ContinueOnError
    
    # Install dependencies (use ci if lockfile exists)
    if (Test-Path "package-lock.json") {
        if (-not (Execute-Command "npm ci" "Node.js dependencies installed (ci)." "Failed to install Node.js dependencies.")) {
            Pop-Location
            return
        }
    } else {
        if (-not (Execute-Command "npm install" "Node.js dependencies installed." "Failed to install Node.js dependencies.")) {
            Pop-Location
            return
        }
    }
    
    Pop-Location
    Write-Log "Frontend setup completed." "SUCCESS"
}

function Setup-EnvironmentFiles {
    Write-Log "Setting up environment files..." "INFO"
    
    if (-not (Test-Path $script:ProjectRoot)) {
        Write-Log "Project root directory '$script:ProjectRoot' not found." "ERROR"
        $script:blnSuccess = $false
        $script:strInstallReport += "Project root directory not found for environment files`n"
        return
    }
    
    # Root .env
    $rootEnvPath = Join-Path $script:ProjectRoot ".env"
    if (-not (Test-Path $rootEnvPath)) {
        Write-Log "Creating root .env file..." "INFO"
        @"
TAG=latest
CAMOUFOX_SOURCE=auto
"@ | Out-File -FilePath $rootEnvPath -Encoding ascii
        Write-Log "Root .env file created." "SUCCESS"
    }
    
    # Backend .env
    $backendEnvPath = Join-Path $script:ProjectRoot "backend\.env"
    $backendEnvExample = Join-Path $script:ProjectRoot "backend\.env.example"
    if (-not (Test-Path $backendEnvPath)) {
        Write-Log "Creating backend .env file..." "INFO"
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
    }
    
    # Frontend .env
    $frontendEnvPath = Join-Path $script:ProjectRoot "frontend\.env"
    $frontendEnvExample = Join-Path $script:ProjectRoot "frontend\.env.example"
    if (-not (Test-Path $frontendEnvPath)) {
        Write-Log "Creating frontend .env file..." "INFO"
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
    }
    
    Write-Log "Environment files have been created with default values." "INFO"
    Write-Log "IMPORTANT: Please edit the .env files to add your actual credentials and API keys." "IMPORTANT"
}

function Display-FinalStatus {
    Write-Host ""
    Write-Host "========================================"
    if ($script:blnSuccess) {
        Write-Host " Setup Complete"
        Write-Host "========================================"
        Write-Host ""
        Write-Log "All components have been installed and configured successfully!" "SUCCESS"
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
            $startScript = Join-Path $script:ProjectRoot "scripts\windows\start.bat"
            if (-not (Test-Path $startScript)) {
                $startScript = Join-Path $script:scriptRoot "start.bat"
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
        Write-Host " Setup Failed"
        Write-Host "========================================"
        Write-Host ""
        Write-Log "Setup failed. See details below." "ERROR"
        Write-Host "The following issues were reported:"
        if ([string]::IsNullOrEmpty($script:strInstallReport)) {
            Write-Host "- An unexpected error occurred."
        } else {
            $script:strInstallReport.Trim() -split "`n" | ForEach-Object { if ($_) { Write-Host $_ } }
        }
        Write-Host ""
        Write-Host "Please check the log file for a complete execution trace:"
        Write-Host $script:logFile
    }
    
    Write-Log "Setup script completed. Log file saved to: $script:logFile" "INFO"
    Write-Host ""
    Write-Host "Log file saved to: $script:logFile"
    Write-Host "You can also check the Windows Event Viewer for '$script:eventSource' events."
    Write-Host ""
    
    if (-not $NoPrompt) {
        Write-Host "Press any key to exit..."
        $null = [System.Console]::ReadKey($true)
    }
}

# Execute backend, frontend, and environment setup if repository exists
if ($script:blnSuccess -and (Test-Path $script:ProjectRoot)) {
    Write-Log "--- Stage 3: Backend Setup ---" "INFO"
    Setup-Backend
    
    Write-Log "--- Stage 4: Frontend Setup ---" "INFO"
    Setup-Frontend
    
    Write-Log "--- Stage 5: Environment Files ---" "INFO"
    Setup-EnvironmentFiles
}

# Display final status
Display-FinalStatus

exit $(if ($script:blnSuccess) { 0 } else { 1 })