@echo off
REM AWS Management Studio - Windows Batch Launcher
REM Simple batch file launcher for Windows environments

echo Launching AWS Management Studio...
echo Working from directory: %~dp0

REM Change to launcher directory for relative paths
cd /d "%~dp0"

REM Check if PowerShell launcher exists
if not exist "%~dp0Launch-AWSStudio.ps1" (
    echo.
    echo ERROR: AWS Management Studio not found
    echo.
    echo This launcher needs the complete AWS Management Studio folder structure.
    echo.
    echo To use AWS Management Studio:
    echo 1. Copy the entire 'aws-management-studio' folder to your desired location
    echo 2. Run the launcher from inside that folder
    echo.
    echo Or create a desktop shortcut pointing to the launcher in the original location.
    echo.
    pause
    exit /b 1
)

REM Check PowerShell availability (try PowerShell 7+ first, then fallback)
pwsh -Version >nul 2>&1
if %errorlevel% equ 0 (
    echo Using PowerShell 7+
    pwsh -ExecutionPolicy Bypass -File "%~dp0Launch-AWSStudio.ps1"
    goto :end
)

echo PowerShell 7+ not found, trying Windows PowerShell 5.1...
powershell -Version >nul 2>&1
if %errorlevel% equ 0 (
    echo Using Windows PowerShell 5.1 (fallback)
    powershell -ExecutionPolicy Bypass -File "%~dp0Launch-AWSStudio.ps1"
    goto :end
)

echo.
echo ERROR: No PowerShell installation found
echo Please install PowerShell 7.0+ from: https://github.com/PowerShell/PowerShell/releases
echo.
echo To use AWS Management Studio:
echo 1. Copy the entire 'aws-management-studio' folder to your desired location
echo 2. Run the launcher from inside that folder
echo.
echo Or create a desktop shortcut pointing to the launcher in the original location.
echo.
pause
exit /b 1

:end

if %errorlevel% neq 0 (
    echo ERROR: Application failed to launch
    pause
    exit /b 1
)