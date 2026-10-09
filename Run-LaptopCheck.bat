@echo off
rem Double-click this file to check the laptop. No Python needed.
rem The script asks for administrator rights and saves a report next to this file.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0laptop_check.ps1" %*
if errorlevel 1 pause
