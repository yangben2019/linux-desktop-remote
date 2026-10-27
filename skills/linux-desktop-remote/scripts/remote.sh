#!/usr/bin/env bash
# Control a Linux X11 desktop over SSH (SSH + xdotool + ImageMagick).
# See ./remote.sh help. Connection settings come from environment variables:
#   REMOTE_HOST    target IP, or "local" to control this machine (required)
#   REMOTE_USER    login user (default: root)
#   SSHPASS        login password (omit to use SSH keys)
#   REMOTE_DISPLAY display (default: :0)
#   REMOTE_XAUTHORITY  X authority file (default: the login user's ~/.Xauthority;
#                      use /var/run/lightdm/root/:0 for root LightDM sessions)
set -euo pipefail

HOST="${REMOTE_HOST:-}"
RUSER="${REMOTE_USER:-root}"
PASS="${SSHPASS:-}"
DISP="${REMOTE_DISPLAY:-:0}"
XAUTH="${REMOTE_XAUTHORITY:-}"
KNOWN="${REMOTE_KNOWN_HOSTS:-$HOME/.ssh/known_hosts_remote}"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
DEB_DIR=""
for d in "$SCRIPT_DIR/debs" "$SCRIPT_DIR/../debs" "$SCRIPT_DIR/../../debs"; do
  if [ -d "$d" ]; then DEB_DIR=$d; break; fi
done

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile="$KNOWN" -o ConnectTimeout=8)

# AT-SPI needs the graphical session's DBUS bus; SSH/non-interactive shells usually lack it.
# Compatible with systemd (/run/user/UID/bus, Kylin V10) and legacy ~/.dbus/session-bus (Kylin V4).
BUS_SNIPPET='if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then for b in "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus" "/run/user/$(id -u)/bus"; do if [ -S "$b" ]; then export DBUS_SESSION_BUS_ADDRESS="unix:path=$b"; break; fi; done; fi; if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then f=$(ls -t "$HOME"/.dbus/session-bus/*-0 2>/dev/null | head -1); [ -n "$f" ] && export DBUS_SESSION_BUS_ADDRESS=$(sed -n "s/^DBUS_SESSION_BUS_ADDRESS=//p" "$f" | tail -1); fi; '
ATSPI_CHECK="/usr/bin/python3 -c 'import gi; gi.require_version(\"Atspi\", \"2.0\"); from gi.repository import Atspi; Atspi.get_desktop(0)'"
REMOTE_HELPER=/tmp/.linux-atspi-helper.py

die() { echo "Error: $*" >&2; exit 1; }
q()   { printf '%q' "$1"; }

arch_of() {
  case "$1" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) echo "$1" ;;
  esac
}
arch_label() {
  case "$1" in
    amd64) echo 'x86_64' ;;
    arm64) echo 'aarch64 (Phytium/ARM64)' ;;
    *) echo "$1" ;;
  esac
}
local_arch() { arch_of "$(uname -m)"; }

ssh_run() {
  if [ "$HOST" = "local" ]; then
    DISPLAY="${DISPLAY:-$DISP}" bash -c "$BUS_SNIPPET $1"
    return
  fi
  local envs="export DISPLAY=$(q "$DISP");"
  if [ -n "$XAUTH" ]; then
    envs="$envs export XAUTHORITY=$(q "$XAUTH");"
  fi
  local cmd="$envs $BUS_SNIPPET $1"
  if [ -n "$PASS" ]; then
    if command -v sshpass >/dev/null 2>&1; then
      SSHPASS="$PASS" sshpass -e ssh "${SSH_OPTS[@]}" "$RUSER@$HOST" "$cmd"
    else
      local ap rc=0
      ap=$(mktemp /tmp/.raskpass.XXXXXX)
      printf '#!/bin/sh\nprintf "%%s\\n" "$SSHPASS"\n' > "$ap"
      chmod 700 "$ap"
      SSH_ASKPASS="$ap" SSHPASS="$PASS" DISPLAY="${DISPLAY:-:0}" \
        setsid -w ssh "${SSH_OPTS[@]}" "$RUSER@$HOST" "$cmd" </dev/null || rc=$?
      rm -f "$ap"
      return $rc
    fi
  else
    ssh "${SSH_OPTS[@]}" "$RUSER@$HOST" "$cmd"
  fi
}

deb_path() {
  local pkg=$1 arch=${2:-$(local_arch)}
  [ -n "$DEB_DIR" ] || return 1
  ls "$DEB_DIR/${pkg}_"*"_${arch}.deb" 2>/dev/null | head -1
}

try_apt_local() {
  local pkgs=$1
  if [ "$(id -u)" -eq 0 ]; then
    DEBIAN_FRONTEND=noninteractive timeout 120 apt-get install -y $pkgs >/dev/null 2>&1
  elif sudo -n true 2>/dev/null; then
    sudo -n env DEBIAN_FRONTEND=noninteractive timeout 120 apt-get install -y $pkgs >/dev/null 2>&1
  else
    return 1
  fi
}

apt_remote() {
  ssh_run "DEBIAN_FRONTEND=noninteractive timeout 120 apt-get install -y $1 >/dev/null 2>&1 || true" || true
}

install_local_deb() {
  local pkg=$1 arch=${2:-$(local_arch)} deb
  deb=$(deb_path "$pkg" "$arch") || { echo "[local] No $arch offline package found for $pkg" >&2; return 1; }
  echo "[local] Installing $pkg ($arch) ..."
  if [ "$(id -u)" -eq 0 ]; then
    dpkg -i "$deb" >/dev/null
  elif sudo -n true 2>/dev/null; then
    sudo -n dpkg -i "$deb" >/dev/null
  else
    echo "[local] No root privileges; run manually: sudo dpkg -i $deb" >&2
    return 1
  fi
}

push_deb() {
  local f=$1 b64
  b64=$(base64 -w0 "$f")
  ssh_run "printf '%s' '$b64' | base64 -d > /tmp/$(basename "$f")"
}

atspi_ok_local() {
  bash -c "$ATSPI_CHECK" >/dev/null 2>&1
}

install_atspi_local() {
  echo "[local] Installing AT-SPI bindings (python3-gi gir1.2-atspi-2.0) ..."
  if [ "$(id -u)" -eq 0 ]; then
    DEBIAN_FRONTEND=noninteractive timeout 120 apt-get install -y python3-gi gir1.2-atspi-2.0 >/dev/null 2>&1 || true
  elif sudo -n true 2>/dev/null; then
    sudo -n env DEBIAN_FRONTEND=noninteractive timeout 120 apt-get install -y python3-gi gir1.2-atspi-2.0 >/dev/null 2>&1 || true
  else
    echo "[local] No root privileges; run manually: sudo apt-get install -y python3-gi gir1.2-atspi-2.0" >&2
  fi
  atspi_ok_local
}

install_atspi_remote() {
  echo "[target] Installing AT-SPI bindings (python3-gi gir1.2-atspi-2.0) ..."
  ssh_run "DEBIAN_FRONTEND=noninteractive timeout 120 apt-get install -y python3-gi gir1.2-atspi-2.0 >/dev/null 2>&1 || true" || true
  ssh_run "$ATSPI_CHECK" >/dev/null 2>&1
}

enable_a11y_local() {
  local val
  if ! command -v gsettings >/dev/null 2>&1; then
    echo "[hint] gsettings not found; enable accessibility manually in system settings" >&2
    return 0
  fi
  if ! gsettings list-schemas 2>/dev/null | grep -qx 'org.gnome.desktop.interface'; then
    echo "[hint] No org.gnome.desktop.interface schema (may happen on UKUI/Kylin V10); enable accessibility manually in system settings" >&2
    return 0
  fi
  val=$(gsettings get org.gnome.desktop.interface toolkit-accessibility 2>/dev/null || echo unknown)
  if [ "$val" = "true" ]; then
    echo "[local] Accessibility bridge already enabled"
  elif gsettings set org.gnome.desktop.interface toolkit-accessibility true 2>/dev/null; then
    echo "[local] Enabled accessibility bridge (toolkit-accessibility)"
  else
    echo "[hint] Failed to enable the accessibility bridge (graphical DBUS required); enable it manually in system settings" >&2
  fi
}

enable_a11y_remote() {
  ssh_run 'if ! command -v gsettings >/dev/null 2>&1; then echo "[hint] gsettings not found on the target; enable accessibility manually in system settings" >&2; exit 0; fi; if ! gsettings list-schemas 2>/dev/null | grep -qx "org.gnome.desktop.interface"; then echo "[hint] No org.gnome.desktop.interface schema on the target (may happen on UKUI/Kylin V10); enable accessibility manually in system settings" >&2; exit 0; fi; v=$(gsettings get org.gnome.desktop.interface toolkit-accessibility 2>/dev/null || echo unknown); if [ "$v" = "true" ]; then echo "[target] Accessibility bridge already enabled"; else gsettings set org.gnome.desktop.interface toolkit-accessibility true >/dev/null 2>&1 && echo "[target] Enabled accessibility bridge (toolkit-accessibility)" || echo "[hint] Failed to enable the accessibility bridge on the target; enable it manually in system settings" >&2; fi'
}

atspi_helper_path() {
  if [ "$HOST" = "local" ]; then
    [ -f "$SCRIPT_DIR/atspi_helper.py" ] || return 1
    printf '%s' "$SCRIPT_DIR/atspi_helper.py"
    return 0
  fi
  local lmd5 rmd5
  lmd5=$(md5sum "$SCRIPT_DIR/atspi_helper.py" | awk '{print $1}')
  rmd5=$(ssh_run "md5sum $REMOTE_HELPER 2>/dev/null | awk '{print \$1}'" 2>/dev/null || true)
  if [ "$lmd5" != "$rmd5" ]; then
    local b64
    b64=$(base64 -w0 "$SCRIPT_DIR/atspi_helper.py")
    ssh_run "printf '%s' '$b64' | base64 -d > $REMOTE_HELPER && chmod 700 $REMOTE_HELPER" >/dev/null || return 1
  fi
  printf '%s' "$REMOTE_HELPER"
}

ui_run() {
  local hp cmd a
  hp=$(atspi_helper_path) || die 'Failed to deploy the AT-SPI helper'
  cmd="/usr/bin/python3 $(q "$hp")"
  for a in "$@"; do cmd="$cmd $(q "$a")"; done
  ssh_run "$cmd"
}

check_atspi() {
  local rc=0 tag count hp
  if [ "$HOST" = "local" ]; then
    tag="local"
    if atspi_ok_local; then
      echo "[$tag] AT-SPI bindings available"
    else
      echo "[$tag] AT-SPI bindings missing; installing"
      install_atspi_local || true
      if atspi_ok_local; then
        echo "[$tag] AT-SPI bindings installed"
      else
        echo "[$tag] Failed to install AT-SPI bindings; run manually: apt-get install -y python3-gi gir1.2-atspi-2.0" >&2
        rc=1
      fi
    fi
    enable_a11y_local || rc=1
  else
    tag="target"
    if ssh_run "$ATSPI_CHECK" >/dev/null 2>&1; then
      echo "[$tag] AT-SPI bindings available"
    else
      echo "[$tag] AT-SPI bindings missing; installing"
      install_atspi_remote || true
      if ssh_run "$ATSPI_CHECK" >/dev/null 2>&1; then
        echo "[$tag] AT-SPI bindings installed"
      else
        echo "[$tag] Failed to install AT-SPI bindings; run manually: apt-get install -y python3-gi gir1.2-atspi-2.0" >&2
        rc=1
      fi
    fi
    enable_a11y_remote || rc=1
  fi
  hp=$(atspi_helper_path) || { echo "[$tag] Failed to deploy the AT-SPI helper" >&2; return 1; }
  count=$(ssh_run "/usr/bin/python3 $(q "$hp") apps 2>/dev/null | wc -l" | tr -d '[:space:]')
  if [ -n "$count" ] && [ "$count" -gt 0 ] 2>/dev/null; then
    echo "[$tag] AT-SPI available; accessible applications: $count"
  else
    echo "[hint] AT-SPI is ready but no accessible applications were found; applications started before accessibility was enabled must be restarted" >&2
  fi
  return $rc
}

ensure_env() {
  local rc=0 p deb files="" larch rarch
  if [ "$HOST" = "local" ]; then
    echo "== Local machine (local mode, no SSH) =="
    larch=$(local_arch)
    echo "[local] Architecture: $(arch_label "$larch")"
    if command -v xdotool >/dev/null 2>&1; then
      echo "[local] xdotool installed: $(xdotool --version)"
    else
      echo "[local] xdotool not installed; trying apt"
      try_apt_local xdotool || true
      if ! command -v xdotool >/dev/null 2>&1; then
        echo "[local] apt unavailable; using bundled offline packages ($(arch_label "$larch"))"
        for p in libxdo3 xdotool; do
          deb=$(deb_path "$p" "$larch") || { echo "[local] No $larch offline package found for $p" >&2; rc=1; continue; }
          if [ "$(id -u)" -eq 0 ]; then
            dpkg -i "$deb" >/dev/null || { echo "[local] Failed to install $p" >&2; rc=1; }
          elif sudo -n true 2>/dev/null; then
            sudo -n dpkg -i "$deb" >/dev/null || { echo "[local] Failed to install $p" >&2; rc=1; }
          else
            echo "[local] No root privileges; run manually: sudo dpkg -i $deb" >&2
            rc=1
          fi
        done
      fi
      if command -v xdotool >/dev/null 2>&1; then
        echo "[local] Installation complete: $(xdotool --version)"
      else
        rc=1
      fi
    fi
    if ! command -v wmctrl >/dev/null 2>&1; then
      echo "[local] wmctrl missing; trying apt"
      try_apt_local wmctrl || true
    fi
    command -v wmctrl >/dev/null 2>&1 || echo "[hint] wmctrl missing; window listing may not work" >&2
    command -v import >/dev/null 2>&1 || echo "[hint] import (ImageMagick) missing; screenshots may not work" >&2
    echo "== AT-SPI semantic control =="
    check_atspi || rc=1
    if [ $rc -eq 0 ]; then
      echo "== Environment ready =="
    else
      echo "== Some steps failed; see the messages above ==" >&2
    fi
    return $rc
  fi
  echo "== Controller =="
  larch=$(local_arch)
  echo "[controller] Architecture: $(arch_label "$larch")"
  if command -v sshpass >/dev/null 2>&1; then
    echo "[controller] sshpass installed"
  else
    echo "[controller] sshpass not installed; trying apt"
    try_apt_local sshpass || true
    if ! command -v sshpass >/dev/null 2>&1; then
      install_local_deb sshpass "$larch" || rc=1
    fi
    if command -v sshpass >/dev/null 2>&1; then
      echo "[controller] sshpass installed"
    fi
  fi

  echo "== Target $RUSER@$HOST =="
  rarch=$(arch_of "$(ssh_run 'uname -m' | tr -d '\r')")
  echo "[target] Architecture: $(arch_label "$rarch")"
  if ssh_run 'command -v xdotool >/dev/null 2>&1'; then
    echo "[target] xdotool installed: $(ssh_run 'xdotool --version')"
  else
    echo "[target] xdotool not installed; trying apt"
    apt_remote xdotool
    if ! ssh_run 'command -v xdotool >/dev/null 2>&1'; then
      echo "[target] apt unavailable; using $(arch_label "$rarch") offline packages"
      for p in libxdo3 xdotool; do
        deb=$(deb_path "$p" "$rarch") || { echo "[target] No $rarch offline package found for $p" >&2; rc=1; continue; }
        if push_deb "$deb"; then
          files="$files /tmp/$(basename "$deb")"
        else
          rc=1
        fi
      done
      if [ -n "$files" ]; then
        ssh_run "dpkg -i $files" || { echo "[target] Installation failed; dependencies may be missing. Run apt-get -f install on the target" >&2; rc=1; }
      fi
    fi
    if ssh_run 'command -v xdotool >/dev/null 2>&1'; then
      echo "[target] Installation complete: $(ssh_run 'xdotool --version')"
    else
      rc=1
    fi
  fi

  if ! ssh_run 'command -v wmctrl >/dev/null 2>&1'; then
    echo "[target] wmctrl missing; trying apt"
    apt_remote wmctrl
  fi
  ssh_run 'command -v wmctrl >/dev/null 2>&1' || echo "[hint] wmctrl missing on the target; window listing may not work" >&2
  ssh_run 'command -v import >/dev/null 2>&1' || echo "[hint] import (ImageMagick) missing on the target; screenshots may not work" >&2

  echo "== AT-SPI semantic control =="
  check_atspi || rc=1

  if [ $rc -eq 0 ]; then
    echo "== Environment ready =="
  else
    echo "== Some steps failed; see the messages above ==" >&2
  fi
  return $rc
}

usage() {
  cat <<'EOF'
Linux remote desktop control utility

Usage: ./remote.sh <command> [arguments]

Connection (environment variables):
  REMOTE_HOST=192.168.1.50  REMOTE_USER=root  SSHPASS=password
  REMOTE_HOST is required. Omit SSHPASS when using SSH keys.
  REMOTE_HOST=local controls this machine directly (no SSH or password).
  REMOTE_XAUTHORITY overrides the X authority file (default: ~/.Xauthority;
  root LightDM sessions often need /var/run/lightdm/root/:0).

Commands:
  ensure                     Detect architecture and install sshpass, xdotool, and AT-SPI bindings; enable accessibility
  arch                       Show controller/target architecture (x86_64 / Phytium ARM64)
  wake                       Unlock/wake the screen (run when screenshots are black)
  shot [file]                Full-screen screenshot (default: screenshot-TIME.png)
  shot-desktop [file]        Desktop window only; avoids browser overlays
  shot-window <name> [file]  Screenshot a specific window
  windows                    List all X windows
  ui-apps                    List accessible applications (AT-SPI, no screenshot)
  ui-windows                 List accessible windows with geometry/state
  ui-tree [app] [--depth N]  Print the widget tree
  ui-find "name" [options]   Find widgets by name; prints geometry/actions
  ui-focus "name" [options]  Focus a widget/window so later type/key lands correctly
  ui-click "name" [options]  Invoke a widget's action (preferred over coordinate clicks)
    options: --role icon --app caja --frame root --contains
             --action click --index N
  active                     Name of the active window
  location                   Current mouse position
  move X Y                   Move the mouse
  click X Y [button 1-5]     Move and click (1=left, 3=right)
  type "text"                Type text
  key ctrl+alt+t             Send a key press / shortcut
  activate <window>          Activate a window
  minimize <window>          Minimize a window
  ws <0-3>                   Switch workspace (does not close programs)
  open "firefox"             Launch a program in the background (arguments allowed)
  exec 'command'             Run an arbitrary command on the target
  help                       Show this help
EOF
}

STAMP() { date +%Y%m%d-%H%M%S; }

case "${1:-}" in
  help|-h|--help) usage; exit 0 ;;
esac
if [ -z "$HOST" ]; then
  die 'REMOTE_HOST is required (set REMOTE_HOST=local to control this machine).'
fi

case "${1:-}" in
  ensure)
    ensure_env
    ;;
  arch)
    la=$(local_arch)
    echo "Controller: $(arch_label "$la")"
    if [ "$HOST" = "local" ]; then
      echo "Target: local ($(arch_label "$la"))"
    else
      ra=$(arch_of "$(ssh_run 'uname -m' | tr -d '\r')")
      echo "Target: $(arch_label "$ra")"
    fi
    ;;
  wake)
    ssh_run 'mate-screensaver-command -d >/dev/null 2>&1 || true; xset s reset >/dev/null 2>&1 || true; xset dpms force on >/dev/null 2>&1 || true; S=$(loginctl list-sessions --no-legend 2>/dev/null | awk "NR==1{print \$1}"); [ -n "$S" ] && loginctl unlock-session "$S" >/dev/null 2>&1 || true; echo awake'
    ;;
  shot)
    out=${2:-screenshot-$(STAMP).png}
    ssh_run 'import -window root png:-' > "$out"
    if [ "$(stat -c%s "$out")" -lt 1024 ]; then
      echo "Warning: screenshot may be all black (locked or screen off); run ./remote.sh wake and retry" >&2
    fi
    echo "Saved: $out"
    ;;
  shot-desktop)
    out=${2:-desktop-$(STAMP).png}
    ssh_run 'D=$(xdotool search --classname desktop_window | head -1); [ -n "$D" ] || { echo "Cannot find the desktop window" >&2; exit 1; }; import -window "$D" png:-' > "$out"
    echo "Saved: $out"
    ;;
  shot-window)
    [ $# -ge 2 ] || die 'usage: ./remote.sh shot-window <window-name> [output-file]'
    name=$2
    out=${3:-window-$(STAMP).png}
    ssh_run "W=\$(xdotool search --name $(q "$name") | head -1); [ -n \"\$W\" ] || { echo 'Window not found' >&2; exit 1; }; import -window \"\$W\" png:-" > "$out"
    echo "Saved: $out"
    ;;
  windows)
    ssh_run 'wmctrl -l'
    ;;
  ui-apps)
    ui_run apps
    ;;
  ui-windows)
    ui_run frames
    ;;
  ui-tree)
    shift
    ui_run tree "$@"
    ;;
  ui-find)
    shift
    [ $# -ge 1 ] || die 'usage: ./remote.sh ui-find "name" [--role ...] [--app ...] [--frame ...]'
    ui_run find "$@"
    ;;
  ui-focus)
    shift
    [ $# -ge 1 ] || die 'usage: ./remote.sh ui-focus "name" [--role ...] [--app ...] [--frame ...]'
    ui_run focus "$@"
    ;;
  ui-click)
    shift
    [ $# -ge 1 ] || die 'usage: ./remote.sh ui-click "name" [--role ...] [--app ...] [--frame ...] [--action ...]'
    ui_run click "$@"
    ;;
  active)
    ssh_run 'xdotool getactivewindow getwindowname'
    ;;
  location)
    ssh_run 'xdotool getmouselocation'
    ;;
  move)
    [ $# -ge 3 ] || die 'usage: ./remote.sh move X Y'
    [[ $2 =~ ^[0-9]+$ && $3 =~ ^[0-9]+$ ]] || die 'coordinates must be integers'
    ssh_run "xdotool mousemove $2 $3"
    ;;
  click)
    [ $# -ge 3 ] || die 'usage: ./remote.sh click X Y [button 1-5]'
    btn=${4:-1}
    [[ $2 =~ ^[0-9]+$ && $3 =~ ^[0-9]+$ && $btn =~ ^[1-5]$ ]] || die 'invalid arguments'
    ssh_run "xdotool mousemove $2 $3 click $btn"
    ;;
  type)
    [ $# -ge 2 ] || die 'usage: ./remote.sh type "text"'
    ssh_run "printf '%s' $(q "$2") > /tmp/.rtext && xdotool type --clearmodifiers --delay 50 --file /tmp/.rtext; rm -f /tmp/.rtext"
    ;;
  key)
    [ $# -ge 2 ] || die 'usage: ./remote.sh key ctrl+alt+t'
    ssh_run "xdotool key -- $(q "$2")"
    ;;
  activate)
    [ $# -ge 2 ] || die 'usage: ./remote.sh activate <window-name>'
    ssh_run "W=\$(xdotool search --name $(q "$2") | head -1); [ -n \"\$W\" ] || { echo 'Window not found' >&2; exit 1; }; xdotool windowactivate --sync \"\$W\"; sleep 0.5"
    ;;
  minimize)
    [ $# -ge 2 ] || die 'usage: ./remote.sh minimize <window-name>'
    ssh_run "W=\$(xdotool search --name $(q "$2") | head -1); [ -n \"\$W\" ] || { echo 'Window not found' >&2; exit 1; }; xdotool windowminimize \"\$W\""
    ;;
  ws)
    [ $# -ge 2 ] && [[ $2 =~ ^[0-3]$ ]] || die 'usage: ./remote.sh ws <0-3>'
    ssh_run "wmctrl -s $2"
    ;;
  open)
    [ $# -ge 2 ] || die 'usage: ./remote.sh open "firefox"'
    ssh_run "setsid bash -c $(q "$2") >/dev/null 2>&1 < /dev/null &"
    ;;
  exec)
    [ $# -ge 2 ] || die "usage: ./remote.sh exec 'command'"
    shift
    ssh_run "$*"
    ;;
  *)
    usage
    exit 1
    ;;
esac
