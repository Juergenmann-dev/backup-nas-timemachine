#!/bin/zsh
# LaunchAgents neu laden (z.B. nach Änderung der Plists).
# Setzt zuerst die Ausführungsrechte der Skripte (verhindert „permission denied“), dann entladen/laden.

set -e
AGENTS_DIR="$HOME/Library/LaunchAgents"
BIN_DIR="${HOME}/bin"
DOMAIN="gui/$(id -u)"

echo "Setze Ausführungsrechte für Time-Machine-Skripte..."
chmod +x "$BIN_DIR/mount_timemachine.sh" "$BIN_DIR/timemachine-backup-launch.sh" "$BIN_DIR/timemachine-backup-watcher.sh" 2>/dev/null || true

echo "Entlade vorhandene Jobs..."
launchctl bootout "$DOMAIN" "$AGENTS_DIR/com.user.timemachine-backup.plist" 2>/dev/null || true
launchctl bootout "$DOMAIN" "$AGENTS_DIR/com.user.timemachine-backup-watcher.plist" 2>/dev/null || true

echo "Kopiere Plists..."
cp "$HOME/bin/com.user.timemachine-backup.plist" "$AGENTS_DIR/"
cp "$HOME/bin/com.user.timemachine-backup-watcher.plist" "$AGENTS_DIR/"

echo "Lade Jobs (bootstrap für neueres macOS)..."
launchctl bootstrap "$DOMAIN" "$AGENTS_DIR/com.user.timemachine-backup.plist"
launchctl bootstrap "$DOMAIN" "$AGENTS_DIR/com.user.timemachine-backup-watcher.plist"

echo "Fertig. Status:"
launchctl list | grep timemachine
