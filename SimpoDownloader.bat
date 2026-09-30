@echo off
title SimpoDownloader
rem Runs the PowerShell version - built into Windows 10/11, nothing to install.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0simpodl.ps1" %*
echo.
pause
