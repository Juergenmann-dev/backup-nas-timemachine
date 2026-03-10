#!/bin/zsh
#
# Manuelles Time-Machine-Backup starten – gleicher Ablauf und Logging wie automatisch.
# Startet mount_timemachine.sh direkt (ohne Verzögerung). So ist jedes Backup –
# ob automatisch per LaunchAgent oder manuell über dieses Skript – gleich geloggt
# und nutzt Timeouts/Ordnerstruktur.
#
# Nutzung:
#   ~/bin/timemachine-backup-now.sh
# Oder per LaunchAgent (mit 20 s Verzögerung wie beim Login):
#   launchctl start com.user.timemachine-backup
#
# Nach dem Kopieren nach ~/bin: chmod +x ~/bin/timemachine-backup-now.sh

[ -z "$HOME" ] && export HOME=/Users/josh
SKRIPT="${HOME}/bin/mount_timemachine.sh"
[ -x "$SKRIPT" ] && exec "$SKRIPT"
echo "Fehler: $SKRIPT nicht gefunden oder nicht ausführbar." >&2
exit 1
