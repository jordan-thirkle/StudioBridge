# Tauri Migration Architecture

## When to Migrate

After Phase 1 (PowerShell) is proven in daily use and at least one of:
- Health check heuristics are validated (no false positives)
- WinForms limitations are actively hurting UX
- External user adoption justifies the investment
- Cross-platform is required

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Tauri Desktop App (Rust + WebView)                         │
│                                                             │
│  ┌────────────────────┐  ┌──────────────────────────────┐  │
│  │ UI Layer           │  │ Rust Backend                 │  │
│  │                    │  │                              │  │
│  │ React + Tailwind   │  │ - Process management         │  │
│  │                    │  │ - Spawn rojo, git, wally     │  │
│  │ Components:        │  │ - Parse JSON output          │  │
│  │  - HealthDashboard │  │ - File system watcher        │  │
│  │  - RojoControls    │  │ - Update checker             │  │
│  │  - GitPanel        │  │                              │  │
│  │  - LuneRunner      │  │  Calls via:                  │  │
│  │  - WallyManager    │  │  powershell.exe (Windows)     │  │
│  │  - ProjectPicker   │  │  or pwsh (macOS/Linux)       │  │
│  └────────────────────┘  └──────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## JSON Pipe Contract

The Rust backend calls PowerShell with:

```rust
powershell -NoProfile -Command "
    Import-Module 'HealthEngine.psm1';
    Run-HealthCheck -TargetDir 'C:\path' | ConvertTo-Json -Depth 5
"
```

Returns structured JSON (see `HEALTH_CHECKS.md`). This is the ONLY interface between Rust and the health engine — the engine never changes, only the UI wrapping it.

## Process Management

```rust
// Safety-critical: timeouts, error streams, working directory
let mut cmd = Command::new("powershell");
cmd.args(&["-NoProfile", "-Command", &script])
   .current_dir(&project_dir)
   .timeout(Duration::from_secs(30));

// Handle:
// - Process timeout (kill after 30s)
// - stderr capture (rojo, git errors)
// - UTF-8 encoding for output
```

## UI Component Tree (React)

```
<App>
  <TitleBar />
  <TabBar>
    <Tab name="Health">
      <HealthDashboard projectDir={dir}>
        <StatusCard status="OK" check="Project" />
        <StatusCard status="WARN" check="Sourcemap" onClick={fix} />
        <SummaryBar pass={12} warn={1} fail={0} />
      </HealthDashboard>
    </Tab>
    <Tab name="Rojo">
      <RojoControls onStart={startRojo} onStop={stopRojo} />
    </Tab>
    <!-- ... -->
  </TabBar>
</App>
```

## Distribution

- Single `.msi` installer (Windows) / `.dmg` (macOS) via Tauri bundler
- Auto-update via GitHub Releases (`tauri-plugin-updater`)
- No telemetry, no analytics
- Portable mode: copy the binary, runs without install

## Migration Path

1. Keep PowerShell `HealthEngine.psm1` as-is (no changes)
2. Build Tauri app with Rust backend calling PowerShell via JSON pipe
3. Build React UI matching the WinForms layout
4. Test in parallel with WinForms version
5. When stable, make Tauri version the default download
6. PowerShell version remains as "lite" alternative for CLI use

## Non-Goals (v1 Tauri)

- Replacing the health engine in a new language
- Real-time file watching
- Built-in code editor
- Plugin system

These can come in v2. The first Tauri version should be a 1:1 port of the WinForms functionality.
