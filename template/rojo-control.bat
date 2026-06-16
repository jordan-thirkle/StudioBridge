@echo off
set "STUDIO_BRIDGE_DIR=D:\Projects\Internal\StudioBridge"
if not exist "%STUDIO_BRIDGE_DIR%\src\rojo-control.ps1" (
	echo Studio Bridge not found at %STUDIO_BRIDGE_DIR%
	pause
	exit /b 1
)
powershell -ExecutionPolicy Bypass -File "%STUDIO_BRIDGE_DIR%\src\rojo-control.ps1" -ProjectDir "%~dp0"
