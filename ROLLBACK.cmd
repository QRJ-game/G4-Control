@echo off
chcp 65001 >nul
title G4 Control - Full Rollback
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0helper\rollback.ps1"
echo.
pause
