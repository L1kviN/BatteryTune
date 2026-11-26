@echo off
chcp 65001 >nul
title BatteryTune
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0BatteryTune.ps1" -Action menu
if errorlevel 1 pause
