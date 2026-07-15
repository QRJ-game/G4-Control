@echo off
chcp 65001 >nul
title G4 Control - Verify Current Install
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0helper\verify-current-install.ps1"
echo.
pause
