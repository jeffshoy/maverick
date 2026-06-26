@echo off
setlocal enabledelayedexpansion
title PLUS Customer User Admin

:MENU
cls
echo =========================================
echo  PLUS Customer User Admin
echo =========================================
echo.
echo  1  Create new PLUS customer user
echo  2  Re-enable (un-terminate) a PLUS user
echo  3  Disable (terminate) a PLUS user
echo  Q  Quit
echo.
set /p CHOICE=Enter choice [1/2/3/Q]:

if /i "!CHOICE!"=="1" goto :CREATE
if /i "!CHOICE!"=="2" goto :ENABLE
if /i "!CHOICE!"=="3" goto :DISABLE
if /i "!CHOICE!"=="Q" goto :EOF
goto :MENU

:CREATE
cls
echo -- CREATE new PLUS customer user --
echo Leave optional fields blank and press Enter to skip.
echo.
set /p CUST=Customer site code (3 letters, e.g. SJC):
set /p FIRSTNAME=First name:
set /p MI=Middle initial (optional):
set /p LASTNAME=Last name:
set /p EMAIL=Email address:
set /p ISDBA=Is this user a DBA admin? (Y/N, default N):

set DBASWITCH=
if /i "!ISDBA!"=="Y" set DBASWITCH=-IsUserDBA

set MIARG=
if not "!MI!"=="" set MIARG=-MiddleInitial "!MI!"

echo.
echo Running New-PLUSCustomerUser -- please wait ...
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\New-PLUSCustomerUser\New-PLUSCustomerUser.ps1" ^
  -Cust "!CUST!" -FirstName "!FIRSTNAME!" -LastName "!LASTNAME!" ^
  -EmailAddress "!EMAIL!" !DBASWITCH! !MIARG!
echo.
pause
goto :MENU

:ENABLE
cls
echo -- RE-ENABLE a PLUS customer user --
echo.
set /p SAMID=aspgov.pri samAccountName (e.g. sjcjsmith):
echo.
echo Running Enable-PLUSCustomerUser -- please wait ...
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\Enable-PLUSCustomerUser\Enable-PLUSCustomerUser.ps1" ^
  -Samid "!SAMID!"
echo.
pause
goto :MENU

:DISABLE
cls
echo -- DISABLE (terminate) a PLUS customer user --
echo.
set /p SAMID=aspgov.pri samAccountName (e.g. sjcjsmith):
set /p CASENO=Case or ticket number (e.g. 02502101):
echo.
echo Running Disable-PLUSCustomerUser -- please wait ...
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\Disable-PLUSCustomerUser\Disable-PLUSCustomerUser.ps1" ^
  -Samid "!SAMID!" -CaseNo "!CASENO!"
echo.
pause
goto :MENU
