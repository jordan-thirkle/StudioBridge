param(
	[string]$ProjectDir = ""
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$projectRoot = if ($ProjectDir) { $ProjectDir } else { Split-Path -Parent $PSCommandPath }
if (-not $projectRoot) { $projectRoot = Get-Location }

$script:rojoProcess = $null
$script:outputQueue = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
$script:portNumber = "--"
$script:eventSubscribers = @()

$form = New-Object System.Windows.Forms.Form
$form.Text = "Rojo Control"
$form.Size = New-Object System.Drawing.Size(560, 480)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false

$statusPanel = New-Object System.Windows.Forms.Panel
$statusPanel.Size = New-Object System.Drawing.Size(18, 18)
$statusPanel.Location = New-Object System.Drawing.Point(14, 14)
$statusPanel.BackColor = [System.Drawing.Color]::Red
$form.Controls.Add($statusPanel)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "Stopped"
$statusLabel.Location = New-Object System.Drawing.Point(40, 12)
$statusLabel.Size = New-Object System.Drawing.Size(200, 20)
$statusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($statusLabel)

$portLabel = New-Object System.Windows.Forms.Label
$portLabel.Text = "Port: --"
$portLabel.Location = New-Object System.Drawing.Point(40, 32)
$portLabel.Size = New-Object System.Drawing.Size(150, 20)
$portLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8)
$form.Controls.Add($portLabel)

$projectLabel = New-Object System.Windows.Forms.Label
$projectLabel.Text = "Project: $projectRoot"
$projectLabel.Location = New-Object System.Drawing.Point(14, 56)
$projectLabel.Size = New-Object System.Drawing.Size(520, 20)
$projectLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8)
$projectLabel.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($projectLabel)

$startBtn = New-Object System.Windows.Forms.Button
$startBtn.Text = "Start"
$startBtn.Location = New-Object System.Drawing.Point(14, 84)
$startBtn.Size = New-Object System.Drawing.Size(90, 30)
$startBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.Controls.Add($startBtn)

$stopBtn = New-Object System.Windows.Forms.Button
$stopBtn.Text = "Stop"
$stopBtn.Location = New-Object System.Drawing.Point(112, 84)
$stopBtn.Size = New-Object System.Drawing.Size(90, 30)
$stopBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$stopBtn.Enabled = $false
$form.Controls.Add($stopBtn)

$restartBtn = New-Object System.Windows.Forms.Button
$restartBtn.Text = "Restart"
$restartBtn.Location = New-Object System.Drawing.Point(210, 84)
$restartBtn.Size = New-Object System.Drawing.Size(90, 30)
$restartBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$restartBtn.Enabled = $false
$form.Controls.Add($restartBtn)

$clearBtn = New-Object System.Windows.Forms.Button
$clearBtn.Text = "Clear Log"
$clearBtn.Location = New-Object System.Drawing.Point(450, 84)
$clearBtn.Size = New-Object System.Drawing.Size(80, 30)
$clearBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.Controls.Add($clearBtn)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = "Vertical"
$logBox.Location = New-Object System.Drawing.Point(14, 124)
$logBox.Size = New-Object System.Drawing.Size(516, 310)
$logBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$logBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$logBox.ForeColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
$form.Controls.Add($logBox)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500

function Write-Log {
	param([string]$text)
	$logBox.AppendText("$text`r`n")
	$logBox.SelectionStart = $logBox.Text.Length
	$logBox.ScrollToCaret()
}

function Update-Status {
	$running = $false
	$port = "--"
	if ($script:rojoProcess -and !$script:rojoProcess.HasExited) {
		$running = $true
		$port = $script:portNumber
	} else {
		$orphans = Get-Process -Name "rojo" -ErrorAction SilentlyContinue
		if ($orphans) { $running = $true; $port = "34872 (orphan)" }
	}
	if ($running) {
		$statusPanel.BackColor = [System.Drawing.Color]::LimeGreen
		$statusLabel.Text = "Running"
		$startBtn.Enabled = $false; $stopBtn.Enabled = $true; $restartBtn.Enabled = $true
	} else {
		$statusPanel.BackColor = [System.Drawing.Color]::Red
		$statusLabel.Text = "Stopped"
		$startBtn.Enabled = $true; $stopBtn.Enabled = $false; $restartBtn.Enabled = $false
	}
	$portLabel.Text = "Port: $port"
}

function Start-Rojo {
	if ($script:rojoProcess -and !$script:rojoProcess.HasExited) { Write-Log "Rojo is already running."; return }
	$cmd = Get-Command "rojo" -ErrorAction SilentlyContinue
	if (-not $cmd) { Write-Log "[ERROR] rojo not found in PATH."; return }
	Write-Log "Starting rojo serve..."
	$psi = New-Object System.Diagnostics.ProcessStartInfo
	$psi.FileName = "rojo"; $psi.Arguments = "serve"
	$psi.WorkingDirectory = $projectRoot
	$psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true
	$psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
	$psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
	$psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
	$proc = New-Object System.Diagnostics.Process
	$proc.StartInfo = $psi
	try {
		$proc.Start() | Out-Null; $proc.BeginOutputReadLine(); $proc.BeginErrorReadLine()
		$outSub = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action {
			$data = $Event.SourceEventArgs.Data
			if ($data) { $script:outputQueue.Enqueue($data); if ($data -match "Port:\s+(\d+)") { $script:portNumber = $matches[1] } }
		}
		$errSub = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -Action {
			$data = $Event.SourceEventArgs.Data
			if ($data) { $script:outputQueue.Enqueue("[ERR] $data") }
		}
		$script:eventSubscribers = @($outSub, $errSub)
		$script:rojoProcess = $proc
		Write-Log "Rojo serve started (PID: $($proc.Id))"
		Update-Status
	} catch { Write-Log "[ERROR] Failed to start: $_" }
}

function Stop-Rojo {
	Write-Log "Stopping rojo serve..."
	if ($script:rojoProcess -and !$script:rojoProcess.HasExited) {
		try { $script:rojoProcess.Kill(); $script:rojoProcess.WaitForExit(3000) } catch {}
		$script:rojoProcess.Dispose(); $script:rojoProcess = $null; $script:portNumber = "--"
	}
	foreach ($sub in $script:eventSubscribers) { Unregister-Event -SubscriptionId $sub.Id -ErrorAction SilentlyContinue }
	$script:eventSubscribers = @()
	foreach ($p in (Get-Process -Name "rojo" -ErrorAction SilentlyContinue)) { try { $p.Kill(); $p.WaitForExit(2000) } catch {} }
	Write-Log "Rojo stopped."; Update-Status
}

$startBtn.Add_Click({ $startBtn.Enabled = $false; Start-Rojo })
$stopBtn.Add_Click({ Stop-Rojo })
$restartBtn.Add_Click({ $restartBtn.Enabled = $false; Stop-Rojo; Start-Sleep -Milliseconds 800; Start-Rojo })
$clearBtn.Add_Click({ $logBox.Clear() })

$timer.Add_Tick({
	while ($script:outputQueue.Count -gt 0) { $line = $script:outputQueue.Dequeue(); $logBox.AppendText("$line`r`n") }
	if ($logBox.Text.Length -gt 0) { $logBox.SelectionStart = $logBox.Text.Length; $logBox.ScrollToCaret() }
	Update-Status
})

$form.Add_Shown({
	$timer.Start(); Update-Status
	Write-Log "=== Rojo Control ==="; Write-Log "Project: $projectRoot"
	Write-Log "Click 'Start' to launch rojo serve."
})

[void]$form.ShowDialog()
$timer.Stop()
foreach ($sub in $script:eventSubscribers) { Unregister-Event -SubscriptionId $sub.Id -ErrorAction SilentlyContinue }
