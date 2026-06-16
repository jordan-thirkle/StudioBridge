# Health Checks — Reference

All checks are implemented in `src/HealthEngine.psm1`.

## Running the Engine

```powershell
Import-Module .\src\HealthEngine.psm1
$results = Run-HealthCheck -TargetDir "C:\path\to\project"
$results | ConvertTo-Json -Depth 5
```

## Output Format

Each check returns a PSObject with these properties:

| Field | Type | Values |
|-------|------|--------|
| `Status` | string | `"OK"`, `"WARN"`, `"FAIL"`, `"INFO"` |
| `Check` | string | Short name of the check (e.g. `"Rojo"`, `"Git status"`) |
| `Detail` | string | Human-readable description of the result |
| `Group` | string | Category: `"Project"`, `"Tools"`, `"Rojo"`, `"Git"` |
| `Valid` | bool? | Whether the tool was found (tool checks only) |
| `Fix` | string? | Optional description of how to fix the issue |
| `FixCommand` | string? | Optional PowerShell command to auto-fix |

## Available Checks

| Check name | Group | What it tests |
|------------|-------|---------------|
| `Project` | Project | `default.project.json` exists and is valid JSON |
| `Toolchain` | Project | `rokit.toml` exists |
| `Luaurc` | Project | `.luaurc` exists |
| `Rojo`, `StyLua`, `Selene`, `Lune`, `Wally` | Tools | Tool is in PATH and returns a version |
| `Rojo serve` | Rojo | Rojo process is running |
| `Git status` | Git | Working tree is clean or has uncommitted files |
| `Git log` | Git | Last commit hash and message |
| `Git` | Git | `.git` directory exists |
| `Sourcemap` | Tools | `sourcemap.json` exists |
| `Packages` | Tools | `Packages/` directory exists |
| `Source files` | Project | `src/` directory exists with file count |

## JSON Contract (for Tauri)

The `-OutputJson` mode (planned for v2) will output:

```json
[
  {
    "Status": "OK",
    "Check": "Project",
    "Detail": "default.project.json valid (\"AuraDepths\")",
    "Group": "Project"
  },
  {
    "Status": "WARN",
    "Check": "Sourcemap",
    "Detail": "sourcemap.json missing",
    "Fix": "Generate it: rojo sourcemap",
    "FixCommand": "rojo sourcemap ...",
    "Group": "Tools"
  }
]
```

Call from Rust:

```rust
use std::process::Command;

let output = Command::new("powershell")
    .args(&["-NoProfile", "-Command",
        "Import-Module HealthEngine.psm1; Run-HealthCheck -TargetDir 'X' | ConvertTo-Json -Depth 5"])
    .output()?;
let results: Vec<HealthCheckResult> = serde_json::from_slice(&output.stdout)?;
```
