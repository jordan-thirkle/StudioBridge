# Studio Bridge

**Universal Rojo project dashboard for Roblox developers.**

A GUI tool that manages Rojo, Wally, Lune, Git, and project health checks — all in one window. Works with any Rojo-based Roblox project.

![GitHub](https://img.shields.io/github/license/jordan-thirkle/StudioBridge)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1+-blue)
![Rojo](https://img.shields.io/badge/Rojo-7.4+-blue?logo=roblox)

---

## Quick Start

### Option 1: Download & Install

```powershell
powershell -ExecutionPolicy Bypass -File "install.ps1"
```

This copies the tools, creates a desktop shortcut, and you're done.

### Option 2: Run directly

```powershell
powershell -ExecutionPolicy Bypass -File "src\studio-bridge.ps1"
```

If no project is detected, the Health tab will prompt you to browse for one.

### Option 3: From a project folder

```powershell
powershell -ExecutionPolicy Bypass -File "src\studio-bridge.ps1" -ProjectDir "D:\Projects\Games\Roblox\MyGame"
```

Or copy `template\studio-bridge.bat` into your project root and double-click.

---

## The 7 Tabs

| Tab | What it does |
|-----|-------------|
| **Health** | Project selector + 16 read-only checks (tools, git, Rojo, sourcemap, packages) |
| **Rojo** | Start/stop `rojo serve` with status indicator |
| **Rojo Tools** | Build project, generate sourcemap |
| **Lune** | Browse and run Lua/Luau scripts |
| **Wally** | Install packages, update sourcemap |
| **Git** | Status, add all, commit, push, pull, log, diff |
| **Bridge** | Info about AI dev tools (Stud.ai, rbxdev-ls, Luano) |

---

## Project Workflows

### I work entirely in Studio

1. Keep making `.rbxl` backups manually (you're doing this right)
2. Before git commit: Open Studio Bridge → **Rojo Tools** → **Build Project**
3. This extracts scripts to the filesystem
4. Then **Git** tab → Status → Add All → Commit → Push

### I use Rojo sync

1. Open Studio Bridge → **Rojo** tab → **Start**
2. In Studio: Rojo plugin → Connect
3. Scripts auto-sync bidirectionally
4. Before commit: **Health** tab → **Run Full Health Check** to verify

### I'm confused / something feels wrong

1. Open Studio Bridge → **Health** tab
2. Browse to your project folder
3. Click **Run Full Health Check**
4. The results tell you exactly what's working and what's broken

---

## Adding Studio Bridge to a New Project

1. Copy `template\studio-bridge.bat` into the project root
2. Edit `STUDIO_BRIDGE_DIR` if your installation is in a different location
3. Double-click `studio-bridge.bat` from the project folder

That's it. The tool auto-detects the project name from `default.project.json`.

---

## Requirements

- **Windows 10/11** (PowerShell 5.1+)
- **Rokit** (recommended) — installs Rojo, StyLua, Selene, Lune, Wally
- **Rojo** — for script sync between filesystem and Studio
- **Git** — for version control

---

## License

MIT — see [LICENSE](LICENSE).

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
