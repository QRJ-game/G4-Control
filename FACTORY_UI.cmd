@echo off
chcp 65001 >nul
title G4 Control - Factory UI
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0helper\factory-ui.ps1"
echo.
pause
