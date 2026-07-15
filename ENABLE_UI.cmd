@echo off
chcp 65001 >nul
title G4 Control - Enable UI
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0helper\enable-ui.ps1"
echo.
pause
