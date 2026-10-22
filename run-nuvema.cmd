@echo off
setlocal
set "ROOT=%~dp0"
if not exist "%ROOT%.tools\Godot_v4.4.1-stable_win64.exe" (
  echo Godot 4.4.1 was not found in .tools.
  pause
  exit /b 1
)
if not exist "%ROOT%client\assets\bw\nuvema\placements.json" (
  echo Nuvema assets are missing. Run:
  echo   python tools\rom\extract_nuvema.py
  pause
  exit /b 1
)
start "" "%ROOT%.tools\Godot_v4.4.1-stable_win64.exe" --path "%ROOT%client" res://scenes/NuvemaTown.tscn
