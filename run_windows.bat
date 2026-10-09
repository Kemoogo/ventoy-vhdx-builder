@echo off
setlocal
:: Check for admin permissions
net session >nul 2>&1
if %errorLevel% == 0 (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0create_ventoy_vhdx.ps1"
) else (
    echo [!] Requesting administrative privileges...
    powershell -Command "Start-Process cmd -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
)
endlocal
