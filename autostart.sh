#!/bin/bash
# Manage syshud login auto-start (per-user LaunchAgent, no admin needed).
# Usage: ./autostart.sh install [back|front]   install + start now (default: back)
#        ./autostart.sh uninstall              stop + remove auto-start
#        ./autostart.sh status                 show agent and process state
set -euo pipefail
cd "$(dirname "$0")"

LABEL="local.syshud"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN="$(pwd)/syshud"
GUI_DOMAIN="gui/$(id -u)"

case "${1:-}" in
install)
    MODE="${2:-back}"
    if [[ "$MODE" != "back" && "$MODE" != "front" ]]; then
        echo "mode must be 'back' or 'front'" >&2; exit 2
    fi
    if [[ ! -x "$BIN" ]]; then
        echo "no ./syshud binary found — run ./build.sh first" >&2; exit 2
    fi
    launchctl bootout "$GUI_DOMAIN/$LABEL" 2>/dev/null || true
    pkill -x syshud 2>/dev/null || true
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
        <string>$MODE</string>
    </array>
    <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
    launchctl bootstrap "$GUI_DOMAIN" "$PLIST"
    echo "Installed: syshud ($MODE mode) is running now and will start at every login."
    ;;
uninstall)
    launchctl bootout "$GUI_DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    pkill -x syshud 2>/dev/null || true
    echo "Removed login auto-start and stopped syshud."
    ;;
status)
    if launchctl print "$GUI_DOMAIN/$LABEL" >/dev/null 2>&1; then
        echo "auto-start: installed ($PLIST)"
    else
        echo "auto-start: not installed"
    fi
    if pgrep -x syshud >/dev/null; then
        echo "syshud: running (pid $(pgrep -x syshud))"
    else
        echo "syshud: not running"
    fi
    ;;
*)
    echo "usage: ./autostart.sh install [back|front] | uninstall | status" >&2
    exit 2
    ;;
esac
