@echo off
setlocal
set "ROOT=%~dp0"
if not exist "%ROOT%.tools\Godot_v4.4.1-stable_win64.exe" (
  echo Godot 4.4.1 was not found in .tools.
  echo Install Godot 4.4.x and edit this script, or run it from the editor.
  pause
  exit /b 1
)
start "" "%ROOT%.tools\Godot_v4.4.1-stable_win64.exe" --path "%ROOT%client"
