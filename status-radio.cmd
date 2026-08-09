@echo off
rem Double-click me. Says what the station is doing and changes nothing.
rem
rem   status-radio.cmd
rem
rem No administrator rights are asked for and none are needed: -Status returns
rem before the elevation block in restart-radio.ps1, so there is no UAC prompt
rem and nothing here can restart anything by accident. That is the whole reason
rem this exists as its own file - a bare double-click of restart-radio.cmd runs
rem -What all, because all is the default, and that is a real restart.
rem
rem It pauses at the end so a double-clicked window stays open to be read.
rem %~dp0 is this file's own folder, so it runs from anywhere.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0restart-radio.ps1" -Status
echo.
pause
