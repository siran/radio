@echo off
rem Double-click me, or run me from cmd. Everything after the name is handed
rem straight to the script, so this works the same as calling it directly:
rem
rem   restart-radio.cmd
rem   restart-radio.cmd -Status
rem   restart-radio.cmd -What liquidsoap
rem
rem The script asks for administrator rights itself, so there is no need to
rem right-click this. %~dp0 is this file's own folder, so it can be run from
rem anywhere without caring what the current directory is.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0restart-radio.ps1" %*
if errorlevel 1 (
  echo.
  echo That did not run. Open PowerShell in this folder and try:
  echo    .\restart-radio.ps1 -Status
  pause
)
