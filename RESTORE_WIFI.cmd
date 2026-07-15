@echo off
chcp 65001 >nul
title G4 Control v0.9.2 - Restore Wi-Fi
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0helper\restore-wifi.ps1"
echo.
pause
