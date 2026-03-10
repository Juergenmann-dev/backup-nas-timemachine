#!/bin/zsh
#
# Watcher: Erkennt Backups, die vom System gestartet wurden (z. B. „Jetzt sichern“),
# und schreibt dieselbe Log-Struktur (Jahr/Monat/KW/Tag) – damit jedes Backup geloggt wird.
# Wird alle 10 s vom LaunchAgent aufgerufen. Wenn ein Backup läuft und nicht unser
# Hauptskript (mount_timemachine.sh) dahintersteckt, starten wir das Logging dafür.
#
# Einmal einrichten – Rest erledigt das Skript (geplant alle 2 h + „Jetzt sichern“).
#

[ -z "$HOME" ] && export HOME=/Users/josh
TMUTIL="/usr/bin/tmutil"
LOG_BASE="${HOME}/Documents/Timemachine_logs"
OUR_RUN_LOCK="$LOG_BASE/.backup_our_run"
WATCHER_LOGGING="$LOG_BASE/.watcher_logging"

# Stale Locks aufräumen: Lock von unserem Skript älter als 2 h? Dann entfernen (abgestürzter Lauf)
if [ -f "$OUR_RUN_LOCK" ]; then
  age=$(($(date +%s) - $(stat -f %m "$OUR_RUN_LOCK" 2>/dev/null || echo 0)))
  [ "$age" -gt 7200 ] 2>/dev/null && rm -f "$OUR_RUN_LOCK" 2>/dev/null
fi
# Watcher-Lock existiert, aber Prozess läuft nicht mehr? Dann Lock entfernen
if [ -f "$WATCHER_LOGGING" ]; then
  pid=$(head -1 "$WATCHER_LOGGING" 2>/dev/null)
  [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null && rm -f "$WATCHER_LOGGING" 2>/dev/null
fi

# Nur prüfen, wenn kein Backup läuft – sofort exit (tmutil liefert z. B. "Running = 1;")
"$TMUTIL" status 2>/dev/null | grep -q 'Running = 1' || exit 0
# Unser Skript hat dieses Backup gestartet? Dann nichts tun
[ -f "$OUR_RUN_LOCK" ] && exit 0
# Wir loggen bereits ein systemgestartetes Backup
[ -f "$WATCHER_LOGGING" ] && exit 0

# Log-Basis muss existieren und beschreibbar sein (LaunchAgent-Kontext)
mkdir -p "$LOG_BASE" 2>/dev/null
[ ! -w "$LOG_BASE" ] 2>/dev/null && exit 0

# Debug: letzte Erkennung notieren (zum Prüfen, ob Watcher überhaupt auslöst)
echo "$(date '+%Y-%m-%d %H:%M:%S') Backup erkannt, starte Logging" >> /tmp/tm_watcher_last_seen.log 2>/dev/null

# System-Backup erkannt – mit nohup entkoppeln, damit Kindprozess nach Script-Ende weiterläuft
nohup env HOME="$HOME" LOG_BASE="$LOG_BASE" /bin/zsh -c '
  HOME="${HOME:-/Users/josh}"
  LOG_BASE="${LOG_BASE:-$HOME/Documents/Timemachine_logs}"
  TMUTIL="/usr/bin/tmutil"
  LOG_BASE="${HOME}/Documents/Timemachine_logs"
  WATCHER_LOGGING="${LOG_BASE}/.watcher_logging"
  echo $$ > "$WATCHER_LOGGING" 2>/dev/null
  LOG_TIMESTAMP=$(date "+%Y-%m-%d_%H-%M-%S")
  LOG_DATE=$(date "+%Y-%m-%d")
  LOG_YEAR=$(date "+%Y")
  LOG_MONTH=$(date "+%Y-%m")
  LOG_KW="KW$(date "+%V")"
  LOG_TECH_DIR="$LOG_BASE/Technical/$LOG_YEAR/$LOG_MONTH/$LOG_KW/$LOG_DATE"
  LOG_USER_DIR="$LOG_BASE/Benutzer/$LOG_YEAR/$LOG_MONTH/$LOG_KW/$LOG_DATE"
  mkdir -p "$LOG_TECH_DIR" "$LOG_USER_DIR"
  TECHNICAL_LOG="$LOG_TECH_DIR/${LOG_TIMESTAMP}_watcher.log"
  USER_LOG="$LOG_USER_DIR/${LOG_TIMESTAMP}_watcher.log"
  log_tech() { echo "[$(date "+%Y-%m-%d %H:%M:%S")] $1" >> "$TECHNICAL_LOG"; }
  log_usr() { echo "[$(date "+%Y-%m-%d %H:%M:%S")] $1" >> "$USER_LOG"; }
  log_tech "Watcher: Backup vom System gestartet (z. B. Jetzt sichern) – Fortschritt wird geloggt"
  log_usr "Backup wurde über das System gestartet (z. B. Jetzt sichern). Fortschritt wird aufgezeichnet."
  CHECK_interval=30
  while "$TMUTIL" status 2>/dev/null | grep -q "Running = 1"; do
    STATUS=$("$TMUTIL" status 2>/dev/null | LC_ALL=C tr -cd "\n\t\40-\176")
    PERCENT=$(printf "%s" "$STATUS" | awk -F= "/Percent/ && /=/ {gsub(/[\"; ]/,\"\",\$2); gsub(/,/,\".\",\$2); v=\$2+0; if (v>0 && v<=1) p=v*100; else if (v>1 && v<=100) p=v; else p=0; if (p>=0) print int(p)}" | sort -n | tail -1)
    PHASE=$(printf "%s" "$STATUS" | awk -F= "/BackupPhase/ {gsub(/[\"; ]/,\"\",\$2); print \$2}" | tr -cd "A-Za-z")
    log_tech "Fortschritt: ${PERCENT:-?}% Phase=$PHASE"
    sleep $CHECK_interval
  done
  log_tech "Watcher: Backup beendet (vom System gestartet)"
  log_usr "Backup abgeschlossen (wurde über das System gestartet)."
  log_tech "========== Time Machine Backup-Lauf beendet (vom System gestartet, z. B. Jetzt sichern) =========="
  log_usr "========== Ende =========="
  rm -f "$WATCHER_LOGGING" 2>/dev/null
' >>/dev/null 2>&1 &
exit 0
