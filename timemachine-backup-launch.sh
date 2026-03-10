#!/bin/zsh
#
# Wrapper: startet das Time-Machine-Backup-Skript mit Verzögerung.
# Wird vom LaunchAgent aufgerufen (alle 2 h + beim Login).
# Verzögerung gibt dem System Zeit, Netzwerk und Benutzer-Ordner zu laden.
#
# ========== KONFIGURATION ==========
START_VERZOEGERUNG=20
SKRIPT="$HOME/bin/mount_timemachine.sh"
# ===================================

[ -z "$HOME" ] && export HOME=/Users/josh
sleep $START_VERZOEGERUNG
[ -x "$SKRIPT" ] && exec "$SKRIPT"
exit 1
