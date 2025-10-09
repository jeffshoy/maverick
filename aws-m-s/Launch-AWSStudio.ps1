#requires -version 7.0
<#
.SYNOPSIS
    AWS Management Studio - Launcher

.DESCRIPTION
    Simple launcher wrapper for AWS Management Studio
    Automatically launches the application in STA mode from the correct location

.EXAMPLE
    .\Launch-AWSStudio.ps1
    
.NOTES
    This launcher ensures the application runs in the required STA threading mode
    and launches from the correct scripts/ directory location
#>

# Get the directory where this launcher script is located
$LauncherRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# Set working directory to launcher location for relative paths
Set-Location $LauncherRoot

# Define main script path relative to launcher
$MainScript = Join-Path $LauncherRoot "scripts\aws-management-studio.ps1"

if (-not (Test-Path $MainScript)) {
    Write-Host "" 
    Write-Host "❌ AWS Management Studio not found" -ForegroundColor Red
    Write-Host "" 
    Write-Host "This launcher needs the complete AWS Management Studio folder structure." -ForegroundColor Yellow
    Write-Host "" 
    Write-Host "Would you like me to create a desktop shortcut to the original location? (Y/N)" -ForegroundColor White
    $response = Read-Host
    
    if ($response -match '^[Yy]') {
        try {
            # Search for the original launcher across drives and common locations
            Write-Host "Searching for AWS Management Studio installation..." -ForegroundColor Gray
            
            $drives = Get-WmiObject -Class Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 } | Select-Object -ExpandProperty DeviceID
            $commonFolders = @('Temp\Repos', 'Temp', 'Projects', 'Dev', 'Source', 'Code', 'Tools')
            
            $originalLauncher = $null
            foreach ($drive in $drives) {
                foreach ($folder in $commonFolders) {
                    $testPath = "$drive\$folder\aws-management-studio\Launch-AWSStudio.cmd"
                    if (Test-Path $testPath) {
                        $originalLauncher = $testPath
                        break
                    }
                }
                if ($originalLauncher) { break }
            }
            
            if ($originalLauncher) {
                $desktop = [Environment]::GetFolderPath('Desktop')
                $shortcutPath = Join-Path $desktop "AWS Management Studio.lnk"
                
                $shell = New-Object -ComObject WScript.Shell
                $shortcut = $shell.CreateShortcut($shortcutPath)
                $shortcut.TargetPath = $originalLauncher
                $shortcut.WorkingDirectory = Split-Path $originalLauncher
                $shortcut.Description = "AWS Management Studio - SRE Tool"
                $shortcut.Save()
                
                Write-Host "✓ Desktop shortcut created successfully!" -ForegroundColor Green
            } else {
                Write-Host "Could not locate original AWS Management Studio installation." -ForegroundColor Yellow
                Write-Host "Please copy the entire 'aws-management-studio' folder to your desired location." -ForegroundColor Gray
            }
        } catch {
            Write-Host "Failed to create shortcut: $($_.Exception.Message)" -ForegroundColor Red
        }
    } else {
        Write-Host "To use AWS Management Studio:" -ForegroundColor White
        Write-Host "1. Copy the entire 'aws-management-studio' folder to your desired location" -ForegroundColor Gray
        Write-Host "2. Run the launcher from inside that folder" -ForegroundColor Gray
    }
    Write-Host "" 
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host "Launching AWS Management Studio..." -ForegroundColor Green
Write-Host "Working directory: $(Get-Location)" -ForegroundColor Gray
Write-Host "Script location: $MainScript" -ForegroundColor Gray

# Check PowerShell availability and launch in STA mode
try {
    # Try PowerShell 7+ first
    if (Get-Command pwsh -ErrorAction SilentlyContinue) {
        Write-Host "Using PowerShell 7+" -ForegroundColor Gray
        & pwsh -STA -WorkingDirectory "$LauncherRoot" -File "$MainScript"
    }
    # Fallback to Windows PowerShell 5.1
    elseif (Get-Command powershell -ErrorAction SilentlyContinue) {
        Write-Host "Using Windows PowerShell 5.1 (fallback)" -ForegroundColor Yellow
        & powershell -STA -WorkingDirectory "$LauncherRoot" -File "$MainScript"
    }
    else {
        throw "No PowerShell installation found"
    }
} catch {
    Write-Error "Failed to launch application: $($_.Exception.Message)"
    Write-Host "Please ensure PowerShell 7.0+ is installed from: https://github.com/PowerShell/PowerShell/releases" -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
    exit 1
}