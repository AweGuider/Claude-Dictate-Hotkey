@echo off
if exist "%~dp0ClaudeDictateHotkey.exe" (
    start "" "%~dp0ClaudeDictateHotkey.exe" /settings
) else (
    start "" "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" "%~dp0ClaudeDictateHotkey.ahk" /settings
)
