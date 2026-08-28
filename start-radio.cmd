@echo off
rem Double-click me. Starts anything that is down and leaves alone anything that
rem is not, so running it twice is safe and the second run touches nothing.
rem
rem   start-radio.cmd            bring up whatever is down
rem   start-radio.cmd -Status    say what is up, change nothing
rem
rem This is NOT restart-radio.cmd. That one stops things and starts them again,
rem which drops every listener; this one never stops anything. Use this after
rem the machine has been off, or when one piece died and the rest is fine.
rem
rem The script asks for administrator rights itself when it needs them, so there
rem is no need to right-click this. -Status returns before the elevation block,
rem so asking what is up never prompts.
rem
rem %~dp0 is this file's own folder, so it runs from anywhere.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-radio.ps1" %*
if errorlevel 1 (
  echo.
  echo That did not run. Open PowerShell in this folder and try:
  echo    .\start-radio.ps1 -Status
)
echo.
pause
