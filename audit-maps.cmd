@echo off
setlocal
cd /d "%~dp0"
python tools\rom\audit_maps.py --report .tools\map-audit\report.md
set "CODE=%ERRORLEVEL%"
echo.
echo Report: %CD%\.tools\map-audit\report.md
if not "%NO_PAUSE%"=="1" pause
exit /b %CODE%
