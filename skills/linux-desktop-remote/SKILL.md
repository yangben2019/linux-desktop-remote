---
name: linux-desktop-remote
description: Control a remote or local Linux X11 desktop over SSH with AT-SPI semantic UI lookup plus xdotool and ImageMagick: locate and click widgets by name (no screenshots needed), take screenshots, type text, manage windows, and launch applications. Use when asked to open apps, click buttons, type into fields, inspect the desktop, or automate GUI workflows on Kylin/UOS or any X11 Linux machine (set REMOTE_HOST=local to operate the current machine).
---

# Linux Remote Desktop Control

Operate an X11 desktop on a remote machine over SSH. Everything goes through `scripts/remote.sh`, which wraps `xdotool` and ImageMagick `import` (plus AT-SPI for semantic control).

## Prerequisites

- The controller can SSH to the target; the target runs an **X11** desktop with `xdotool`, `import`, and `wmctrl` (the setup command installs what is missing).
- Works with Kylin V4/V10, UOS, and other X11 desktops; controller and target may be **x86_64 or Phytium/ARM64 (aarch64)**. `ensure` detects both architectures and picks apt or the matching offline package in `debs/`.
- Semantic control needs the AT-SPI bindings (`python3-gi` + `gir1.2-atspi-2.0`) and the graphical session's DBUS. Kylin/UOS normally ship these; `ensure` detects and installs what is missing.
- Connection settings come from environment variables (do not put passwords in your shell history; use `read -s SSHPASS` or have the user export it):

```bash
export REMOTE_HOST=192.168.1.50
export REMOTE_USER=alice
export SSHPASS='<password>'                 # omit when SSH keys are configured
export REMOTE_DISPLAY=:0
# REMOTE_XAUTHORITY is optional; root LightDM sessions usually need /var/run/lightdm/root/:0
# export REMOTE_XAUTHORITY=/var/run/lightdm/root/:0
```

## Target selection: user-provided values always win

- **`REMOTE_HOST` is required**; the script exits with a clear error if it is unset. Never guess a target.
- If the user gives a target **IP / username / password** in the current conversation, use those for all subsequent operations.
- Environment variables do not persist between Bash calls, so prefix **every** `remote.sh` invocation:

  ```bash
  REMOTE_HOST=1.2.3.4 REMOTE_USER=alice SSHPASS='<password>' scripts/remote.sh shot
  ```

- Never write passwords into files, scripts, or screenshots. Omit `SSHPASS` when using SSH keys.
- If the user gives only an IP without a username or password, ask; do not guess.
- **Operating the local machine**: with `REMOTE_HOST=local` the script skips SSH and runs `xdotool`/`import` locally; no username or password needed. Run `ensure` first in this mode too.

## First run: automatic environment setup

Run once before any other operation:
```bash
scripts/remote.sh ensure
```
It checks and installs:
- **Architecture first**: reports the controller's and target's `uname -m`, normalized to `amd64`/`arm64` (also available via the `arch` command);
- `sshpass` on the controller if missing → apt first, then the matching offline package in `debs/`;
- `xdotool` on the target if missing → apt first (ARM64 aware), then the matching offline package in `debs/`;
- AT-SPI bindings on the target (`python3-gi`, `gir1.2-atspi-2.0`) → apt, for the target architecture;
- Enables `toolkit-accessibility` for the graphical session (with fallbacks for the Kylin V4 `org.gnome.desktop.interface` vs. V10/UKUI layouts), and deploys the AT-SPI helper to `/tmp` on the target;
- Checks `import` and `wmctrl`, then prints the number of accessible applications.

Offline packages cover both x86_64 and Phytium ARM64: `xdotool`/`libxdo3`/`sshpass` are split by `_amd64.deb` / `_arm64.deb` under `debs/`, and `ensure` selects by target architecture. There is no offline package for the AT-SPI bindings; that step needs apt on the target.

Installation needs root and network (for apt): the script installs directly as root, otherwise it tries passwordless sudo and prints manual commands on failure. **Explain and get user consent before escalating privileges or running commands manually.** Continue only after `ensure` reports the environment is ready. If it says the environment is ready but no accessible applications were found, restart the target application (GTK apps started before accessibility was enabled do not register with AT-SPI); on V10/UKUI without a `toolkit-accessibility` key, enable accessibility manually in system settings.

## Workflow

1. **Prepare**: `scripts/remote.sh ensure` once per session (prints controller/target architecture).
2. **Locate (AT-SPI first, no screenshots)**: `ui-apps` lists apps, `ui-windows` lists windows, `ui-find "Name"` returns a widget's coordinates and available actions. If a widget can be found by name, do not screenshot it.
3. **Act**: prefer `ui-click "Name"` to invoke the widget's action; when no action exists, use the coordinates from `ui-find` with `click X Y`. Prefer keyboard or commands when possible: `key`, `open`, `activate`.
4. **Verify**: after critical steps, verify with `ui-find` or filesystem commands; use `shot` only for interfaces AT-SPI cannot reach. Never assume success.
5. Close menus/dialogs you opened with `key Escape`.

> Before `type` / `key`, first `ui-focus` the target widget/window or `activate` the target window, and confirm `active` is the intended window — otherwise keystrokes land in the active window (e.g. a terminal).

## Semantic lookup and actions (AT-SPI, no screenshots)

```bash
scripts/remote.sh ui-apps                          # accessible applications
scripts/remote.sh ui-windows                       # accessible windows + geometry/state
scripts/remote.sh ui-find "Home"                   # find widget by name
scripts/remote.sh ui-find "New" --app caja --role menu
scripts/remote.sh ui-click "Home" --role icon      # invoke open: open the Home folder
scripts/remote.sh ui-click "New" --app caja --frame root --role menu
scripts/remote.sh ui-click "Text Document" --app caja --frame root --role "menu item"
scripts/remote.sh ui-focus "New File" --app caja --role "table cell"   # focus, then type
```

- Names match exactly by default, with menu mnemonics tolerated: `"New"` also matches `New(N)`; use `--contains` for substring matching.
- Common filters: `--app caja`, `--frame root`, `--role icon|menu|"menu item"|"push button"|"table cell"`; `--index N` picks the Nth match.
- Actions are tried in order `click → activate → press → open → menu`; override with `--action open`.
- If `ui-click` returns `NOACTION ... x=... y=...` (exit code 3), the widget exposes no action; fall back to coordinates: `click X Y`.
- **When several windows share a name, scope with `--frame`**; use `ui-windows` to confirm titles and geometry. Add `--role icon` for desktop icons so you do not match same-named sidebar entries.
- If a Qt app does not appear in `ui-apps`, restart it with `QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1`.
- Self-drawn interfaces (games, some Java/Electron apps) do not expose AT-SPI; fall back to screenshots or coordinates.

## Desktop icons (Caja / x-caja-desktop)

Prefer AT-SPI for desktop icons: `ui-find "Home" --role icon` / `ui-click "Home" --role icon`; icons expose `open`, so no coordinates needed. Coordinate-based fallbacks when AT-SPI is unavailable (validated 2026-10):

- **Clicking the text label is more reliable than the icon body.** Clicking the icon's top/edge may neither select nor error; the filename text below the icon is the safest target.
- **Confirm selection with a zoomed screenshot** (label turns blue) before continuing. If it is not selected, the coordinate was off: mark the target with an ImageMagick crosshair on the screenshot, zoom in, and compare against `xdotool getdisplaygeometry` (screenshots must be 1:1 with the screen resolution).
- **When coordinates are uncertain, use the keyboard**: click any icon to focus the desktop, then move with `key Down`/`key Right` in the icon grid, confirm the highlight, and `key Return`. Much more reliable than guessing coordinates.
- **A double-click must be one remote command** — two separate `click` calls exceed the double-click threshold because of SSH round-trips:
  ```bash
  scripts/remote.sh exec 'xdotool mousemove X Y && xdotool click --repeat 2 --delay 150 1'
  ```
- After opening, `windows` should show an extra file-manager window (a Caja window title is the directory name, e.g. `root`); confirm contents with `shot`.
- If the mouse seems unresponsive, first `exec 'xdotool mousemove 300 400 click 3'` on empty desktop space: a context menu means the event path works and the problem is the coordinates, not xdotool.

## Screenshots are optional

- **Prefer `ui-find` / `ui-click` by name**; it costs no screenshot tokens and is resolution-independent.
- Screenshots are for two cases only: interfaces AT-SPI cannot reach (self-drawn/no accessibility) and final visual verification.
- Once coordinates and steps are known (fixed button positions, a just-verified flow), use `click` / `type` / `key` directly.
- Prefer coordinate-free methods: `open "firefox"` to launch, `key ctrl+l` for browsers, `activate` to switch windows — faster and more stable than screenshot-and-click.
- Do not click blindly: when the UI may have changed, resolution differs, or it is the first time operating an app, confirm with `ui-find` or a screenshot first. A misclick costs far more than a lookup.

## Command reference

| Command | Description |
|---|---|
| `ensure` | Detect architecture, install sshpass/xdotool/AT-SPI bindings, enable accessibility, deploy helper |
| `arch` | Show controller/target architecture (x86_64 / Phytium ARM64) |
| `wake` | Unlock/wake the screen; run when screenshots are black |
| `shot [file]` | Full-screen screenshot |
| `shot-desktop [file]` | Desktop window only; avoids browser overlays |
| `shot-window <name> [file]` | Screenshot a specific window |
| `windows` | List X windows (ID, workspace, title) |
| `ui-apps` | List AT-SPI-accessible applications |
| `ui-windows` | List accessible windows (title/geometry/state) |
| `ui-tree [app] [--depth N]` | Print the widget tree (debugging) |
| `ui-find "name" [options]` | Find widgets by name; prints geometry/actions |
| `ui-focus "name" [options]` | Focus a widget/window so input goes to the right place |
| `ui-click "name" [options]` | Invoke a widget's action, no screenshot |
| `active` | Name of the active window |
| `location` | Current mouse position |
| `move X Y` | Move the mouse |
| `click X Y [1-5]` | Move and click; 1=left, 3=right |
| `type "text"` | Type text (UTF-8 supported) |
| `key ctrl+alt+t` | Key press / shortcut |
| `activate <window>` | Activate a window (waits 0.5 s) |
| `minimize <window>` | Minimize a window |
| `ws <0-3>` | Switch workspace without closing programs |
| `open "firefox"` | Launch a program in the background, with arguments |
| `exec 'command'` | Run an arbitrary command on the target |

Options for `ui-find` / `ui-focus` / `ui-click`: `--contains`, `--app <app>`, `--frame <window title>`, `--role <role>`; `ui-click` also takes `--action <name>` and `--index N`.

## Key constraints

- **X11 only.** `xdotool` does not work under Wayland (use ydotool/wtype); AT-SPI may work there, but this skill does not cover Wayland.
- **Coordinates follow the current screenshot**; the resolution may not be 1918x918.
- **Clicks hit the topmost window**: minimize (`minimize`) or switch workspace (`ws`) when the target is covered — prefer this over closing programs.
- If a full screenshot is black, run `wake`; if still black, check lock/screen-blanking policy.
- If input is unreliable: `activate`, wait 1 s, then `type`; always `move` before a coordinate click. **Never `type` without confirming the active window.**
- Window titles can collide; `activate` takes the first match. Use `windows` for exact titles or `ui-windows` geometry to disambiguate.
- **Architecture matters**: only `xdotool`/`libxdo3`/`sshpass` offline packages are split into `amd64`/`arm64`; the AT-SPI helper is pure Python. Check both sides with `ensure`/`arch` each session and never mix architectures.
- **Kylin V10**: the DBUS session bus is usually at `/run/user/UID/bus` (V4: `~/.dbus/session-bus/*-0`); the script handles both. If UKUI lacks a `toolkit-accessibility` key, enable accessibility manually in system settings.
- AT-SPI depends on the graphical session's DBUS session bus; `remote.sh` fills in `DBUS_SESSION_BUS_ADDRESS` automatically.
- The helper always runs under `/usr/bin/python3` (the system Python is the one with `gi`; a default `python3` may be 3.10 without it).
- Actions are exposed by the application: desktop icons have `open`, menu items have `click`, list items have `activate`; when there is no action, fall back to the coordinates printed with `NOACTION`.
- Applications started before accessibility was enabled may not register with AT-SPI; restart them. Qt apps need `QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1`.

## Safety

- Destructive operations — deleting files, shutdown/reboot, sending messages, changing system settings — **require explicit user confirmation first**.
- Do not run `rm`, `shutdown`, `reboot`, `apt remove`, etc. unless the user explicitly asks.
- Passwords travel only through environment variables; never write them into scripts or screenshots.
