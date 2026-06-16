param(
	[string]$ProjectDir = ""
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Project Discovery ---
function Get-ProjectDirectory {
	if ($ProjectDir -and (Test-Path -LiteralPath $ProjectDir)) {
		return $ProjectDir
	}
	$candidate = Get-Location
	if (Test-Path (Join-Path -Path $candidate -ChildPath "default.project.json")) {
		return $candidate
	}
	$scriptDir = Split-Path -Parent $PSCommandPath
	if ($scriptDir -and (Test-Path (Join-Path -Path $scriptDir -ChildPath "default.project.json"))) {
		return $scriptDir
	}
	return ""
}

$projectRoot = Get-ProjectDirectory
if (-not $projectRoot) {
	$projectRoot = (Get-Location).Path
}

# --- Shared State ---
$script:outputQueue = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
$script:rojoProcess = $null
$script:rojoSubscriptions = @()
$script:allSubscriptions = @()
$script:portNumber = "--"
$script:projectName = "Unknown Project"
$script:healthProjectDir = $projectRoot

# --- Helper Functions ---

function Write-Log {
	param([string]$text)
	$sharedLogBox.AppendText("$text`r`n")
	$sharedLogBox.SelectionStart = $sharedLogBox.Text.Length
	$sharedLogBox.ScrollToCaret()
}

function Write-LogTimestamped {
	param([string]$text)
	$time = Get-Date -Format "HH:mm:ss"
	Write-Log "[$time] $text"
}

function Run-Tool {
	param(
		[string]$FileName,
		[string]$Arguments,
		[string]$WorkingDirectory,
		[string]$ToolName = "Tool"
	)

	$cmd = Get-Command $FileName -ErrorAction SilentlyContinue
	if (-not $cmd) {
		Write-LogTimestamped "[ERROR] '$FileName' not found in PATH."
		return $null
	}

	$psi = New-Object System.Diagnostics.ProcessStartInfo
	$psi.FileName = $FileName
	$psi.Arguments = $Arguments
	$psi.WorkingDirectory = $WorkingDirectory
	$psi.UseShellExecute = $false
	$psi.RedirectStandardOutput = $true
	$psi.RedirectStandardError = $true
	$psi.CreateNoWindow = $true
	$psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
	$psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

	$proc = New-Object System.Diagnostics.Process
	$proc.StartInfo = $psi
	$proc.EnableRaisingEvents = $true

	try {
		$outSub = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action {
			$data = $Event.SourceEventArgs.Data
			if ($data -ne $null) {
				$script:outputQueue.Enqueue($data)
			}
		} -MessageData $ToolName
		$errSub = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -Action {
			$data = $Event.SourceEventArgs.Data
			if ($data -ne $null) {
				$script:outputQueue.Enqueue("[ERR] $data")
			}
		} -MessageData $ToolName
		$exitSub = Register-ObjectEvent -InputObject $proc -EventName Exited -Action {
			$toolName = $Event.MessageData
			$exitCode = $Event.Sender.ExitCode
			$script:outputQueue.Enqueue("[DONE] $toolName finished (exit code: $exitCode)")
		} -MessageData $ToolName

		$script:allSubscriptions += @($outSub, $errSub, $exitSub)

		$proc.Start() | Out-Null
		$proc.BeginOutputReadLine()
		$proc.BeginErrorReadLine()

		Write-LogTimestamped "[$ToolName] Started: $FileName $Arguments"
		return $proc
	}
	catch {
		Write-LogTimestamped "[ERROR] Failed to start $ToolName : $($_)"
		return $null
	}
}

function Start-Rojo {
	if ($script:rojoProcess -and !$script:rojoProcess.HasExited) {
		Write-LogTimestamped "Rojo is already running."
		return
	}

	$cmd = Get-Command "rojo" -ErrorAction SilentlyContinue
	if (-not $cmd) {
		Write-LogTimestamped "[ERROR] 'rojo' not found in PATH. Install via: rokit install"
		return
	}

	Write-LogTimestamped "Starting rojo serve..."

	$psi = New-Object System.Diagnostics.ProcessStartInfo
	$psi.FileName = "rojo"
	$psi.Arguments = "serve"
	$psi.WorkingDirectory = $projectRoot
	$psi.UseShellExecute = $false
	$psi.RedirectStandardOutput = $true
	$psi.RedirectStandardError = $true
	$psi.CreateNoWindow = $true
	$psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
	$psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

	$proc = New-Object System.Diagnostics.Process
	$proc.StartInfo = $psi

	try {
		$proc.Start() | Out-Null
		$proc.BeginOutputReadLine()
		$proc.BeginErrorReadLine()

		$outSub = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action {
			$data = $Event.SourceEventArgs.Data
			if ($data -ne $null) {
				$script:outputQueue.Enqueue($data)
				if ($data -match "Port:\s+(\d+)") {
					$script:portNumber = $matches[1]
				}
			}
		}
		$errSub = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -Action {
			$data = $Event.SourceEventArgs.Data
			if ($data -ne $null) {
				$script:outputQueue.Enqueue("[ERR] $data")
			}
		}

		$script:rojoSubscriptions = @($outSub, $errSub)
		$script:rojoProcess = $proc
		Write-LogTimestamped "Rojo serve started (PID: $($proc.Id))"
		Update-Status
	}
	catch {
		Write-LogTimestamped "[ERROR] Failed to start: $_"
	}
}

function Stop-Rojo {
	Write-LogTimestamped "Stopping rojo serve..."

	if ($script:rojoProcess -and !$script:rojoProcess.HasExited) {
		try {
			$script:rojoProcess.Kill()
			$script:rojoProcess.WaitForExit(3000)
		}
		catch {
			Write-LogTimestamped "[WARN] Could not kill process: $_"
		}
		$script:rojoProcess.Dispose()
		$script:rojoProcess = $null
		$script:portNumber = "--"
	}

	foreach ($sub in $script:rojoSubscriptions) {
		Unregister-Event -SubscriptionId $sub.Id -ErrorAction SilentlyContinue
	}
	$script:rojoSubscriptions = @()

	$orphans = Get-Process -Name "rojo" -ErrorAction SilentlyContinue
	foreach ($p in $orphans) {
		try {
			$p.Kill()
			$p.WaitForExit(2000)
			Write-LogTimestamped "Killed orphan rojo (PID: $($p.Id))"
		}
		catch { }
	}

	Write-LogTimestamped "Rojo stopped."
	Update-Status
}

function Update-Status {
	$running = $false
	$port = "--"

	if ($script:rojoProcess -and !$script:rojoProcess.HasExited) {
		$running = $true
		$port = $script:portNumber
	}
	else {
		$orphans = Get-Process -Name "rojo" -ErrorAction SilentlyContinue
		if ($orphans) {
			$running = $true
			$port = "34872 (orphan)"
		}
	}

	if ($running) {
		$rojoStatusPanel.BackColor = [System.Drawing.Color]::LimeGreen
		$rojoStatusLabel.Text = "Running"
		$startBtn.Enabled = $false
		$stopBtn.Enabled = $true
		$restartBtn.Enabled = $true
	}
	else {
		$rojoStatusPanel.BackColor = [System.Drawing.Color]::Red
		$rojoStatusLabel.Text = "Stopped"
		$startBtn.Enabled = $true
		$stopBtn.Enabled = $false
		$restartBtn.Enabled = $false
	}
	$rojoPortLabel.Text = "Port: $port"
	$statusBarLabel.Text = "Port: $port"
}

function Cleanup-AllSubscriptions {
	foreach ($sub in $script:allSubscriptions) {
		Unregister-Event -SubscriptionId $sub.Id -ErrorAction SilentlyContinue
	}
	$script:allSubscriptions = @()
	foreach ($sub in $script:rojoSubscriptions) {
		Unregister-Event -SubscriptionId $sub.Id -ErrorAction SilentlyContinue
	}
	$script:rojoSubscriptions = @()
}

function Get-ProjectName {
	param([string]$Dir = $projectRoot)
	$projFile = Join-Path -Path $Dir -ChildPath "default.project.json"
	if (Test-Path -LiteralPath $projFile) {
		try {
			$json = Get-Content -LiteralPath $projFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
			if ($json.name) { return $json.name }
		} catch { }
	}
	return (Split-Path -Leaf $Dir)
}

function Show-ProjectPicker {
	$dialog = New-Object System.Windows.Forms.FolderBrowserDialog
	$dialog.Description = "Select your Rojo project folder (the one with default.project.json)"
	$dialog.SelectedPath = $projectRoot
	if ($dialog.ShowDialog() -eq "OK") {
		$script:healthProjectDir = $dialog.SelectedPath
		$global:projectRoot = $dialog.SelectedPath
		$healthPathBox.Text = $dialog.SelectedPath
		$script:projectName = Get-ProjectName -Dir $dialog.SelectedPath
		$form.Text = "Studio Bridge - $script:projectName"
		$rojoProjectLabel.Text = "Project: $dialog.SelectedPath"
		$statusProjectLabel.Text = "Project: $dialog.SelectedPath"
		Write-LogTimestamped "Project set to: $dialog.SelectedPath ($script:projectName)"
		return $true
	}
	return $false
}

function Write-HealthResult {
	param([string]$Text)
	$healthResultsBox.AppendText("$Text`r`n")
	$healthResultsBox.SelectionStart = $healthResultsBox.Text.Length
	$healthResultsBox.ScrollToCaret()
	Write-LogTimestamped $Text
}

function Run-HealthCheck {
	param([string]$TargetDir, [switch]$Quick)

	if (-not (Test-Path -LiteralPath $TargetDir)) {
		Write-HealthResult "[FAIL] Directory does not exist: $TargetDir"
		return
	}

	$healthResultsBox.Clear()
	Write-HealthResult "=== Studio Bridge Health Check ==="
	Write-HealthResult "Target: $TargetDir"
	Write-HealthResult ""

	$passCount = 0
	$warnCount = 0
	$failCount = 0

	# --- Project file checks ---
	$projFile = Join-Path -Path $TargetDir -ChildPath "default.project.json"
	if (Test-Path -LiteralPath $projFile) {
		try {
			$json = Get-Content -LiteralPath $projFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
			$pn = if ($json.name) { $json.name } else { "Unnamed" }
			Write-HealthResult "[OK] default.project.json valid (`"$pn`")"
			$passCount++
		} catch {
			Write-HealthResult "[FAIL] default.project.json: invalid JSON"
			$failCount++
		}

		$rojofile = Join-Path -Path $TargetDir -ChildPath "rokit.toml"
		if (Test-Path -LiteralPath $rojofile) {
			Write-HealthResult "[OK] rokit.toml found (version-managed project)"
			$passCount++
		} else {
			Write-HealthResult "[WARN] rokit.toml missing (tools not pinned)"
			$warnCount++
		}
	} else {
		Write-HealthResult "[FAIL] default.project.json NOT FOUND - not a Rojo project"
		Write-HealthResult ""
		Write-HealthResult "=== Summary: 0 passed, 0 warnings, 1 failure ==="
		Write-HealthResult "Select a project folder with the Browse button above."
		Write-HealthResult ""
		if ([System.Windows.Forms.MessageBox]::Show(
			"default.project.json not found. Browse for a Rojo project?",
			"Project Not Found",
			[System.Windows.Forms.MessageBoxButtons]::YesNo
		) -eq "Yes") {
			[void](Show-ProjectPicker)
		}
		return
	}

	# --- Luaurc ---
	$luaurcFile = Join-Path -Path $TargetDir -ChildPath ".luaurc"
	if (Test-Path -LiteralPath $luaurcFile) {
		Write-HealthResult "[OK] .luaurc found (Luau language mode configured)"
		$passCount++
	} else {
		Write-HealthResult "[WARN] .luaurc missing (Luau LSP may not work)"
		$warnCount++
	}

	# --- Tool version checks ---
	$tools = @(
		@{ Name = "Rojo"; Cmd = "rojo"; Arg = "--version" },
		@{ Name = "StyLua"; Cmd = "stylua"; Arg = "--version" },
		@{ Name = "Selene"; Cmd = "selene"; Arg = "--version" },
		@{ Name = "Lune"; Cmd = "lune"; Arg = "--version" },
		@{ Name = "Wally"; Cmd = "wally"; Arg = "--version" }
	)

	foreach ($tool in $tools) {
		$name = $tool.Name
		$cmd = Get-Command $tool.Cmd -ErrorAction SilentlyContinue
		if ($cmd) {
			try {
				$result = & $tool.Cmd $tool.Arg 2>&1
				$version = ($result | Out-String).Trim().Split("`n")[0].Trim()
				if ($version.Length -gt 40) { $version = $version.Substring(0, 40) + "..." }
				Write-HealthResult "[OK] $name $version"
				$passCount++
			} catch {
				Write-HealthResult "[WARN] $name found but failed to run"
				$warnCount++
			}
		} else {
			Write-HealthResult "[FAIL] $name NOT FOUND in PATH"
			$failCount++
		}
	}

	# --- Rojo serve check ---
	try {
		$rojoRunning = $false
		if ($script:rojoProcess -and !$script:rojoProcess.HasExited) {
			$rojoRunning = $true
		} else {
			$orphans = Get-Process -Name "rojo" -ErrorAction SilentlyContinue
			if ($orphans) { $rojoRunning = $true }
		}
		if ($rojoRunning) {
			Write-HealthResult "[OK] Rojo serve: RUNNING (port $($script:portNumber))"
			$passCount++
		} else {
			Write-HealthResult "[INFO]  Rojo serve: STOPPED (start from Rojo tab)"
		}
	} catch {
		Write-HealthResult "[WARN] Could not check Rojo serve status"
		$warnCount++
	}

	# --- Git checks ---
	$gitDir = Join-Path -Path $TargetDir -ChildPath ".git"
	if (Test-Path -LiteralPath $gitDir -PathType Container) {
		try {
			$status = & git -C $TargetDir status --short 2>&1
			$fileCount = ($status | Where-Object { $_ -ne $null }).Count
			if ($fileCount -gt 0) {
				Write-HealthResult "[WARN] Git: $fileCount uncommitted file(s)"
				$warnCount++
			} else {
				Write-HealthResult "[OK] Git: working tree clean"
				$passCount++
			}
		} catch {
			Write-HealthResult "[WARN] Git repo found but status check failed"
			$warnCount++
		}
		try {
			$lastCommit = & git -C $TargetDir log --oneline -1 2>&1
			if ($lastCommit) {
				Write-HealthResult "[OK] Last commit: $($lastCommit.Trim())"
				$passCount++
			}
		} catch {
			Write-HealthResult "[INFO]  No commits yet"
		}
		try {
			$branch = & git -C $TargetDir rev-parse --abbrev-ref HEAD 2>&1
			if ($branch) { Write-HealthResult "[INFO]  Branch: $($branch.Trim())" }
		} catch { }
	} else {
		Write-HealthResult "[FAIL] Not a git repository (.git missing)"
		$failCount++
	}

	# --- Sourcemap ---
	$srcmap = Join-Path -Path $TargetDir -ChildPath "sourcemap.json"
	if (Test-Path -LiteralPath $srcmap) {
		Write-HealthResult "[OK] sourcemap.json exists (LSP ready)"
		$passCount++
	} else {
		Write-HealthResult "[WARN] sourcemap.json missing (run Rojo Tools -> Generate Sourcemap)"
		$warnCount++
	}

	# --- Packages ---
	$pkgDir = Join-Path -Path $TargetDir -ChildPath "Packages"
	if (Test-Path -LiteralPath $pkgDir -PathType Container) {
		Write-HealthResult "[OK] Packages/ installed"
		$passCount++
	} else {
		Write-HealthResult "[INFO]  Packages/ not installed (run Wally -> Install if needed)"
	}

	# --- Source file count ---
	$srcDir = Join-Path -Path $TargetDir -ChildPath "src"
	if (Test-Path -LiteralPath $srcDir -PathType Container) {
		$luauFiles = Get-ChildItem -Path $srcDir -Recurse -Include *.luau, *.lua -ErrorAction SilentlyContinue
		$fileCount = ($luauFiles | Measure-Object).Count
		Write-HealthResult "[OK] $fileCount source files in src/"
		$passCount++
	} else {
		Write-HealthResult "[WARN] src/ directory not found"
		$warnCount++
	}

	# --- Summary ---
	Write-HealthResult ""
	Write-HealthResult "=== Summary: $passCount passed, $warnCount warnings, $failCount failures ==="
	if ($failCount -eq 0 -and $warnCount -eq 0) {
		Write-HealthResult "[OK] Everything looks good!"
	} elseif ($failCount -eq 0) {
		Write-HealthResult "[WARN] All critical checks pass, address warnings when convenient."
	} else {
		Write-HealthResult "[FAIL] $failCount critical issue(s) need attention."
	}
}

# --- Form Creation ---
$form = New-Object System.Windows.Forms.Form
$script:projectName = Get-ProjectName -Dir $projectRoot
$form.Text = "Studio Bridge - $script:projectName"
$form.ClientSize = New-Object System.Drawing.Size(750, 600)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false

# --- TabControl ---
$tabControl = New-Object System.Windows.Forms.TabControl
$tabControl.Location = New-Object System.Drawing.Point(0, 0)
$tabControl.Size = New-Object System.Drawing.Size(750, 395)
$form.Controls.Add($tabControl)

# =============================================================================
# TAB 1: Rojo
# =============================================================================
$tabRojo = New-Object System.Windows.Forms.TabPage
$tabRojo.Text = "Rojo"

$rojoStatusPanel = New-Object System.Windows.Forms.Panel
$rojoStatusPanel.Size = New-Object System.Drawing.Size(18, 18)
$rojoStatusPanel.Location = New-Object System.Drawing.Point(14, 14)
$rojoStatusPanel.BackColor = [System.Drawing.Color]::Red
$tabRojo.Controls.Add($rojoStatusPanel)

$rojoStatusLabel = New-Object System.Windows.Forms.Label
$rojoStatusLabel.Text = "Stopped"
$rojoStatusLabel.Location = New-Object System.Drawing.Point(40, 12)
$rojoStatusLabel.Size = New-Object System.Drawing.Size(200, 20)
$rojoStatusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$tabRojo.Controls.Add($rojoStatusLabel)

$rojoPortLabel = New-Object System.Windows.Forms.Label
$rojoPortLabel.Text = "Port: --"
$rojoPortLabel.Location = New-Object System.Drawing.Point(40, 32)
$rojoPortLabel.Size = New-Object System.Drawing.Size(150, 20)
$rojoPortLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8)
$tabRojo.Controls.Add($rojoPortLabel)

$rojoProjectLabel = New-Object System.Windows.Forms.Label
$rojoProjectLabel.Text = "Project: $projectRoot"
$rojoProjectLabel.Location = New-Object System.Drawing.Point(14, 56)
$rojoProjectLabel.Size = New-Object System.Drawing.Size(700, 20)
$rojoProjectLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8)
$rojoProjectLabel.ForeColor = [System.Drawing.Color]::DimGray
$tabRojo.Controls.Add($rojoProjectLabel)

$startBtn = New-Object System.Windows.Forms.Button
$startBtn.Text = "Start"
$startBtn.Location = New-Object System.Drawing.Point(14, 84)
$startBtn.Size = New-Object System.Drawing.Size(90, 30)
$startBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$tabRojo.Controls.Add($startBtn)

$stopBtn = New-Object System.Windows.Forms.Button
$stopBtn.Text = "Stop"
$stopBtn.Location = New-Object System.Drawing.Point(112, 84)
$stopBtn.Size = New-Object System.Drawing.Size(90, 30)
$stopBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$stopBtn.Enabled = $false
$tabRojo.Controls.Add($stopBtn)

$restartBtn = New-Object System.Windows.Forms.Button
$restartBtn.Text = "Restart"
$restartBtn.Location = New-Object System.Drawing.Point(210, 84)
$restartBtn.Size = New-Object System.Drawing.Size(90, 30)
$restartBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$restartBtn.Enabled = $false
$tabRojo.Controls.Add($restartBtn)

$clearBtn = New-Object System.Windows.Forms.Button
$clearBtn.Text = "Clear Log"
$clearBtn.Location = New-Object System.Drawing.Point(450, 84)
$clearBtn.Size = New-Object System.Drawing.Size(90, 30)
$clearBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$tabRojo.Controls.Add($clearBtn)

$startBtn.Add_Click({
	$startBtn.Enabled = $false
	Start-Rojo
})

$stopBtn.Add_Click({ Stop-Rojo })

$restartBtn.Add_Click({
	$restartBtn.Enabled = $false
	Stop-Rojo
	Start-Sleep -Milliseconds 800
	Start-Rojo
})

$clearBtn.Add_Click({
	$sharedLogBox.Clear()
	Write-LogTimestamped "Log cleared."
})

$tabControl.TabPages.Add($tabRojo)

# =============================================================================
# TAB 2: Rojo Tools
# =============================================================================
$tabRbxTools = New-Object System.Windows.Forms.TabPage
$tabRbxTools.Text = "Rojo Tools"

$buildBtn = New-Object System.Windows.Forms.Button
$buildBtn.Text = "Build Project"
$buildBtn.Location = New-Object System.Drawing.Point(14, 20)
$buildBtn.Size = New-Object System.Drawing.Size(140, 32)
$buildBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$tabRbxTools.Controls.Add($buildBtn)

$srcmapBtn = New-Object System.Windows.Forms.Button
$srcmapBtn.Text = "Generate Sourcemap"
$srcmapBtn.Location = New-Object System.Drawing.Point(164, 20)
$srcmapBtn.Size = New-Object System.Drawing.Size(160, 32)
$srcmapBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$tabRbxTools.Controls.Add($srcmapBtn)

$buildBtn.Add_Click({
	Write-LogTimestamped "=== Building project with rojo... ==="
	Run-Tool -FileName "rojo" -Arguments "build -o build.rbxl" -WorkingDirectory $projectRoot -ToolName "Rojo Build"
})

$srcmapBtn.Add_Click({
	Write-LogTimestamped "=== Generating sourcemap... ==="
	Run-Tool -FileName "rojo" -Arguments "sourcemap default.project.json --output sourcemap.json" -WorkingDirectory $projectRoot -ToolName "Sourcemap"
})

$tabControl.TabPages.Add($tabRbxTools)

# =============================================================================
# TAB 3: Lune
# =============================================================================
$tabLune = New-Object System.Windows.Forms.TabPage
$tabLune.Text = "Lune"

$lunePathLabel = New-Object System.Windows.Forms.Label
$lunePathLabel.Text = "Script Path:"
$lunePathLabel.Location = New-Object System.Drawing.Point(14, 20)
$lunePathLabel.Size = New-Object System.Drawing.Size(80, 20)
$lunePathLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$tabLune.Controls.Add($lunePathLabel)

$lunePathBox = New-Object System.Windows.Forms.TextBox
$lunePathBox.Location = New-Object System.Drawing.Point(14, 45)
$lunePathBox.Size = New-Object System.Drawing.Size(540, 22)
$lunePathBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$tabLune.Controls.Add($lunePathBox)

$luneBrowseBtn = New-Object System.Windows.Forms.Button
$luneBrowseBtn.Text = "Browse"
$luneBrowseBtn.Location = New-Object System.Drawing.Point(560, 44)
$luneBrowseBtn.Size = New-Object System.Drawing.Size(80, 26)
$luneBrowseBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$tabLune.Controls.Add($luneBrowseBtn)

$luneRunBtn = New-Object System.Windows.Forms.Button
$luneRunBtn.Text = "Run Script"
$luneRunBtn.Location = New-Object System.Drawing.Point(14, 80)
$luneRunBtn.Size = New-Object System.Drawing.Size(120, 32)
$luneRunBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$tabLune.Controls.Add($luneRunBtn)

$luneOpenDialog = New-Object System.Windows.Forms.OpenFileDialog
$luneOpenDialog.Filter = "Lua Scripts (*.lua;*.luau)|*.lua;*.luau|All Files (*.*)|*.*"
$luneOpenDialog.Title = "Select Lua Script"

$luneBrowseBtn.Add_Click({
	$luneOpenDialog.InitialDirectory = $projectRoot
	if ($luneOpenDialog.ShowDialog() -eq "OK") {
		$lunePathBox.Text = $luneOpenDialog.FileName
	}
})

$luneRunBtn.Add_Click({
	$path = $lunePathBox.Text.Trim()
	if (-not $path) {
		Write-LogTimestamped "[ERROR] Please select a script path first."
		return
	}
	if (-not (Test-Path -LiteralPath $path)) {
		Write-LogTimestamped "[ERROR] File not found: $path"
		return
	}
	Write-LogTimestamped "=== Running script with lune... ==="
	Run-Tool -FileName "lune" -Arguments "run `"$path`"" -WorkingDirectory $projectRoot -ToolName "Lune"
})

$tabControl.TabPages.Add($tabLune)

# =============================================================================
# TAB 4: Wally
# =============================================================================
$tabWally = New-Object System.Windows.Forms.TabPage
$tabWally.Text = "Wally"

$wallyInstallBtn = New-Object System.Windows.Forms.Button
$wallyInstallBtn.Text = "Install Packages"
$wallyInstallBtn.Location = New-Object System.Drawing.Point(14, 20)
$wallyInstallBtn.Size = New-Object System.Drawing.Size(140, 32)
$wallyInstallBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$tabWally.Controls.Add($wallyInstallBtn)

$wallyUpdateBtn = New-Object System.Windows.Forms.Button
$wallyUpdateBtn.Text = "Update Sourcemap"
$wallyUpdateBtn.Location = New-Object System.Drawing.Point(164, 20)
$wallyUpdateBtn.Size = New-Object System.Drawing.Size(160, 32)
$wallyUpdateBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$tabWally.Controls.Add($wallyUpdateBtn)

$wallyInstallBtn.Add_Click({
	Write-LogTimestamped "=== Installing Wally packages... ==="
	Run-Tool -FileName "wally" -Arguments "install" -WorkingDirectory $projectRoot -ToolName "Wally Install"
})

$wallyUpdateBtn.Add_Click({
	Write-LogTimestamped "=== Generating sourcemap... ==="
	Run-Tool -FileName "rojo" -Arguments "sourcemap default.project.json --output sourcemap.json" -WorkingDirectory $projectRoot -ToolName "Sourcemap"
})

$tabControl.TabPages.Add($tabWally)

# =============================================================================
# TAB 5: Git
# =============================================================================
$tabGit = New-Object System.Windows.Forms.TabPage
$tabGit.Text = "Git"

$gitStatusBtn = New-Object System.Windows.Forms.Button
$gitStatusBtn.Text = "Status"
$gitStatusBtn.Location = New-Object System.Drawing.Point(14, 14)
$gitStatusBtn.Size = New-Object System.Drawing.Size(90, 30)
$gitStatusBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$tabGit.Controls.Add($gitStatusBtn)

$gitAddBtn = New-Object System.Windows.Forms.Button
$gitAddBtn.Text = "Add All"
$gitAddBtn.Location = New-Object System.Drawing.Point(112, 14)
$gitAddBtn.Size = New-Object System.Drawing.Size(90, 30)
$gitAddBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$tabGit.Controls.Add($gitAddBtn)

$gitCommitBtn = New-Object System.Windows.Forms.Button
$gitCommitBtn.Text = "Commit"
$gitCommitBtn.Location = New-Object System.Drawing.Point(210, 14)
$gitCommitBtn.Size = New-Object System.Drawing.Size(90, 30)
$gitCommitBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$tabGit.Controls.Add($gitCommitBtn)

$gitPushBtn = New-Object System.Windows.Forms.Button
$gitPushBtn.Text = "Push"
$gitPushBtn.Location = New-Object System.Drawing.Point(308, 14)
$gitPushBtn.Size = New-Object System.Drawing.Size(90, 30)
$gitPushBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$tabGit.Controls.Add($gitPushBtn)

$gitPullBtn = New-Object System.Windows.Forms.Button
$gitPullBtn.Text = "Pull"
$gitPullBtn.Location = New-Object System.Drawing.Point(406, 14)
$gitPullBtn.Size = New-Object System.Drawing.Size(90, 30)
$gitPullBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$tabGit.Controls.Add($gitPullBtn)

$gitCommitLabel = New-Object System.Windows.Forms.Label
$gitCommitLabel.Text = "Commit Message:"
$gitCommitLabel.Location = New-Object System.Drawing.Point(14, 56)
$gitCommitLabel.Size = New-Object System.Drawing.Size(120, 20)
$gitCommitLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$tabGit.Controls.Add($gitCommitLabel)

$gitCommitBox = New-Object System.Windows.Forms.TextBox
$gitCommitBox.Multiline = $true
$gitCommitBox.Location = New-Object System.Drawing.Point(14, 80)
$gitCommitBox.Size = New-Object System.Drawing.Size(700, 80)
$gitCommitBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$gitCommitBox.AcceptsReturn = $true
$tabGit.Controls.Add($gitCommitBox)

$gitStatusBtn.Add_Click({
	Write-LogTimestamped "=== Git Status ==="
	Run-Tool -FileName "git" -Arguments "status" -WorkingDirectory $projectRoot -ToolName "Git Status"
})

$gitAddBtn.Add_Click({
	Write-LogTimestamped "=== Staging all changes... ==="
	Run-Tool -FileName "git" -Arguments "add -A" -WorkingDirectory $projectRoot -ToolName "Git Add"
})

$gitCommitBtn.Add_Click({
	$msg = $gitCommitBox.Text.Trim()
	if (-not $msg) {
		Write-LogTimestamped "[ERROR] Commit message cannot be empty."
		return
	}
	Write-LogTimestamped "=== Committing changes... ==="
	Run-Tool -FileName "git" -Arguments "commit -m `"$msg`"" -WorkingDirectory $projectRoot -ToolName "Git Commit"
	$gitCommitBox.Clear()
})

$gitPushBtn.Add_Click({
	Write-LogTimestamped "=== Pushing to remote... ==="
	Run-Tool -FileName "git" -Arguments "push" -WorkingDirectory $projectRoot -ToolName "Git Push"
})

$gitPullBtn.Add_Click({
	Write-LogTimestamped "=== Pulling from remote... ==="
	Run-Tool -FileName "git" -Arguments "pull" -WorkingDirectory $projectRoot -ToolName "Git Pull"
})

$gitLogBtn = New-Object System.Windows.Forms.Button
$gitLogBtn.Text = "Log"
$gitLogBtn.Location = New-Object System.Drawing.Point(504, 14)
$gitLogBtn.Size = New-Object System.Drawing.Size(90, 30)
$gitLogBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$tabGit.Controls.Add($gitLogBtn)

$gitDiffBtn = New-Object System.Windows.Forms.Button
$gitDiffBtn.Text = "Diff"
$gitDiffBtn.Location = New-Object System.Drawing.Point(14, 170)
$gitDiffBtn.Size = New-Object System.Drawing.Size(90, 30)
$gitDiffBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$tabGit.Controls.Add($gitDiffBtn)

$gitLogBtn.Add_Click({
	Write-LogTimestamped "=== Recent Commits ==="
	Run-Tool -FileName "git" -Arguments "log --oneline -10" -WorkingDirectory $projectRoot -ToolName "Git Log"
})

$gitDiffBtn.Add_Click({
	Write-LogTimestamped "=== Staged Changes ==="
	Run-Tool -FileName "git" -Arguments "diff --cached" -WorkingDirectory $projectRoot -ToolName "Git Diff"
})

$tabControl.TabPages.Add($tabGit)

# =============================================================================
# TAB 6: Bridge
# =============================================================================
$tabBridge = New-Object System.Windows.Forms.TabPage
$tabBridge.Text = "Bridge"

$bridgeTitleLabel = New-Object System.Windows.Forms.Label
$bridgeTitleLabel.Text = "AI Development Tools"
$bridgeTitleLabel.Location = New-Object System.Drawing.Point(14, 14)
$bridgeTitleLabel.Size = New-Object System.Drawing.Size(400, 24)
$bridgeTitleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$tabBridge.Controls.Add($bridgeTitleLabel)

$bridgeDescLabel = New-Object System.Windows.Forms.Label
$bridgeDescLabel.Text = "Tools that bridge AI coding assistants with Roblox Studio development."
$bridgeDescLabel.Location = New-Object System.Drawing.Point(14, 40)
$bridgeDescLabel.Size = New-Object System.Drawing.Size(700, 20)
$bridgeDescLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$bridgeDescLabel.ForeColor = [System.Drawing.Color]::DimGray
$tabBridge.Controls.Add($bridgeDescLabel)

$studLabel = New-Object System.Windows.Forms.Label
$studLabel.Text = "Stud.ai"
$studLabel.Location = New-Object System.Drawing.Point(14, 75)
$studLabel.Size = New-Object System.Drawing.Size(100, 22)
$studLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$tabBridge.Controls.Add($studLabel)

$studDescLabel = New-Object System.Windows.Forms.Label
$studDescLabel.Text = "Desktop application that connects AI agents directly to Roblox Studio."
$studDescLabel.Location = New-Object System.Drawing.Point(14, 97)
$studDescLabel.Size = New-Object System.Drawing.Size(500, 40)
$studDescLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$tabBridge.Controls.Add($studDescLabel)

$studLaunchBtn = New-Object System.Windows.Forms.Button
$studLaunchBtn.Text = "Launch Stud.ai"
$studLaunchBtn.Location = New-Object System.Drawing.Point(530, 97)
$studLaunchBtn.Size = New-Object System.Drawing.Size(110, 28)
$studLaunchBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$studLaunchBtn.Enabled = $false
$tabBridge.Controls.Add($studLaunchBtn)

$rbxdevLabel = New-Object System.Windows.Forms.Label
$rbxdevLabel.Text = "rbxdev-ls"
$rbxdevLabel.Location = New-Object System.Drawing.Point(14, 145)
$rbxdevLabel.Size = New-Object System.Drawing.Size(100, 22)
$rbxdevLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$tabBridge.Controls.Add($rbxdevLabel)

$rbxdevDescLabel = New-Object System.Windows.Forms.Label
$rbxdevDescLabel.Text = "MCP server for Cursor and Claude AI coding assistants. Provides Roblox type information."
$rbxdevDescLabel.Location = New-Object System.Drawing.Point(14, 167)
$rbxdevDescLabel.Size = New-Object System.Drawing.Size(700, 40)
$rbxdevDescLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$tabBridge.Controls.Add($rbxdevDescLabel)

$luanoLabel = New-Object System.Windows.Forms.Label
$luanoLabel.Text = "Luano"
$luanoLabel.Location = New-Object System.Drawing.Point(14, 215)
$luanoLabel.Size = New-Object System.Drawing.Size(100, 22)
$luanoLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$tabBridge.Controls.Add($luanoLabel)

$luanoDescLabel = New-Object System.Windows.Forms.Label
$luanoDescLabel.Text = "AI-powered editor for Roblox development. Integrates code editing, asset management, and AI assistance."
$luanoDescLabel.Location = New-Object System.Drawing.Point(14, 237)
$luanoDescLabel.Size = New-Object System.Drawing.Size(700, 40)
$luanoDescLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$tabBridge.Controls.Add($luanoDescLabel)

$tabControl.TabPages.Add($tabBridge)

# =============================================================================
# TAB 7: Health
# =============================================================================
$tabHealth = New-Object System.Windows.Forms.TabPage
$tabHealth.Text = "Health"

$healthPathLabel = New-Object System.Windows.Forms.Label
$healthPathLabel.Text = "Project Directory:"
$healthPathLabel.Location = New-Object System.Drawing.Point(14, 14)
$healthPathLabel.Size = New-Object System.Drawing.Size(110, 22)
$healthPathLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$tabHealth.Controls.Add($healthPathLabel)

$healthPathBox = New-Object System.Windows.Forms.TextBox
$healthPathBox.Text = $projectRoot
$healthPathBox.Location = New-Object System.Drawing.Point(130, 14)
$healthPathBox.Size = New-Object System.Drawing.Size(440, 22)
$healthPathBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$tabHealth.Controls.Add($healthPathBox)

$healthBrowseBtn = New-Object System.Windows.Forms.Button
$healthBrowseBtn.Text = "Browse"
$healthBrowseBtn.Location = New-Object System.Drawing.Point(578, 13)
$healthBrowseBtn.Size = New-Object System.Drawing.Size(80, 26)
$healthBrowseBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$tabHealth.Controls.Add($healthBrowseBtn)

$healthResetBtn = New-Object System.Windows.Forms.Button
$healthResetBtn.Text = "Reset"
$healthResetBtn.Location = New-Object System.Drawing.Point(664, 13)
$healthResetBtn.Size = New-Object System.Drawing.Size(70, 26)
$healthResetBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$tabHealth.Controls.Add($healthResetBtn)

$healthFullBtn = New-Object System.Windows.Forms.Button
$healthFullBtn.Text = ">  Run Full Health Check"
$healthFullBtn.Location = New-Object System.Drawing.Point(14, 50)
$healthFullBtn.Size = New-Object System.Drawing.Size(190, 34)
$healthFullBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$healthFullBtn.BackColor = [System.Drawing.Color]::FromArgb(40, 120, 40)
$healthFullBtn.ForeColor = [System.Drawing.Color]::White
$tabHealth.Controls.Add($healthFullBtn)

$healthQuickBtn = New-Object System.Windows.Forms.Button
$healthQuickBtn.Text = "Quick Verify"
$healthQuickBtn.Location = New-Object System.Drawing.Point(214, 50)
$healthQuickBtn.Size = New-Object System.Drawing.Size(130, 34)
$healthQuickBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$tabHealth.Controls.Add($healthQuickBtn)

$healthResultsBox = New-Object System.Windows.Forms.TextBox
$healthResultsBox.Multiline = $true
$healthResultsBox.ReadOnly = $true
$healthResultsBox.ScrollBars = "Vertical"
$healthResultsBox.Location = New-Object System.Drawing.Point(14, 96)
$healthResultsBox.Size = New-Object System.Drawing.Size(720, 270)
$healthResultsBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$healthResultsBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$healthResultsBox.ForeColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
$healthResultsBox.WordWrap = $false
$tabHealth.Controls.Add($healthResultsBox)

$healthOpenDialog = New-Object System.Windows.Forms.FolderBrowserDialog
$healthOpenDialog.Description = "Select a Rojo project directory"

$healthBrowseBtn.Add_Click({
	$healthOpenDialog.SelectedPath = $healthPathBox.Text
	if ($healthOpenDialog.ShowDialog() -eq "OK") {
		$healthPathBox.Text = $healthOpenDialog.SelectedPath
		$healthResultsBox.Clear()
	}
})

$healthResetBtn.Add_Click({
	$healthPathBox.Text = $projectRoot
	$healthResultsBox.Clear()
})

$healthFullBtn.Add_Click({
	$healthFullBtn.Enabled = $false
	$healthFullBtn.Text = "Running..."
	try {
		Run-HealthCheck -TargetDir $healthPathBox.Text
	} catch {
		Write-HealthResult "[ERROR] Health check failed: $_"
	}
	$healthFullBtn.Text = ">  Run Full Health Check"
	$healthFullBtn.Enabled = $true
})

$healthQuickBtn.Add_Click({
	$healthQuickBtn.Enabled = $false
	$healthQuickBtn.Text = "Running..."
	try {
		Run-HealthCheck -TargetDir $healthPathBox.Text -Quick
	} catch {
		Write-HealthResult "[ERROR] Quick verify failed: $_"
	}
	$healthQuickBtn.Text = "Quick Verify"
	$healthQuickBtn.Enabled = $true
})

$tabControl.TabPages.Add($tabHealth)

# =============================================================================
# SHARED LOG BOX
# =============================================================================
$sharedLogBox = New-Object System.Windows.Forms.TextBox
$sharedLogBox.Multiline = $true
$sharedLogBox.ReadOnly = $true
$sharedLogBox.ScrollBars = "Vertical"
$sharedLogBox.Location = New-Object System.Drawing.Point(6, 400)
$sharedLogBox.Size = New-Object System.Drawing.Size(738, 175)
$sharedLogBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$sharedLogBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$sharedLogBox.ForeColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
$form.Controls.Add($sharedLogBox)

# =============================================================================
# STATUS STRIP
# =============================================================================
$statusStrip = New-Object System.Windows.Forms.StatusStrip
$statusStrip.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
$statusStrip.ForeColor = [System.Drawing.Color]::White

$statusProjectLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusProjectLabel.Text = "Project: $projectRoot"
$statusProjectLabel.Spring = $true
$statusProjectLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$statusProjectLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8)

$statusBarLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusBarLabel.Text = "Port: --"
$statusBarLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$statusBarLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8)

$statusStrip.Items.Add($statusProjectLabel)
$statusStrip.Items.Add($statusBarLabel)
$form.Controls.Add($statusStrip)

# =============================================================================
# TIMER
# =============================================================================
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000

$timer.Add_Tick({
	while ($script:outputQueue.Count -gt 0) {
		$line = $script:outputQueue.Dequeue()
		$sharedLogBox.AppendText("$line`r`n")
	}
	if ($sharedLogBox.Text.Length -gt 0) {
		$sharedLogBox.SelectionStart = $sharedLogBox.Text.Length
		$sharedLogBox.ScrollToCaret()
	}
	Update-Status
})

# =============================================================================
# FORM EVENTS
# =============================================================================
$form.Add_Shown({
	$timer.Start()
	Update-Status
	$script:projectName = Get-ProjectName -Dir $projectRoot
	$form.Text = "Studio Bridge - $script:projectName"
	Write-LogTimestamped "=== Studio Bridge v1.0 ==="
	Write-LogTimestamped "Project: $projectRoot"
	Write-LogTimestamped "Detected: $script:projectName"

	# If no project was auto-detected, prompt user
	if ($script:projectName -eq "StudioBridge" -or -not (Test-Path (Join-Path -Path $projectRoot -ChildPath "default.project.json"))) {
		Write-LogTimestamped ""
		Write-LogTimestamped "No Rojo project detected. You can:"
		Write-LogTimestamped "  1. Click the Health tab and Browse for your project"
		Write-LogTimestamped "  2. Pass -ProjectDir `"path\to\project`" when launching"
		Write-LogTimestamped "  3. Launch from within a project directory"
	} else {
		Write-LogTimestamped "Ready. Go to Health tab to run checks."
	}
})

# =============================================================================
# LAUNCH
# =============================================================================
[void]$form.ShowDialog()

$timer.Stop()
Cleanup-AllSubscriptions
# Rojo process is deliberately left running when GUI closes.
