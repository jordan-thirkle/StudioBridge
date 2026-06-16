# Studio Bridge — Installer
param(
	[string]$InstallDir = "",
	[switch]$NoShortcut
)

$ErrorActionPreference = "Continue"

Write-Host @"
=== Studio Bridge Installer ===
"@

# --- Determine install location ---
if (-not $InstallDir) {
	$defaultDir = Join-Path -Path $env:USERPROFILE -ChildPath "Projects\Internal\StudioBridge"
	if (-not (Test-Path -LiteralPath (Split-Path -Parent $defaultDir))) {
		$defaultDir = "D:\Projects\Internal\StudioBridge"
	}
	$InstallDir = Read-Host "Install directory [$defaultDir]"
	if (-not $InstallDir) { $InstallDir = $defaultDir }
}

$scriptDir = Split-Path -Parent $PSCommandPath
if (-not $scriptDir) { $scriptDir = Get-Location }

# --- Check prerequisites ---
$hasGit = Get-Command "git" -ErrorAction SilentlyContinue
$hasRojo = Get-Command "rojo" -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Checking prerequisites..."

if (-not $hasGit) {
	Write-Host "[WARN] Git not found. Install from https://git-scm.com"
} else {
	Write-Host "[OK] Git: $((git --version 2>&1).Trim())"
}

if (-not $hasRojo) {
	Write-Host "[INFO] Rojo not found. Install via: rokit install"
	Write-Host "      Download Rokit from: https://github.com/rojo-rbx/rokit"
} else {
	Write-Host "[OK] Rojo: $((rojo --version 2>&1).Trim())"
}

# --- Copy files ---
Write-Host ""
Write-Host "Installing to: $InstallDir"

if (-not (Test-Path -LiteralPath $InstallDir)) {
	New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}
if (-not (Test-Path -LiteralPath "$InstallDir\src")) {
	New-Item -ItemType Directory -Path "$InstallDir\src" -Force | Out-Null
}
if (-not (Test-Path -LiteralPath "$InstallDir\template")) {
	New-Item -ItemType Directory -Path "$InstallDir\template" -Force | Out-Null
}

Copy-Item -Path "$scriptDir\src\studio-bridge.ps1" -Destination "$InstallDir\src\" -Force
Copy-Item -Path "$scriptDir\src\rojo-control.ps1" -Destination "$InstallDir\src\" -Force
Copy-Item -Path "$scriptDir\src\rojo-stop.ps1" -Destination "$InstallDir\src\" -Force
Copy-Item -Path "$scriptDir\template\studio-bridge.bat" -Destination "$InstallDir\template\" -Force
Copy-Item -Path "$scriptDir\template\rojo-control.bat" -Destination "$InstallDir\template\" -Force
Copy-Item -Path "$scriptDir\README.md" -Destination "$InstallDir\" -Force
Copy-Item -Path "$scriptDir\LICENSE" -Destination "$InstallDir\" -Force
Write-Host "[OK] Files copied"

# --- Create desktop shortcut ---
if (-not $NoShortcut) {
	$desktop = [Environment]::GetFolderPath("Desktop")
	$wshell = New-Object -ComObject WScript.Shell
	$shortcut = $wshell.CreateShortcut("$desktop\Studio Bridge.lnk")
	$shortcut.TargetPath = "powershell.exe"
	$shortcut.Arguments = "-ExecutionPolicy Bypass -File `"$InstallDir\src\studio-bridge.ps1`""
	$shortcut.WorkingDirectory = $InstallDir
	$shortcut.Description = "Studio Bridge — Universal Rojo Dev Dashboard"
	$shortcut.Save()
	Write-Host "[OK] Desktop shortcut created"
}

# --- Add to PATH (optional) ---
$pathKey = [Environment]::GetEnvironmentVariable("Path", "User")
$binDir = Split-Path -Parent (Get-Command "powershell.exe" -ErrorAction SilentlyContinue).Source
if ($pathKey -notlike "*$InstallDir*") {
	Write-Host ""
	Write-Host "[INFO] To run 'studio-bridge' from anywhere, add to PATH:"
	Write-Host "       [Environment]::SetEnvironmentVariable('Path',"
	Write-Host "           `"[Environment]::GetEnvironmentVariable('Path','User') + ';$InstallDir\src'`", 'User')"
}

# --- Done ---
Write-Host ""
Write-Host @"
=== Installation Complete ===

Studio Bridge installed at: $InstallDir

QUICK START:
  Double-click the "Studio Bridge" desktop icon
  -> Click the Health tab
  -> Click Browse, pick your Rojo project folder
  -> Click "Run Full Health Check"

OR run from any project:
  powershell -ExecutionPolicy Bypass -File "$InstallDir\src\studio-bridge.ps1" -ProjectDir "C:\path\to\project"

TO ADD TO A NEW PROJECT:
  Copy template\studio-bridge.bat into the project root.
  Edit STUDIO_BRIDGE_DIR in that file if needed.
"@
