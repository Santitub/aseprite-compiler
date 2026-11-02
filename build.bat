@echo off
rem Aseprite build script for Windows.
rem
rem Thin launcher for build.ps1, so the build can be started by double-clicking
rem this file or from cmd.exe. All options are forwarded, for example:
rem
rem   build.bat -Version v1.3.18.6 -Arch arm64 -Yes
rem   build.bat -Help
rem
setlocal

set "PS_EXE=powershell.exe"
where pwsh.exe >nul 2>&1 && set "PS_EXE=pwsh.exe"

if /i "%~1"=="-h" goto :help
if /i "%~1"=="--help" goto :help
if /i "%~1"=="-Help" goto :help
if /i "%~1"=="/?" goto :help

"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
set "EXIT_CODE=%ERRORLEVEL%"

rem Keep the window open when the script was started from Explorer
if "%~1"=="" if not defined CI pause
exit /b %EXIT_CODE%

:help
"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "Get-Help -Detailed '%~dp0build.ps1'"
exit /b 0
