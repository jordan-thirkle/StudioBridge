# Studio Bridge — Portable Health Engine
# Pure functions returning structured objects.
# Import: Import-Module .\HealthEngine.psm1
# CLI:   powershell -Command "Import-Module .\HealthEngine.psm1; Run-HealthCheck -TargetDir 'X' | ConvertTo-Json"

function Remove-AnsiEscape {
	param([string]$InputString)
	if (-not $InputString) { return "" }
	$ansiRegex = '\x1B\[[0-?]*[ -/]*[@-~]'
	return [regex]::Replace($InputString, $ansiRegex, '')
}

function Get-ToolVersion {
	param([string]$ToolName, [string]$Arg = "--version", [string]$WorkingDir = "")

	$cmd = Get-Command $ToolName -ErrorAction SilentlyContinue
	if (-not $cmd) {
		return New-Object PSObject -Property @{ Status = "FAIL"; Check = $ToolName; Detail = "$ToolName NOT FOUND in PATH"; Valid = $false; Group = "Tools" }
	}

	$raw = $null
	$timeoutSec = 10
	try {
		$exePath = (Get-Command $ToolName).Source
		$psi = New-Object System.Diagnostics.ProcessStartInfo
		$psi.FileName = $exePath
		$psi.Arguments = $Arg
		$psi.WorkingDirectory = if ($WorkingDir) { $WorkingDir } else { (Get-Location).Path }
		$psi.UseShellExecute = $false
		$psi.RedirectStandardOutput = $true
		$psi.RedirectStandardError = $true
		$psi.CreateNoWindow = $true
		$proc = [System.Diagnostics.Process]::Start($psi)
		if ($proc.WaitForExit($timeoutSec * 1000)) {
			$raw = $proc.StandardOutput.ReadToEnd() + $proc.StandardError.ReadToEnd()
		} else {
			$proc.Kill()
			return New-Object PSObject -Property @{ Status = "WARN"; Check = $ToolName; Detail = "$ToolName timed out after ${timeoutSec}s"; Valid = $true; Group = "Tools" }
		}
	} catch {
		return New-Object PSObject -Property @{ Status = "WARN"; Check = $ToolName; Detail = "$ToolName found but failed to run"; Valid = $true; Group = "Tools" }
	}

	if ($null -eq $raw) {
		return New-Object PSObject -Property @{ Status = "WARN"; Check = $ToolName; Detail = "$ToolName produced no output"; Valid = $true; Group = "Tools" }
	}

	$clean = Remove-AnsiEscape ($raw | Out-String)
	$lines = $clean.Trim() -split "`n"
	$firstLine = $lines[0].Trim()
	$version = ($firstLine -replace '^.*\berror\b.*$', '') -replace '^\D+(\d[\d.]*)', '$1'
	if (-not $version -or $version -match "ERROR|error|not found|failed") {
		$version = $firstLine
		if ($version.Length -gt 60) { $version = $version.Substring(0, 60) + "..." }
		return New-Object PSObject -Property @{ Status = "WARN"; Check = $ToolName; Detail = "$ToolName : $version"; Valid = $true; Group = "Tools" }
	}
	if ($version.Length -gt 50) { $version = $version.Substring(0, 50) + "..." }
	return New-Object PSObject -Property @{ Status = "OK"; Check = $ToolName; Detail = "$ToolName $version"; Valid = $true; Group = "Tools" }
}

function Run-HealthCheck {
	param([string]$TargetDir, [switch]$Quick)

	$results = @()

	if (-not (Test-Path -LiteralPath $TargetDir)) {
		$results += New-Object PSObject -Property @{ Status = "FAIL"; Check = "Project"; Detail = "Directory does not exist: $TargetDir"; Fix = "Choose a different folder"; Group = "Project" }
		return $results
	}

	# --- Project file ---
	$projFile = Join-Path -Path $TargetDir -ChildPath "default.project.json"
	if (Test-Path -LiteralPath $projFile) {
		try {
			$json = Get-Content -LiteralPath $projFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
			$pn = if ($json.name) { $json.name } else { "Unnamed" }
			$results += New-Object PSObject -Property @{ Status = "OK"; Check = "Project"; Detail = "default.project.json valid (`"$pn`")"; Group = "Project" }
		} catch {
			$results += New-Object PSObject -Property @{ Status = "FAIL"; Check = "Project"; Detail = "default.project.json: invalid JSON"; Fix = "Check that the file has valid JSON syntax"; Group = "Project" }
		}
		$rojofile = Join-Path -Path $TargetDir -ChildPath "rokit.toml"
		if (Test-Path -LiteralPath $rojofile) {
			$results += New-Object PSObject -Property @{ Status = "OK"; Check = "Toolchain"; Detail = "rokit.toml found (tools versioned)"; Group = "Project" }
		} else {
			$results += New-Object PSObject -Property @{ Status = "WARN"; Check = "Toolchain"; Detail = "rokit.toml missing (tools not pinned)"; Fix = "Run: rokit init"; Group = "Project" }
		}
	} else {
		$results += New-Object PSObject -Property @{ Status = "FAIL"; Check = "Project"; Detail = "default.project.json NOT FOUND"; Fix = "Select a folder with a valid Rojo project"; Group = "Project" }
		return $results
	}

	# --- Luaurc ---
	$luaurcFile = Join-Path -Path $TargetDir -ChildPath ".luaurc"
	if (Test-Path -LiteralPath $luaurcFile) {
		$results += New-Object PSObject -Property @{ Status = "OK"; Check = "Luaurc"; Detail = ".luaurc found (Luau mode configured)"; Group = "Project" }
	} else {
		$results += New-Object PSObject -Property @{ Status = "WARN"; Check = "Luaurc"; Detail = ".luaurc missing (VS Code type hints need it)"; Fix = "Create .luaurc"; Group = "Project" }
	}

	# --- Tool versions ---
	foreach ($name in @("Rojo", "StyLua", "Selene", "Lune", "Wally")) {
		$results += Get-ToolVersion -ToolName $name -WorkingDir $TargetDir
	}

	# --- Rojo serve ---
	$rojoRunning = $null -ne (Get-Process -Name "rojo" -ErrorAction SilentlyContinue)
	if ($rojoRunning) {
		$results += New-Object PSObject -Property @{ Status = "OK"; Check = "Rojo serve"; Detail = "Rojo serve is RUNNING"; Group = "Rojo" }
	} else {
		$results += New-Object PSObject -Property @{ Status = "INFO"; Check = "Rojo serve"; Detail = "Rojo serve is STOPPED. Start from Rojo tab when needed."; Fix = "Go to Rojo tab -> Start"; Group = "Rojo" }
	}

	# --- Git ---
	$gitDir = Join-Path -Path $TargetDir -ChildPath ".git"
	if (Test-Path -LiteralPath $gitDir -PathType Container) {
		try {
			$status = & git -C $TargetDir status --short 2>&1
			$fileCount = ($status | Where-Object { $_ }).Count
			if ($fileCount -gt 0) {
				$results += New-Object PSObject -Property @{ Status = "WARN"; Check = "Git status"; Detail = "$fileCount uncommitted file(s)"; Fix = "Go to Git tab -> Commit"; Group = "Git" }
			} else {
				$results += New-Object PSObject -Property @{ Status = "OK"; Check = "Git status"; Detail = "Working tree clean"; Group = "Git" }
			}
		} catch {
			$results += New-Object PSObject -Property @{ Status = "WARN"; Check = "Git status"; Detail = "Could not check Git status"; Group = "Git" }
		}
		try {
			$lc = & git -C $TargetDir log --oneline -1 2>&1
			if ($lc) {
				$results += New-Object PSObject -Property @{ Status = "OK"; Check = "Git log"; Detail = ($lc | Out-String).Trim(); Group = "Git" }
			}
		} catch {
			$results += New-Object PSObject -Property @{ Status = "INFO"; Check = "Git log"; Detail = "No commits yet"; Group = "Git" }
		}
	} else {
		$results += New-Object PSObject -Property @{ Status = "FAIL"; Check = "Git"; Detail = "Not a git repository"; Fix = "Run: git init"; Group = "Git" }
	}

	# --- Sourcemap ---
	$srcmap = Join-Path -Path $TargetDir -ChildPath "sourcemap.json"
	if (Test-Path -LiteralPath $srcmap) {
		$results += New-Object PSObject -Property @{ Status = "OK"; Check = "Sourcemap"; Detail = "sourcemap.json exists (LSP ready)"; Group = "Tools" }
	} else {
		$results += New-Object PSObject -Property @{ Status = "WARN"; Check = "Sourcemap"; Detail = "sourcemap.json missing (VS Code type hints need it)"; Fix = "Generate it: rojo sourcemap"; FixCommand = "rojo sourcemap `"$projFile`" --output `"$srcmap`""; Group = "Tools" }
	}

	# --- Packages ---
	$pkgDir = Join-Path -Path $TargetDir -ChildPath "Packages"
	if (Test-Path -LiteralPath $pkgDir -PathType Container) {
		$results += New-Object PSObject -Property @{ Status = "OK"; Check = "Packages"; Detail = "Packages/ installed"; Group = "Tools" }
	} else {
		$results += New-Object PSObject -Property @{ Status = "INFO"; Check = "Packages"; Detail = "Packages/ not installed (needed for Wally dependencies)"; Fix = "Run: wally install"; Group = "Tools" }
	}

	# --- Source files ---
	$srcDir = Join-Path -Path $TargetDir -ChildPath "src"
	if (Test-Path -LiteralPath $srcDir -PathType Container) {
		$files = Get-ChildItem -Path $srcDir -Recurse -Include *.luau, *.lua -ErrorAction SilentlyContinue
		$results += New-Object PSObject -Property @{ Status = "OK"; Check = "Source files"; Detail = "$($files.Count) source files in src/"; Group = "Project" }
	} else {
		$results += New-Object PSObject -Property @{ Status = "WARN"; Check = "Source files"; Detail = "src/ directory not found"; Group = "Project" }
	}

	return $results
}

Export-ModuleMember -Function Run-HealthCheck, Get-ToolVersion, Remove-AnsiEscape
