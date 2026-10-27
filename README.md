# Linux Desktop Remote

[![skills.sh](https://skills.sh/b/yangben2019/linux-desktop-remote)](https://skills.sh/yangben2019/linux-desktop-remote)
[![License: MIT](https://img.shields.io/github/license/yangben2019/linux-desktop-remote)](LICENSE)
[![GitHub stars](https://img.shields.io/github/stars/yangben2019/linux-desktop-remote)](https://github.com/yangben2019/linux-desktop-remote/stargazers)

A Claude Code skill that lets Claude operate a **Linux X11 desktop** over SSH — or the local machine — using **AT-SPI semantic UI lookup** plus `xdotool` and ImageMagick. Find widgets by name, invoke their actions without screenshots, type, click, manage windows, and launch applications.

Works with Kylin V4/V10, UOS, and other X11 desktops on **x86_64 and Phytium/ARM64 (aarch64)**.

## Why semantic first?

Most GUI automation guesses pixel coordinates from screenshots. This skill asks the accessibility tree instead:

```bash
scripts/remote.sh ui-find "Home" --role icon
# [0] role=icon name='Home' app='caja' frame='Desktop' xywh=... actions=open,menu

scripts/remote.sh ui-click "Home" --role icon --action open
```

No screenshot, no OCR, no resolution dependency. Coordinates are only a fallback for apps that do not expose AT-SPI (games, some Java/Electron apps), and keyboard shortcuts are preferred wherever possible.

## Features

- **Semantic lookup and actions** — `ui-apps`, `ui-windows`, `ui-tree`, `ui-find`, `ui-focus`, `ui-click`
- **No-screenshot clicking** — invoke the widget's own `open` / `click` / `activate` action
- **Coordinate fallback** — `click`, `move`, `type`, `key` via `xdotool`
- **Window and workspace control** — `windows`, `activate`, `minimize`, `ws`
- **Screenshots when needed** — full screen, desktop-only, or a single window
- **Local or remote** — `REMOTE_HOST=local` controls the current machine without SSH
- **Zero-touch setup** — `ensure` detects architecture, installs missing dependencies (apt or bundled `.deb` for amd64/arm64), enables the accessibility bridge, and deploys the helper
- **Works headless-ish** — SSH into a graphical X11 session and drive it directly

## Requirements

- **X11** on the target (Wayland is not supported; `xdotool` does not work there)
- SSH access from the controller to the target
- Target user that owns the graphical session (or root with access to its `XAUTHORITY`)
- Debian-based package manager for the optional auto-install steps
- For semantic control: `python3-gi`, `gir1.2-atspi-2.0`, and the graphical session's DBUS

## Install

### Option 1 — skills CLI (skills.sh)

```bash
npx skills add yangben2019/linux-desktop-remote
```

### Option 2 — Claude Code plugin marketplace

From inside Claude Code:

```text
/plugin marketplace add yangben2019/linux-desktop-remote
/plugin install linux-desktop-remote@desktop-automation
```

Equivalent CLI:

```bash
claude plugin marketplace add yangben2019/linux-desktop-remote
claude plugin install linux-desktop-remote@desktop-automation
```

### Option 3 — manual

```bash
git clone https://github.com/yangben2019/linux-desktop-remote.git /tmp/ldr
cp -r /tmp/ldr/skills/linux-desktop-remote ~/.claude/skills/
```

## Quick start

```bash
# Connection settings (omit SSHPASS when using SSH keys)
export REMOTE_HOST=192.168.1.50
export REMOTE_USER=alice
export SSHPASS='<password>'
# export REMOTE_XAUTHORITY=/var/run/lightdm/root/:0   # root LightDM sessions

# One-time environment setup (also works with REMOTE_HOST=local)
scripts/remote.sh ensure

# What is accessible?
scripts/remote.sh ui-apps
scripts/remote.sh ui-windows

# Open the Home folder on the desktop by name
scripts/remote.sh ui-find "Home" --role icon
scripts/remote.sh ui-click "Home" --role icon --action open

# Type into a field: focus first, then type
scripts/remote.sh ui-focus "Search" --role entry
scripts/remote.sh type "hello"

# Screenshot for visual verification
scripts/remote.sh shot /tmp/desktop.png
```

`REMOTE_HOST` is required. Set `REMOTE_HOST=local` to operate the machine running Claude Code.

## Command overview

| Command | Purpose |
|---|---|
| `ensure` | Detect architecture; install missing dependencies; enable accessibility |
| `arch` | Show controller/target architecture |
| `ui-apps` | List AT-SPI-accessible applications |
| `ui-windows` | List accessible windows with geometry/state |
| `ui-find "name" [--role ...] [--app ...] [--frame ...]` | Locate widgets by name |
| `ui-focus "name" ...` | Focus a widget/window before typing |
| `ui-click "name" ...` | Invoke a widget action without screenshots |
| `windows`, `active`, `activate`, `minimize`, `ws` | Window and workspace control |
| `click X Y [1-5]`, `move X Y`, `type "text"`, `key ctrl+l` | Raw input via xdotool |
| `shot`, `shot-desktop`, `shot-window` | Screenshots |
| `open "firefox"`, `exec 'command'` | Launch apps / run commands on the target |

See `skills/linux-desktop-remote/SKILL.md` for the full guide and failure-mode playbook.

## How it works

- **`remote.sh`** wraps SSH and three layers:
  1. **AT-SPI** (`atspi_helper.py` via the system Python) for semantic lookup and actions.
  2. **xdotool** for real X11 input events, coordinate clicks, keys, and window control.
  3. **ImageMagick `import`** for screenshots.
- It resolves `DISPLAY`, optional `XAUTHORITY`, and the graphical session's `DBUS_SESSION_BUS_ADDRESS`, which SSH sessions usually lack.
- Bundled `.deb` packages provide offline installation of `xdotool`/`libxdo3`/`sshpass` for x86_64 and ARM64 when apt is unavailable.

## Safety

This skill can control a real desktop. Run it only on machines you are authorized to operate.

- Destructive actions (deleting files, shutdown/reboot, sending messages, changing system settings) must be confirmed by the user.
- Passwords are passed through environment variables, never stored in files.
- `StrictHostKeyChecking=no` is used by default for lab convenience; use `REMOTE_KNOWN_HOSTS` and your SSH keys for stricter setups.

## Limitations

- X11 only.
- AT-SPI coverage depends on the application; self-drawn UIs need coordinate fallback.
- Qt apps must be started with `QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1` to register.
- Restart applications that were started before accessibility was enabled.

## Contributing

Issues and PRs are welcome. Please include the target desktop (Kylin/UOS/other), architecture, and the exact commands and output involved.

## License

[MIT](LICENSE) © 2026 yangben2019
