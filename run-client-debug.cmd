@echo off
setlocal
set "ROOT=%~dp0"
set "CONSOLE=%ROOT%.tools\Godot_v4.4.1-stable_win64_console.exe"
if not exist "%CONSOLE%" (
  echo Godot 4.4.1 console build was not found in .tools.
  echo Install Godot 4.4.x and edit this script, or run it from the editor.
  pause
  exit /b 1
)
if not exist "%ROOT%.tools" mkdir "%ROOT%.tools"
echo Running the client with console output captured in .tools\client.log
echo Leave this window open while you play; close the game to finish.
"%CONSOLE%" --path "%ROOT%client" -- --server=ws://127.0.0.1:2567 > "%ROOT%.tools\client.log" 2>&1
