@echo off
chcp 65001 >nul
title G4 Control v0.9.2 Public Beta Beta - Install or Update
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0helper\install.ps1"
echo.
pause
