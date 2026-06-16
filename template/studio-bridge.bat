@echo off
REM Studio Bridge launcher — copy this into any Rojo project root.
REM Edit STUDIO_BRIDGE_DIR to point to your StudioBridge installation.
set "STUDIO_BRIDGE_DIR=D:\Projects\Internal\StudioBridge"
if not exist "%STUDIO_BRIDGE_DIR%\src\studio-bridge.ps1" (
	echo Studio Bridge not found at %STUDIO_BRIDGE_DIR%
	echo Run install.ps1 first, or edit STUDIO_BRIDGE_DIR in this file.
	pause
	exit /b 1
)
powershell -ExecutionPolicy Bypass -File "%STUDIO_BRIDGE_DIR%\src\studio-bridge.ps1" -ProjectDir "%~dp0"
