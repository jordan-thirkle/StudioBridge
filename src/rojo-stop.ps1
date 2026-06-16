# Kill any running Rojo processes (orphans from studio-bridge or rojo-control)
$orphans = Get-Process -Name "rojo" -ErrorAction SilentlyContinue
if ($orphans) {
	foreach ($p in $orphans) {
		try {
			$p.Kill()
			$p.WaitForExit(2000)
			Write-Host "Killed rojo (PID: $($p.Id))"
		} catch {
			Write-Host "Failed to kill rojo (PID: $($p.Id)): $_"
		}
	}
} else {
	Write-Host "No running Rojo processes found."
}
