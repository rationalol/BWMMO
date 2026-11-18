@echo off
setlocal
cd /d "%~dp0"

rem Rebuild every indoor scene from the local ROM, then prove the result with
rem the headless audit. Run this after changing tools/rom/prop_resolve.py or
rem extract_unova_indoor.py; it replaces the old "walk around the house and
rem look at it" acceptance pass.

set "ROM=Pokemon - White Version (USA, Europe) (NDSi Enhanced).nds"
if not exist "%ROM%" (
  echo ROM not found: %CD%\%ROM%
  exit /b 1
)

echo [1/5] extracting indoor scenes...
python tools\rom\extract_unova_indoor.py --rom "%ROM%" --force
if errorlevel 1 goto fail

echo [2/5] building indoor worlds...
python tools\rom\build_unova_indoor_worlds.py
if errorlevel 1 goto fail

echo [3/5] building maps (NPCs, warps, doors)...
python tools\rom\build_unova_maps.py
if errorlevel 1 goto fail

echo [4/5] importing new assets into Godot...
where godot >nul 2>nul
if errorlevel 1 (
  echo godot not on PATH; run: godot --headless --path client --import
) else (
  godot --headless --path client --import
  if errorlevel 1 goto fail
)

echo [5/5] auditing...
python tools\rom\audit_assets.py --props
if errorlevel 1 goto fail
echo.
echo Indoor rebuild OK. The bedroom (zone 391) must show tv01, stair_d01 and plant01.
if not "%NO_PAUSE%"=="1" pause
exit /b 0

:fail
echo.
echo Indoor rebuild FAILED at step %errorlevel%. See the messages above.
if not "%NO_PAUSE%"=="1" pause
exit /b 1
