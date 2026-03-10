#!/bin/zsh
#
# Time Machine Backup (NAS/Sparsebundle) – automatisch beim Login + alle 2 h; „Jetzt sichern“ wird vom Watcher mitgeloggt
#
# =============================================================================
# WICHTIGE BEFEHLE (z. B. für neuen Mac oder nach Jahren – hier nachschlagen)
# =============================================================================
#
# ---- Stündliche Time-Machine-Backups an/aus ----
# Nur Backups per dieses Skript (alle 2 h + nach Login), NICHT die stündliche Apple-Vorgabe:
#   defaults write com.apple.TimeMachine AutoBackup -bool false
# Wieder stündlich automatisch (Standard von Apple):
#   defaults write com.apple.TimeMachine AutoBackup -bool true
#
# ---- Wo liegt was ----
# Dieses Skript muss in ~/bin liegen, damit es nach Neustart funktioniert (Desktop ist oft noch nicht da).
#   Wichtige Datei:  ~/bin/mount_timemachine.sh
#   Wrapper (20 s Verzögerung):  ~/bin/timemachine-backup-launch.sh
#   Watcher (loggt auch „Jetzt sichern“):  ~/bin/timemachine-backup-watcher.sh  (via eigener LaunchAgent)
# Nach Änderungen an diesem Skript Kopie nach ~/bin aktualisieren. Wichtig: Alle Skripte müssen ausführbar sein (LaunchAgent sonst „permission denied“):
#   cp "/Pfad/zum/mount_timemachine.sh" ~/bin/
#   chmod +x ~/bin/mount_timemachine.sh ~/bin/timemachine-backup-launch.sh ~/bin/timemachine-backup-watcher.sh
#
# ---- LaunchAgents (einmal einrichten – Rest erledigt das Skript) ----
#   Backup geplant (Login + alle 2 h):  com.user.timemachine-backup.plist
#   Watcher (erkennt „Jetzt sichern“ und loggt in dieselbe Ordnerstruktur):  com.user.timemachine-backup-watcher.plist
# Beide Plists nach ~/Library/LaunchAgents/ kopieren, dann:
#   launchctl load ~/Library/LaunchAgents/com.user.timemachine-backup.plist
#   launchctl load ~/Library/LaunchAgents/com.user.timemachine-backup-watcher.plist
# Optional sofort auslösen:  launchctl start com.user.timemachine-backup
# Prüfen:  launchctl list | grep timemachine
#
# ---- Logs (nur auf dem Mac; bei Bedarf selbst woanders ablegen) ----
#   Technisch:  .../Timemachine_logs/Technical/<Jahr>/<YYYY-MM>/KW<Woche>/<YYYY-MM-DD>/
#   Benutzer:   .../Timemachine_logs/Benutzer/<Jahr>/<YYYY-MM>/KW<Woche>/<YYYY-MM-DD>/
#   LaunchAgent Fehler:  ~/Library/Logs/timemachine-backup-stderr.log
#   Logs: von diesem Skript (geplant + manuell start) und vom Watcher („Jetzt sichern“) – gleiche Ordnerstruktur.
#   Pro Lauf wird zusätzlich ein Apple-Log-Ausschnitt gespeichert: Technical/.../Apple_log_<Zeitstempel>.log
#
# ---- Apple Time Machine Logs (Unified Logging – getrennte Befehle) ----
#   Anzeigen (z. B. letzte Stunde):
#     log show --predicate 'subsystem == "com.apple.TimeMachine"' --info --last 1h
#   Live mitschauen:
#     log stream --predicate 'subsystem == "com.apple.TimeMachine"' --info
#
# =============================================================================
#
# Design:
# - Alle Pfade/URLs stehen bewusst im Skript. Kein Nutzer muss etwas konfigurieren;
#   das Skript soll nach dem Einrichten einfach laufen (z. B. per LaunchAgent).
# - mount_smbfs und hdiutil attach laufen mit Timeout; blockieren sie (z. B. NAS aus/Schlaf),
#   wird abgebrochen, Cleanup beendet caffeinate – verhindert, dass der Mac stundenlang „wach hängend“ einfriert.
# - Zwei Logs für zwei Zielgruppen:
#   • User-Log (timemachine_backup.log): verständliche Meldungen für Nutzer ohne
#     Tech-Hintergrund (z. B. "Ziel nicht erreichbar" → Stecker? WLAN? NAS aus?).
#   • Technical-Log (timemachine_technical.log): Fehlercodes und Details für
#     Fehlersuche/Programmierer (z. B. Exit-Codes, Timeout, tmutil/hdiutil-Ausgaben).
#
#
# NAS-Freigaben – Verbindung OHNE Benutzer/Passwort (Gast-Zugriff).
# Nach Reset: Freigaben-Namen mit ./nas_freigaben_finden.sh wdmycloud.local ermitteln.
# NAS 10.20.30.12 – Freigabe TimeMachineBackup (kein Volume1 auf diesem NAS)
NAS_SERVER="10.20.30.12"
NAS_SHARE="TimeMachineBackup"
NAS_SUBFOLDER=""   # Sparsebundle liegt direkt in der Freigabe
SPARSEBUNDLE_NAME="TimeMachine.sparsebundle"

# Als Gast anmelden, ohne Passwort
NAS_USER="guest"
NAS_PASS=""
MOUNTPOINT="/Volumes/TimeMachine"
MAX_RETRIES=10
SLEEP_BETWEEN=5
NETWORK_WAIT_MAX=120   # max. Sekunden warten bis NAS erreichbar (ping), danach trotzdem Mount versuchen
NETWORK_WAIT_INTERVAL=5  # alle 5 s ping versuchen
CHECK_INTERVAL=300  # alle 5 Minuten (vollständiger Status-Check)
QUICK_CHECK_SECONDS=5   # alle 5 s prüfen + Fortschritt (näher an System-UI)
PROGRESS_NOTIFY_INTERVAL=5   # alle 5 s Fortschritt prüfen (näher an System-UI, weniger Differenz Log vs. Anzeige)
MAX_BACKUP_HOURS=6  # Timeout: Backup darf maximal 6 Stunden dauern
# Timeouts für blockierende Aufrufe – verhindern, dass das Skript (und caffeinate) ewig hängen und den Mac einfrieren
SMB_MOUNT_TIMEOUT=90    # Sekunden: mount_smbfs abbbrechen wenn NAS nicht antwortet
HDIUTIL_ATTACH_TIMEOUT=120  # Sekunden: hdiutil attach auf Netzwerk-Volume abbrechen wenn kein Fortschritt
TM_STARTBACKUP_TIMEOUT=90   # Sekunden: tmutil startbackup --auto abbrechen wenn blockiert (Freeze-Schutz)
LOG_SHOW_TIMEOUT=30     # Sekunden: log show (Apple-Log) abbrechen wenn blockiert
LOG_SHOW_EXCERPT_TIMEOUT=45  # Sekunden: log show für save_apple_log_excerpt (längerer Zeitraum)
CLEANUP_STOPBACKUP_TIMEOUT=15   # Sekunden: tmutil stopbackup im Cleanup
CLEANUP_DETACH_TIMEOUT=20      # Sekunden: hdiutil detach im Cleanup

# --- Logging: rein lokal (Library = nicht in iCloud) ---
# Struktur: Jahr (YYYY) → Monat (YYYY-MM) → KW (Kalenderwoche) → Tag (YYYY-MM-DD), z. B. .../Benutzer/2026/2026-05/KW19/2026-05-06/
# Es werden keine bestehenden Ordner oder Log-Dateien überschrieben:
#   - mkdir -p legt nur fehlende Ordner an, ändert/löscht keine bestehenden.
#   - Log-Dateinamen sind pro Lauf eindeutig; existiert eine Datei bereits (z. B. gleiche Sekunde), wird ein Zusatz (PID) angehängt.
[ -z "$HOME" ] && export HOME=/Users/josh
LOG_BASE="/Users/josh/Documents/Timemachine_logs"
LOG_TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
LOG_DATE=$(date '+%Y-%m-%d')
LOG_YEAR=$(date '+%Y')
LOG_MONTH=$(date '+%Y-%m')
LOG_KW="KW$(date '+%V')"
LOG_TECH_DIR="$LOG_BASE/Technical/$LOG_YEAR/$LOG_MONTH/$LOG_KW/$LOG_DATE"
LOG_USER_DIR="$LOG_BASE/Benutzer/$LOG_YEAR/$LOG_MONTH/$LOG_KW/$LOG_DATE"
OUR_RUN_LOCK="$LOG_BASE/.backup_our_run"   # Watcher prüft: wenn gesetzt, loggt dieses Skript (nicht „Jetzt sichern“)
mkdir -p "$LOG_TECH_DIR" "$LOG_USER_DIR"
TECHNICAL_LOG="$LOG_TECH_DIR/${LOG_TIMESTAMP}.log"
USER_LOG="$LOG_USER_DIR/${LOG_TIMESTAMP}.log"
# Bestehende Log-Dateien nie überschreiben: falls Name schon existiert (z. B. zweiter Lauf in derselben Sekunde), PID an Namen anhängen
[ -f "$TECHNICAL_LOG" ] && TECHNICAL_LOG="$LOG_TECH_DIR/${LOG_TIMESTAMP}_$$.log"
[ -f "$USER_LOG" ] && USER_LOG="$LOG_USER_DIR/${LOG_TIMESTAMP}_$$.log"
# Log-Dateien sofort anlegen und erste Zeile schreiben (damit bei Problemen immer eine Datei existiert)
echo "Time Machine Skript: Log-Pfad $TECHNICAL_LOG" >&2
if ! echo "[$(date '+%Y-%m-%d %H:%M:%S')] Skript gestartet (PID $$)" >> "$TECHNICAL_LOG" 2>/dev/null; then
    echo "FEHLER: Konnte nicht in $TECHNICAL_LOG schreiben (HOME=$HOME)" >&2
fi
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Skript gestartet" >> "$USER_LOG" 2>/dev/null || true

function log_technical() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$TECHNICAL_LOG"
}

function log_user() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$USER_LOG"
}

function log_both() {
    log_technical "$1"
    log_user "$1"
}

# Führt einen Befehl mit Timeout aus. Verhindert, dass mount_smbfs/hdiutil ewig blockieren (z. B. NAS aus/Schlaf)
# und so das Skript nie beendet → caffeinate läuft weiter → Mac kann einfrieren.
# Aufruf: run_with_timeout Sekunden Logdatei_oder_- Befehl [Argumente...]
# Rückgabe: 0 = Befehl erfolgreich, 124 = Timeout, sonst Exit-Code des Befehls.
run_with_timeout() {
    local timeout_sec=$1
    local log_file=$2
    shift 2
    if [ -n "$log_file" ] && [ "$log_file" != "-" ]; then
        ("$@" >> "$log_file" 2>&1) &
    else
        ("$@") &
    fi
    local pid=$!
    sleep $timeout_sec
    if kill -0 $pid 2>/dev/null; then
        kill -TERM $pid 2>/dev/null
        sleep 2
        kill -KILL $pid 2>/dev/null
        wait $pid 2>/dev/null
        return 124
    fi
    wait $pid
    return $?
}

# Hilfsfunktion: Größenangabe wie "31.6 MB" oder "125 GB" in Bytes umrechnen (für % wie Time-Machine-UI)
parse_size_to_bytes() {
    local s="$1"
    local num unit int frac
    num=$(printf '%s' "$s" | grep -oE '[0-9]+\.?[0-9]*' | head -1)
    unit=$(printf '%s' "$s" | grep -oE '[KMGTP]?B' | head -1)
    [ -z "$num" ] && echo "0" && return
    int=${num%%.*}
    frac=${num#*.}
    [ "$frac" = "$num" ] && frac=0
    case "$unit" in
        GB) echo $(( int * 1073741824 + frac * 1073741824 / 10 )) ;;
        MB) echo $(( int * 1048576 + frac * 1048576 / 10 )) ;;
        KB) echo $(( int * 1024 + frac * 1024 / 10 )) ;;
        *)  echo "$int" ;;
    esac
}

# Apple Time Machine Log auswerten: Art (Vollbackup vs Inkrementallauf) + geschätzte Dateianzahl/Größe für diesen Lauf
# Setzt APPLE_BACKUP_ART, APPLE_ESTIMATED_FILES, APPLE_ESTIMATED_STR, APPLE_ESTIMATED_BYTES (für % wie in der System-UI)
function parse_apple_tm_log_for_run() {
    APPLE_BACKUP_ART=""
    APPLE_ESTIMATED_FILES=""
    APPLE_ESTIMATED_STR=""
    APPLE_ESTIMATED_BYTES=""
    local raw tmp_log
    tmp_log=$(mktemp -t tm_apple_log.XXXXXX 2>/dev/null) || return 0
    run_with_timeout "${LOG_SHOW_TIMEOUT:-30}" "$tmp_log" log show --predicate 'subsystem == "com.apple.TimeMachine"' --info --last 3h 2>/dev/null
    raw=$(cat "$tmp_log" 2>/dev/null)
    rm -f "$tmp_log" 2>/dev/null
    [ -z "$raw" ] && return 0
    # Strategie: "Using first backup" → Vollbackup; "Using FSEvents" / "Using snapshot diffing" / "Deep scan" → Inkrementallauf
    if printf '%s' "$raw" | grep -qE 'Using first backup|first backup for source'; then
        APPLE_BACKUP_ART="Vollbackup"
    elif printf '%s' "$raw" | grep -qE 'Using FSEvents|Using snapshot diffing|snapshot diffing for source'; then
        APPLE_BACKUP_ART="Inkrementallauf"
    elif printf '%s' "$raw" | grep -qE 'Deep scan required|Deep scan for source'; then
        APPLE_BACKUP_ART="Inkrementallauf"
    fi
    # Geschätzte Dateien/Größe für diesen Lauf: "Estimated N files (X MB) need to be backed up from all sources" oder "Found N files (X MB) needing backup"
    local line
    line=$(printf '%s' "$raw" | grep -E 'Estimated [0-9]+ files.*need to be backed up from all sources|Found [0-9]+ files.*needing backup' | tail -1)
    if [ -n "$line" ]; then
        APPLE_ESTIMATED_FILES=$(printf '%s' "$line" | grep -oE '[0-9]+ files' | head -1 | grep -oE '[0-9]+')
        APPLE_ESTIMATED_STR=$(printf '%s' "$line" | grep -oE '\([0-9.]+ [A-Za-z]*B\)|[0-9.]+ [A-Za-z]*B' | head -1 | tr -d '()')
        [ -n "$APPLE_ESTIMATED_STR" ] && APPLE_ESTIMATED_BYTES=$(parse_size_to_bytes "$APPLE_ESTIMATED_STR")
    fi
}

# Apple Time Machine Log (Unified Logging) – Ausschnitt der letzten 30 Min in Technical-Ordner speichern
# Hinweis: Unter Umständen liefert log show keine Zeilen (Berechtigung/Vollständiger Festplattenzugriff).
function save_apple_log_excerpt() {
    local out="$LOG_TECH_DIR/Apple_log_${LOG_TIMESTAMP}.log"
    [ -f "$out" ] && out="$LOG_TECH_DIR/Apple_log_${LOG_TIMESTAMP}_$$.log"
    log_technical "Speichere Apple Time-Machine-Log-Ausschnitt (letzte 30 Min) nach $out"
    run_with_timeout "${LOG_SHOW_EXCERPT_TIMEOUT:-45}" "-" sh -c "log show --predicate 'subsystem == \"com.apple.TimeMachine\"' --info --last 30m 2>&1 | head -n 2000 > \"$out\""
    local lines=$(wc -l < "$out" 2>/dev/null | tr -d ' ')
    [ -z "$lines" ] && lines=0
    if [ "$lines" -eq 0 ] 2>/dev/null; then
        echo "Kein Apple-Log-Auszug (log show lieferte keine Zeilen – z. B. Berechtigung „Vollständiger Festplattenzugriff“ für Terminal/Agent prüfen)." >> "$out"
        log_technical "Apple-Log-Ausschnitt: 0 Zeilen von log show – Hinweis in Datei geschrieben"
    else
        log_technical "Apple-Log-Ausschnitt gespeichert ($lines Zeilen)"
    fi
}

# Stderr ins Technical-Log umleiten, damit Automator/LaunchAgent keinen leeren Fehler-Dialog anzeigt
exec 2>>"$TECHNICAL_LOG"

# --- Notification Helper ---
function notify() {
    local MESSAGE=$1
    local TITLE=$2
    osascript -e "display notification \"$MESSAGE\" with title \"$TITLE\"" 2>/dev/null
    log_user "$TITLE: $MESSAGE"
}

# --- Genauen tmutil-Status als eine Logzeile schreiben (Technical-Log) ---
log_tmutil_status() {
    local s="$1"
    [ -z "$s" ] && return
    local phase run pct frac bytes totalb files totalf datechange remaining
    phase=$(printf '%s' "$s" | awk -F= '/BackupPhase/ {gsub(/["; ]/,"",$2); print $2}' | tr -cd 'A-Za-z')
    run=$(printf '%s' "$s" | awk -F= '/Running/ && /=/ {gsub(/["; ]/,"",$2); print $2+0}' | head -1 | tr -cd '0-9')
    pct=$(printf '%s' "$s" | awk -F= '/Percent/ && /=/ {gsub(/["; ]/,"",$2); gsub(/,/,".",$2); v=$2+0; if (v>0 && v<=1) p=v*100; else if (v>1 && v<=100) p=v; else p=0; if (p>=0) print int(p)}' | sort -n | tail -1)
    frac=$(printf '%s' "$s" | awk -F= '/FractionOfProgressBar/ {gsub(/["; ]/,"",$2); print $2+0}')
    bytes=$(printf '%s' "$s" | awk -F= '/[[:space:]]bytes[[:space:]]*=[[:space:]]/ && !/totalBytes/ {gsub(/["; ]/,"",$2); print $2+0}' | head -1)
    totalb=$(printf '%s' "$s" | awk -F= '/totalBytes[[:space:]]*=/ {gsub(/["; ]/,"",$2); print $2+0}' | head -1)
    files=$(printf '%s' "$s" | awk -F= '/[[:space:]]files[[:space:]]*=[[:space:]]/ && !/totalFiles/ {gsub(/["; ]/,"",$2); print $2+0}' | head -1)
    totalf=$(printf '%s' "$s" | awk -F= '/totalFiles[[:space:]]*=/ {gsub(/["; ]/,"",$2); print $2+0}' | head -1)
    datechange=$(printf '%s' "$s" | awk -F= '/DateOfStateChange/ {gsub(/^[" ]+|["; ]+$/,"",$2); gsub(/[: ]/,"_",$2); print $2}' | head -1)
    remaining=$(printf '%s' "$s" | awk -F= '/TimeRemaining/ {gsub(/["; ]/,"",$2); print $2+0}' | head -1)
    [ -n "$bytes" ] && [ "$bytes" -ge 0 ] 2>/dev/null && bytes=$(human_bytes "$bytes") || bytes="-"
    [ -n "$totalb" ] && [ "$totalb" -ge 0 ] 2>/dev/null && totalb=$(human_bytes "$totalb") || totalb="-"
    log_technical "tmutil BackupPhase=${phase:-?} Running=${run:-?} Percent=${pct:-?} FractionOfProgressBar=${frac:-?} bytes=${bytes} totalBytes=${totalb} files=${files:-?} totalFiles=${totalf:-?} DateOfStateChange=${datechange:-?} TimeRemaining=${remaining:-?}s"
}

# --- Bytes lesbar formatieren (z.B. 135651934208 -> "126 GB") ---
human_bytes() {
    local n=$1
    [ -z "$n" ] || [ "$n" -lt 0 ] 2>/dev/null && echo "0 B" && return
    if [ "$n" -ge 1073741824 ] 2>/dev/null; then
        echo "$(( n / 1073741824 )) GB"
    elif [ "$n" -ge 1048576 ] 2>/dev/null; then
        echo "$(( n / 1048576 )) MB"
    elif [ "$n" -ge 1024 ] 2>/dev/null; then
        echo "$(( n / 1024 )) KB"
    else
        echo "$n B"
    fi
}

# --- Fehler-Helper mit zwei verschiedenen Meldungen ---
function log_error() {
    local TECHNICAL_MSG=$1
    local USER_MSG=$2
    log_technical "FEHLER: $TECHNICAL_MSG"
    log_user "FEHLER: $USER_MSG"
    notify "$USER_MSG" "Time Machine Fehler"
}

# --- Cleanup bei Abbruch oder Fehler ---
CLEANUP_DONE=false
BACKUP_OUTCOME=""  # wird vor jedem exit gesetzt; Cleanup schreibt es in die "beendet"-Zeile
CAFFEINATE_PID=""  # PID von caffeinate (verhindert Schlaf/Sperre während Backup)
function cleanup() {
    if [ "$CLEANUP_DONE" = true ]; then
        return
    fi
    CLEANUP_DONE=true
    
    log_technical "Cleanup wird ausgeführt..."
    log_user "Backup wird beendet und aufgeräumt..."
    
    # Schlaf-Sperre wieder aufheben
    if [ -n "$CAFFEINATE_PID" ]; then
        kill "$CAFFEINATE_PID" 2>/dev/null
        log_technical "Caffeinate beendet (PID $CAFFEINATE_PID)"
    fi
    
    # Erst prüfen ob ein Backup läuft und stoppen (mit Timeout – blockiert nicht ewig)
    if tmutil status 2>/dev/null | grep -q '"Running" = 1'; then
        log_technical "Stoppe laufendes Backup (Timeout ${CLEANUP_STOPBACKUP_TIMEOUT:-15}s)..."
        log_user "Laufendes Backup wird gestoppt..."
        run_with_timeout "${CLEANUP_STOPBACKUP_TIMEOUT:-15}" "-" tmutil stopbackup 2>/dev/null
        sleep 3
    fi
    
    # Sparsebundle unmounten (mit Timeout – blockiert nicht ewig)
    if mount | grep -q "$MOUNTPOINT"; then
        log_technical "Unmounte Sparsebundle (Timeout ${CLEANUP_DETACH_TIMEOUT:-20}s)..."
        log_user "Backup-Laufwerk wird getrennt..."
        run_with_timeout "${CLEANUP_DETACH_TIMEOUT:-20}" "-" hdiutil detach "$MOUNTPOINT" -force -quiet 2>/dev/null
        sleep 2
    fi
    
    rm -f "$OUR_RUN_LOCK" 2>/dev/null
    save_apple_log_excerpt
    notify "Time Machine Skript beendet." "Time Machine"
    log_both "========== Time Machine Backup-Lauf beendet (${BACKUP_OUTCOME:-unbekannt}) =========="
    log_both ""
    log_both ""
}
trap cleanup EXIT INT TERM

# --- Prüfen, ob Time Machine bereits läuft ---
if tmutil status 2>/dev/null | grep -q '"Running" = 1'; then
    BACKUP_OUTCOME="nicht gestartet (Time Machine lief bereits)"
    log_both "Time Machine läuft bereits - Skript wird beendet"
    notify "Time Machine läuft bereits." "Time Machine"
    exit 0
fi

log_both "========== Time Machine Backup-Lauf gestartet ($(date '+%Y-%m-%d %H:%M:%S')) =========="

# Warten bis WLAN/Netzwerk bereit ist und NAS erreichbar (sonst bricht der Mount sofort ab)
NAS_IP="$NAS_SERVER"
elapsed=0
while [ $elapsed -lt $NETWORK_WAIT_MAX ]; do
    if ping -c 1 -t 2 "$NAS_IP" >> "$TECHNICAL_LOG" 2>&1; then
        log_technical "NAS erreichbar (ping $NAS_IP) nach ${elapsed}s – starte Verbindung"
        break
    fi
    log_technical "Warte auf Netzwerk/NAS (ping $NAS_IP) … ${elapsed}s"
    sleep $NETWORK_WAIT_INTERVAL
    elapsed=$((elapsed + NETWORK_WAIT_INTERVAL))
done
if [ $elapsed -ge $NETWORK_WAIT_MAX ]; then
    log_technical "Nach ${NETWORK_WAIT_MAX}s noch kein Ping – versuche Mount trotzdem"
fi

# --- Schlaf und Bildschirmsperre während Backup verhindern (sonst bricht oft die NAS-Verbindung ab) ---
# -i = kein Leerlauf-Schlaf, -s = kein Systemschlaf bei Netzteil, -d = Display bleibt an, -m = Festplatte wach
# -t = Dauer in Sekunden (Backup-Timeout + Puffer), damit die Sperre auch bei Prozess-Trennung wirkt
CAFFEINATE_DURATION=$((MAX_BACKUP_HOURS * 3600 + 600))
caffeinate -i -s -d -m -t $CAFFEINATE_DURATION &
CAFFEINATE_PID=$!
log_technical "Caffeinate gestartet (PID $CAFFEINATE_PID) – Schlaf/Display/Festplatte deaktiviert für ${CAFFEINATE_DURATION}s"
log_user "Hinweis: Unter Energie/Batterie „Computer schlafen lassen“ bei Netzbetrieb auf „Nie“ stellen."

# --- Cloud/NAS: prüfen ob bereits verbunden, sonst per mount_smbfs verbinden (ohne Fenster) ---
VOLUME_PATH=""
# Bereits gemountet? (ganzes Laufwerk mit Ordner TimeMachineBackup oder direkt TimeMachineBackup gemountet)
for vol in "$HOME/.timemachine_nas/"*/; do
    [ -d "$vol" ] || continue
    if [ -n "$NAS_SUBFOLDER" ]; then
        [ -e "$vol/$NAS_SUBFOLDER/$SPARSEBUNDLE_NAME" ] && VOLUME_PATH="${vol%/}/$NAS_SUBFOLDER" && break
    else
        [ -e "$vol/$SPARSEBUNDLE_NAME" ] && VOLUME_PATH="${vol%/}" && break
    fi
done
if [ -z "$VOLUME_PATH" ]; then
    for vol in /Volumes/*; do
        if [ -n "$NAS_SUBFOLDER" ]; then
            [ -e "$vol/$NAS_SUBFOLDER/$SPARSEBUNDLE_NAME" ] && VOLUME_PATH="$vol/$NAS_SUBFOLDER" && break
        else
            [ -e "$vol/$SPARSEBUNDLE_NAME" ] && VOLUME_PATH="$vol" && break
        fi
    done
fi

# Hilfsfunktion: eine SMB-Freigabe mounten (Server, Share, Mountpoint)
# Mit NAS_USER: //user:pass@server/share (Passwort kann leer sein). Mit Timeout, damit blockierender Mount den Mac nicht einfriert.
mount_one_smb() {
    local server=$1 share=$2 mnt=$3
    if mount | grep -q "$mnt"; then
        log_technical "Bereits gemountet: $mnt"
        return 0
    fi
    mkdir -p "$mnt" 2>/dev/null
    local rc=0
    if [ -n "$NAS_USER" ]; then
        run_with_timeout "${SMB_MOUNT_TIMEOUT}" "$TECHNICAL_LOG" mount_smbfs "//${NAS_USER}:${NAS_PASS}@${server}/${share}" "$mnt"
        rc=$?
    else
        run_with_timeout "${SMB_MOUNT_TIMEOUT}" "$TECHNICAL_LOG" mount_smbfs "//$server/$share" "$mnt"
        rc=$?
    fi
    if [ $rc -eq 124 ]; then
        log_technical "mount_smbfs Timeout nach ${SMB_MOUNT_TIMEOUT}s – NAS antwortet nicht"
        return 1
    fi
    mount | grep -q "$mnt"
}

# Passwort aus Schlüsselbund (nur wenn NAS_PASS nicht schon gesetzt)
if [ -n "$NAS_USER" ] && [ -z "${NAS_PASS+set}" ]; then
    NAS_PASS=$(security find-generic-password -s "mount_timemachine_nas" -a "$NAS_USER" -w 2>/dev/null)
    [ -z "$NAS_PASS" ] && log_technical "Kein Schlüsselbund-Eintrag – verwende leeres Passwort"
fi
NAS_MOUNT_BASE="${HOME}/.timemachine_nas"

if [ -n "$VOLUME_PATH" ]; then
    log_technical "NAS bereits verbunden: $VOLUME_PATH"
    log_user "NAS ist bereits verbunden – starte mit Backup."
else
    MNT="$NAS_MOUNT_BASE/$NAS_SHARE"
    mkdir -p "$MNT"
    if [ ! -d "$MNT" ]; then
        log_technical "FEHLER: Konnte Mountpoint nicht anlegen: $MNT"
        BACKUP_OUTCOME="Fehler: Mountpoint nicht anlegbar"
        log_error "Mountpoint konnte nicht erstellt werden." "Speicher für Backup-Verbindung konnte nicht vorbereitet werden."
        exit 1
    fi

    log_technical "Mounte NAS: //$NAS_SERVER/$NAS_SHARE -> $MNT (Gast, ohne Anmeldung)"
    log_user "Verbinde mit NAS..."

    retries=0
    while [ $retries -lt $MAX_RETRIES ]; do
        mount_one_smb "$NAS_SERVER" "$NAS_SHARE" "$MNT"
        if [ -n "$NAS_SUBFOLDER" ]; then
            if [ -e "$MNT/$NAS_SUBFOLDER/$SPARSEBUNDLE_NAME" ]; then
                VOLUME_PATH="$MNT/$NAS_SUBFOLDER"
                log_technical "SMB-Volume mit Backup-Ziel: $VOLUME_PATH"
                log_user "Verbindung zum NAS hergestellt"
                break
            fi
        else
            if [ -e "$MNT/$SPARSEBUNDLE_NAME" ]; then
                VOLUME_PATH="$MNT"
                log_technical "SMB-Volume mit Backup-Ziel: $VOLUME_PATH"
                log_user "Verbindung zum NAS hergestellt"
                break
            fi
        fi
        log_technical "Backup-Ziel auf Volume noch nicht da (Versuch $((retries + 1))/$MAX_RETRIES), warte ${SLEEP_BETWEEN}s..."
        sleep $SLEEP_BETWEEN
        retries=$((retries + 1))
    done
fi

if [ -z "$VOLUME_PATH" ]; then
    BACKUP_OUTCOME="Fehler: NAS nicht erreichbar"
    log_error "NAS nicht gefunden nach $MAX_RETRIES Versuchen (Exit-Code: Timeout)" \
              "Verbindung zum NAS fehlgeschlagen. Bitte prüfe: Ist das NAS eingeschaltet? Ist die WLAN/Netzwerk-Verbindung aktiv?"
    exit 1
fi

# --- Sparsebundle mounten (nur wenn noch nicht gemountet) ---
SPARSEBUNDLE_PATH="$VOLUME_PATH/$SPARSEBUNDLE_NAME"

if [ ! -e "$SPARSEBUNDLE_PATH" ]; then
    BACKUP_OUTCOME="Fehler: Backup-Datei nicht gefunden"
    log_error "Sparsebundle nicht gefunden: $SPARSEBUNDLE_PATH" \
              "Time Machine Backup-Datei wurde nicht gefunden. Möglicherweise wurde sie verschoben oder gelöscht."
    exit 1
fi

if ! mount | grep -q "$MOUNTPOINT"; then
    log_technical "Mounte Sparsebundle: $SPARSEBUNDLE_PATH"
    log_user "Öffne Backup-Laufwerk..."
    
    # Erst prüfen ob Mountpoint existiert, sonst erstellen
    if [ ! -d "$MOUNTPOINT" ]; then
        mkdir -p "$MOUNTPOINT" 2>/dev/null
    fi
    
    run_with_timeout "${HDIUTIL_ATTACH_TIMEOUT}" "$TECHNICAL_LOG" hdiutil attach "$SPARSEBUNDLE_PATH" -mountpoint "$MOUNTPOINT" -nobrowse -quiet -noverify -noautofsck
    ATTACH_EXIT=$?
    
    if [ $ATTACH_EXIT -ne 0 ]; then
        BACKUP_OUTCOME="Fehler: Laufwerk konnte nicht geöffnet werden"
        log_technical "hdiutil attach fehlgeschlagen mit Exit-Code: $ATTACH_EXIT"
        
        # Benutzerfreundliche Erklärung je nach Exit-Code
        case $ATTACH_EXIT in
            124)
                log_error "hdiutil attach Timeout nach ${HDIUTIL_ATTACH_TIMEOUT}s" \
                          "Backup-Laufwerk hat nicht rechtzeitig reagiert (z. B. NAS im Schlaf oder Netzwerk langsam). Bitte erneut versuchen oder NAS/Netzwerk prüfen."
                ;;
            1)
                log_error "hdiutil attach Exit-Code: 1" \
                          "Backup-Laufwerk konnte nicht geöffnet werden. Möglicherweise ist es beschädigt oder wird bereits verwendet."
                ;;
            2)
                log_error "hdiutil attach Exit-Code: 2" \
                          "Backup-Laufwerk konnte nicht gefunden oder gelesen werden. Prüfe die Verbindung zum NAS."
                ;;
            95)
                log_error "hdiutil attach Exit-Code: 95" \
                          "Backup-Laufwerk ist bereits an anderer Stelle geöffnet oder wird verwendet."
                ;;
            *)
                log_error "hdiutil attach Exit-Code: $ATTACH_EXIT" \
                          "Backup-Laufwerk konnte nicht geöffnet werden (Fehlercode: $ATTACH_EXIT). Möglicherweise ist die Verbindung zum NAS instabil."
                ;;
        esac
        exit 1
    fi
    
    # Kurz warten damit Mount sicher steht
    sleep 2
    
    # Verifizieren dass Mount erfolgreich war
    if ! mount | grep -q "$MOUNTPOINT"; then
        BACKUP_OUTCOME="Fehler: Laufwerk konnte nicht eingebunden werden"
        log_error "Mount-Verifizierung fehlgeschlagen" \
                  "Backup-Laufwerk konnte nicht korrekt eingebunden werden. Versuche es erneut oder starte den Mac neu."
        exit 1
    fi
else
    log_technical "Sparsebundle bereits gemountet"
    log_user "Backup-Laufwerk ist bereits verbunden"
fi

log_both "Backup-Laufwerk bereit"
notify "Backup-Laufwerk bereit - starte Backup..." "Time Machine"

# --- Backup starten (mit Timeout – verhindert Freeze wenn tmutil blockiert) ---
log_technical "Starte Time Machine Backup (tmutil startbackup --auto, Timeout ${TM_STARTBACKUP_TIMEOUT}s)..."
log_user "Starte Time Machine Backup..."
run_with_timeout "${TM_STARTBACKUP_TIMEOUT}" "$TECHNICAL_LOG" tmutil startbackup --auto
BACKUP_START_EXIT=$?

# Timeout (124)? Prüfen ob Backup trotzdem gestartet wurde – dann weitermachen
if [ $BACKUP_START_EXIT -eq 124 ]; then
    if tmutil status 2>/dev/null | grep -qF 'Running = 1'; then
        BACKUP_START_EXIT=0
        log_technical "tmutil startbackup Timeout, aber Backup läuft bereits – Überwachung wird fortgesetzt"
    else
        BACKUP_OUTCOME="Fehler: Time Machine Start Timeout"
        log_error "tmutil startbackup blockierte nach ${TM_STARTBACKUP_TIMEOUT}s (Mac-Freeze verhindert)" \
                  "Time Machine konnte nicht starten (Timeout). Bitte erneut versuchen oder Systemeinstellungen prüfen."
        exit 1
    fi
fi

if [ $BACKUP_START_EXIT -ne 0 ]; then
    BACKUP_OUTCOME="Fehler: Time Machine konnte nicht starten"
    # Benutzerfreundliche Erklärung je nach Exit-Code
    case $BACKUP_START_EXIT in
        1)
            log_error "tmutil startbackup Exit-Code: 1" \
                      "Time Machine konnte nicht gestartet werden. Möglicherweise läuft bereits ein Backup oder das Backup-Ziel ist nicht korrekt konfiguriert."
            ;;
        2)
            log_error "tmutil startbackup Exit-Code: 2" \
                      "Time Machine hat das Backup abgelehnt. Das Backup-Laufwerk wurde möglicherweise nicht erkannt."
            ;;
        *)
            log_error "tmutil startbackup Exit-Code: $BACKUP_START_EXIT" \
                      "Time Machine konnte nicht gestartet werden (Fehlercode: $BACKUP_START_EXIT). Prüfe in den Systemeinstellungen ob Time Machine korrekt konfiguriert ist."
            ;;
    esac
    exit 1
fi

log_both "Backup erfolgreich gestartet"
notify "Backup gestartet." "Time Machine"
touch "$OUR_RUN_LOCK" 2>/dev/null

# Kurz warten, bis tmutil status "Running = 1" anzeigt (sonst denkt das Skript sofort "übersprungen")
sleep 15
log_technical "Start der Überwachung (15 s Verzögerung abgeschlossen)"

# --- Backup Fortschritt überwachen ---
LAST_PERCENT=-1
HAD_PROGRESS=0  # 1 = mindestens einmal Fortschritt > 0% gesehen (für Unterscheidung abgebrochen vs. übersprungen)
LAST_LOGGED_FILES=0
LAST_LOGGED_TOTAL_FILES=0
LAST_LOGGED_BYTES=0
LAST_LOGGED_TOTAL_BYTES=0
INCREMENTAL_COMPLETED=0  # 1 = Quick-Check: vermutlich Inkrementallauf fertig (Phase nicht Idle, aber nur wenige Dateien)
TIMEOUT=$((MAX_BACKUP_HOURS * 3600))
ELAPSED=0
STALLED_COUNT=0
MAX_STALLED=3  # Anzahl identischer Checks bevor "stalled" gemeldet wird
COMPLETED_COUNT=0  # Zähler für "Backup ist fertig" Bestätigungen
SEEN_RUNNING=0  # Erst nach "Running = 1" auf Abbruch prüfen (Vorbereitungsphase auslassen)

log_technical "Überwache Backup-Fortschritt (Timeout: ${MAX_BACKUP_HOURS}h, Check-Interval: ${CHECK_INTERVAL}s)..."
log_user "Backup läuft - Fortschritt wird überwacht..."

while true; do

    # Caffeinate am Leben halten (falls das System es beendet hat, neu starten)
    if [ -n "$CAFFEINATE_PID" ] && ! kill -0 "$CAFFEINATE_PID" 2>/dev/null; then
        caffeinate -i -s -d -m -t $CAFFEINATE_DURATION &
        CAFFEINATE_PID=$!
        log_technical "Caffeinate neu gestartet (PID $CAFFEINATE_PID) – war beendet worden"
    fi

    # Timeout prüfen
    if [ $ELAPSED -ge $TIMEOUT ]; then
        BACKUP_OUTCOME="Fehler: Timeout (über ${MAX_BACKUP_HOURS} Stunden)"
        log_error "Backup-Timeout nach ${MAX_BACKUP_HOURS} Stunden erreicht (Elapsed: ${ELAPSED}s)" \
                  "Das Backup dauert ungewöhnlich lange (über ${MAX_BACKUP_HOURS} Stunden). Möglicherweise ist die Netzwerkverbindung zu langsam oder es gibt zu viele Daten zu sichern."
        exit 1
    fi

    # Status ohne Variable für Lauf-Check (vermeidet "character not in range" bei Sonderzeichen)
    if tmutil status 2>/dev/null | grep -qF 'Running = 1'; then
        SEEN_RUNNING=1
    fi

    STATUS=$(tmutil status 2>/dev/null | LC_ALL=C tr -cd '\n\t\40-\176')
    
    if [ -z "$STATUS" ]; then
        log_technical "Warnung: tmutil status liefert keine Ausgabe"
        sleep $CHECK_INTERVAL
        ELAPSED=$((ELAPSED + CHECK_INTERVAL))
        continue
    fi

    # Kein Backup mehr aktiv? Nur prüfen, wenn wir "Running = 1" schon mal gesehen haben
    # (in der Vorbereitungsphase steht oft noch kein Running = 1)
    if [ "$SEEN_RUNNING" -eq 0 ]; then
        :  # Noch in Vorbereitung – nicht als "beendet" werten
    elif ! tmutil status 2>/dev/null | grep -qF 'Running = 1'; then
        # Inkrementallauf wurde in der inneren Schleife als fertig erkannt → nicht hier als "abgebrochen" beenden
        if [ "$INCREMENTAL_COMPLETED" -eq 1 ] 2>/dev/null; then
            :  # Durchlaufen lassen, damit unten "Running=0, Phase nicht Idle" + INCREMENTAL_COMPLETED als Erfolg geloggt wird
        elif [ "$HAD_PROGRESS" -eq 1 ]; then
            BACKUP_OUTCOME="vom Benutzer abgebrochen"
            log_technical "Kein laufendes Backup mehr (Quick-Check) – Backup war gestartet, wurde abgebrochen"
            log_user "Backup wurde von Ihnen abgebrochen."
            notify "Time Machine: ${BACKUP_OUTCOME}" "Time Machine"
            exit 0
        else
            BACKUP_OUTCOME="von Time Machine übersprungen (z.B. keine Änderungen)"
            log_technical "Kein laufendes Backup mehr – von Time Machine übersprungen (z.B. keine Änderungen)"
            log_user "Backup wurde von Time Machine übersprungen (z.B. keine Änderungen nötig)."
            notify "Time Machine: ${BACKUP_OUTCOME}" "Time Machine"
            exit 0
        fi
    fi

    # Laufstatus auslesen – Fallback auf "1" damit Schleife weiterläuft wenn leer
    RUNNING=$(printf '%s' "$STATUS" | awk -F= '/Running/ && /=/ {gsub(/ /,"",$2); print $2}' | tr -d ';\r\n' | head -1)
    RUNNING=$(printf '%s' "${RUNNING:-1}" | tr -cd '0-9')
    [ -z "$RUNNING" ] && RUNNING=1

    # Phase auslesen – nur ASCII-Buchstaben (vermeidet zsh "character not in range")
    PHASE=$(printf '%s' "$STATUS" | awk -F= '/BackupPhase/ {gsub(/ /,"",$2); print $2}' | tr -d ';"\r\n')
    PHASE=$(printf '%s' "${PHASE:-}" | LC_ALL=C tr -cd 'A-Za-z')

    # Backup fertig oder abgebrochen? Running=0 heißt: kein Backup läuft mehr
    if [ "$RUNNING" = "0" ]; then
        if [ "$PHASE" = "Idle" ] || [ "$PHASE" = "idle" ]; then
            COMPLETED_COUNT=$((COMPLETED_COUNT + 1))
            log_technical "Backup scheint abgeschlossen zu sein (Check $COMPLETED_COUNT/2: Running=0, Phase=$PHASE)"
            
            # Bestätige zweimal dass Backup wirklich fertig ist (vermeidet false positives)
            if [ $COMPLETED_COUNT -ge 2 ]; then
                log_technical "Backup definitiv abgeschlossen - beende Überwachung"
                log_tmutil_status "$STATUS"
                log_technical "Backup Fortschritt: 100% (abgeschlossen)"
                # Art des Laufs: aus Apple-Log (first backup / FSEvents / snapshot diffing) oder Heuristik (Dateien-Ratio)
                parse_apple_tm_log_for_run
                if [ -n "$APPLE_BACKUP_ART" ]; then
                    log_technical "Art: $APPLE_BACKUP_ART (laut Apple-Log)"
                    [ -n "$APPLE_ESTIMATED_FILES" ] && log_technical "Laut Apple-Log: ${APPLE_ESTIMATED_FILES} Dateien (${APPLE_ESTIMATED_STR}) sollten in diesem Lauf gesichert werden"
                    log_user "Art: $APPLE_BACKUP_ART${APPLE_ESTIMATED_FILES:+ (laut Apple: ${APPLE_ESTIMATED_FILES} Dateien in diesem Lauf)}"
                elif [ -n "$LAST_LOGGED_TOTAL_FILES" ] && [ "$LAST_LOGGED_TOTAL_FILES" -gt 0 ] 2>/dev/null; then
                    _ratio=0
                    [ -n "$LAST_LOGGED_FILES" ] && [ "$LAST_LOGGED_FILES" -ge 0 ] 2>/dev/null && _ratio=$(( LAST_LOGGED_FILES * 100 / LAST_LOGGED_TOTAL_FILES ))
                    if [ "$_ratio" -lt 50 ] 2>/dev/null; then
                        _bh=""; _th=""
                        [ -n "$LAST_LOGGED_BYTES" ] && [ "$LAST_LOGGED_BYTES" -ge 0 ] 2>/dev/null && _bh=$(human_bytes "$LAST_LOGGED_BYTES")
                        [ -n "$LAST_LOGGED_TOTAL_BYTES" ] && [ "$LAST_LOGGED_TOTAL_BYTES" -ge 0 ] 2>/dev/null && _th=$(human_bytes "$LAST_LOGGED_TOTAL_BYTES")
                        log_technical "Art: Inkrementallauf – nur ${LAST_LOGGED_FILES} von ${LAST_LOGGED_TOTAL_FILES} Dateien (${_bh:-?} von ${_th:-?}) übertragen"
                        log_user "Art: Inkrementallauf (nur geänderte Dateien: ${LAST_LOGGED_FILES} von ${LAST_LOGGED_TOTAL_FILES})"
                    else
                        log_technical "Art: Vollbackup/Erstlauf – ${LAST_LOGGED_FILES} von ${LAST_LOGGED_TOTAL_FILES} Dateien übertragen"
                        log_user "Art: Vollbackup (${LAST_LOGGED_FILES} von ${LAST_LOGGED_TOTAL_FILES} Dateien)"
                    fi
                fi
                log_user "Backup Fortschritt: 100% (abgeschlossen)"
                log_user "Backup abgeschlossen!"
                break
            fi
            
            # Kurz warten für zweite Bestätigung
            sleep 10
            continue
        else
            # Running=0, Phase nicht Idle – mit Apple-Zahl sauber prüfen: kopierte Dateien >= erwartete → fertig
            parse_apple_tm_log_for_run
            if [ "$HAD_PROGRESS" -eq 1 ] && [ -n "$APPLE_ESTIMATED_FILES" ] && [ "$APPLE_ESTIMATED_FILES" -gt 0 ] 2>/dev/null; then
                _need=$(( APPLE_ESTIMATED_FILES * 95 / 100 ))
                if [ -n "$LAST_LOGGED_FILES" ] && [ "$LAST_LOGGED_FILES" -ge "$_need" ] 2>/dev/null; then
                    INCREMENTAL_COMPLETED=1
                fi
            fi
            if [ "$INCREMENTAL_COMPLETED" -eq 1 ] 2>/dev/null; then
                BACKUP_OUTCOME="erfolgreich abgeschlossen"
                log_technical "Backup beendet (Running=0, Phase=$PHASE) – als Inkrementallauf fertig gewertet (nicht abgebrochen)"
                parse_apple_tm_log_for_run
                if [ -n "$APPLE_BACKUP_ART" ]; then
                    log_technical "Art: $APPLE_BACKUP_ART (laut Apple-Log)"
                    [ -n "$APPLE_ESTIMATED_FILES" ] && log_technical "Laut Apple-Log: ${APPLE_ESTIMATED_FILES} Dateien (${APPLE_ESTIMATED_STR}) sollten in diesem Lauf gesichert werden"
                    log_user "Art: $APPLE_BACKUP_ART${APPLE_ESTIMATED_FILES:+ (laut Apple: ${APPLE_ESTIMATED_FILES} Dateien in diesem Lauf)}"
                elif [ -n "$LAST_LOGGED_TOTAL_FILES" ] && [ "$LAST_LOGGED_TOTAL_FILES" -gt 0 ] 2>/dev/null; then
                    _bh=""; _th=""
                    [ -n "$LAST_LOGGED_BYTES" ] && [ "$LAST_LOGGED_BYTES" -ge 0 ] 2>/dev/null && _bh=$(human_bytes "$LAST_LOGGED_BYTES")
                    [ -n "$LAST_LOGGED_TOTAL_BYTES" ] && [ "$LAST_LOGGED_TOTAL_BYTES" -ge 0 ] 2>/dev/null && _th=$(human_bytes "$LAST_LOGGED_TOTAL_BYTES")
                    log_technical "Art: Inkrementallauf – nur ${LAST_LOGGED_FILES} von ${LAST_LOGGED_TOTAL_FILES} Dateien (${_bh:-?} von ${_th:-?}) übertragen"
                    log_user "Art: Inkrementallauf (nur geänderte Dateien: ${LAST_LOGGED_FILES} von ${LAST_LOGGED_TOTAL_FILES})"
                else
                    log_user "Art: Inkrementallauf (Backup fertig, Phase wurde nicht als Idle erkannt)"
                fi
                log_user "Backup Fortschritt: 100% (abgeschlossen)"
                log_user "Backup abgeschlossen!"
                break
            fi
            # Sonst: vom Benutzer abgebrochen oder von Time Machine übersprungen
            if [ "$HAD_PROGRESS" -eq 1 ]; then
                BACKUP_OUTCOME="vom Benutzer abgebrochen"
                log_technical "Backup beendet (Running=0, Phase=$PHASE) – vom Benutzer abgebrochen"
                log_user "Backup wurde von Ihnen abgebrochen."
            else
                BACKUP_OUTCOME="von Time Machine übersprungen (z.B. keine Änderungen)"
                log_technical "Backup beendet (Running=0, Phase=$PHASE) – von Time Machine übersprungen"
                log_user "Backup wurde von Time Machine übersprungen (z.B. keine Änderungen nötig)."
            fi
            notify "Time Machine: ${BACKUP_OUTCOME}" "Time Machine"
            exit 0
        fi
    else
        # Running ist nicht 0 - Reset Counter
        COMPLETED_COUNT=0
    fi

    # Apple-Log auswerten: erwartete Dateianzahl dieses Laufs → korrekte % und saubere Fertig/Abgebrochen-Entscheidung
    if [ "$RUNNING" = "1" ]; then
        parse_apple_tm_log_for_run
    fi

    # Fortschritt auslesen: tmutil liefert Percent teils als 0.0–1.0 (Bruch), teils als 0–100; alle Zeilen auswerten, Maximum nehmen
    PERCENT=$(printf '%s' "$STATUS" | awk -F= '/Percent/ && /=/ {gsub(/["; ]/,"",$2); gsub(/,/,".",$2); v=$2+0; if (v>0 && v<=1) p=v*100; else if (v>1 && v<=100) p=v; else p=0; if (p>=0) print int(p)}' | sort -n | tail -1)
    PERCENT=$(printf '%s' "${PERCENT:-0}" | tr -cd '0-9\-')
    [ -z "$PERCENT" ] && PERCENT=0
    [ "$PERCENT" -lt 0 ] 2>/dev/null && PERCENT=0
    [ "$PERCENT" -gt 100 ] 2>/dev/null && PERCENT=100
    [ "$PERCENT" -gt 0 ] 2>/dev/null && HAD_PROGRESS=1

    # Aus tmutil status: Phase, Bytes, Dateien für besseres Log
    TM_BYTES=$(printf '%s' "$STATUS" | awk -F= '/[[:space:]]bytes[[:space:]]*=[[:space:]]/ && !/totalBytes/ {gsub(/["; ]/,"",$2); print $2+0}' | head -1)
    TM_TOTAL_BYTES=$(printf '%s' "$STATUS" | awk -F= '/totalBytes[[:space:]]*=/ {gsub(/["; ]/,"",$2); print $2+0}' | head -1)
    TM_FILES=$(printf '%s' "$STATUS" | awk -F= '/[[:space:]]files[[:space:]]*=[[:space:]]/ && !/totalFiles/ {gsub(/["; ]/,"",$2); print $2+0}' | head -1)
    TM_TOTAL_FILES=$(printf '%s' "$STATUS" | awk -F= '/totalFiles[[:space:]]*=/ {gsub(/["; ]/,"",$2); print $2+0}' | head -1)
    # Fortschritt wie Time-Machine-UI: wenn Apple geschätzte Größe dieses Laufs liefert → % aus Bytes (stimmt mit System-Anzeige überein)
    if [ -n "$APPLE_ESTIMATED_BYTES" ] && [ "$APPLE_ESTIMATED_BYTES" -gt 0 ] 2>/dev/null && [ -n "$TM_BYTES" ] && [ "$TM_BYTES" -ge 0 ] 2>/dev/null; then
        PERCENT=$(( TM_BYTES * 100 / APPLE_ESTIMATED_BYTES ))
        [ "$PERCENT" -gt 100 ] 2>/dev/null && PERCENT=100
    # Sonst: % aus erwarteten Dateien dieses Laufs (wenn aus Apple-Log)
    elif [ -n "$APPLE_ESTIMATED_FILES" ] && [ "$APPLE_ESTIMATED_FILES" -gt 0 ] 2>/dev/null && [ -n "$TM_FILES" ] && [ "$TM_FILES" -ge 0 ] 2>/dev/null; then
        PERCENT=$(( TM_FILES * 100 / APPLE_ESTIMATED_FILES ))
        [ "$PERCENT" -gt 100 ] 2>/dev/null && PERCENT=100
    fi
    TM_BYTES_HUMAN=""; TM_TOTAL_HUMAN=""
    [ -n "$TM_BYTES" ] && [ "$TM_BYTES" -ge 0 ] 2>/dev/null && TM_BYTES_HUMAN=$(human_bytes "$TM_BYTES")
    [ -n "$TM_TOTAL_BYTES" ] && [ "$TM_TOTAL_BYTES" -ge 0 ] 2>/dev/null && TM_TOTAL_HUMAN=$(human_bytes "$TM_TOTAL_BYTES")

    # Prüfe ob Backup hängt (gleicher Prozentsatz über mehrere Intervalle)
    if [ -n "$PERCENT" ] && [ "$PERCENT" -eq "$PERCENT" ] 2>/dev/null; then
        if [ "$PERCENT" -eq "${LAST_PERCENT:-0}" ] 2>/dev/null && [ "$PERCENT" -gt 0 ] 2>/dev/null; then
            STALLED_COUNT=$((STALLED_COUNT + 1))
            if [ $STALLED_COUNT -ge $MAX_STALLED ]; then
                STALL_MINUTES=$((MAX_STALLED * CHECK_INTERVAL / 60))
                log_technical "WARNUNG: Backup scheint festzuhängen bei $PERCENT% (seit ${STALL_MINUTES} Minuten kein Fortschritt, Stalled-Count: $STALLED_COUNT)"
                log_user "WARNUNG: Backup macht seit ${STALL_MINUTES} Minuten keinen Fortschritt mehr bei $PERCENT%"
                notify "Backup macht keinen Fortschritt mehr bei $PERCENT%. Möglicherweise gibt es Probleme mit der Netzwerkverbindung." "Time Machine Warnung"
                STALLED_COUNT=0  # Reset damit Notification nicht spammt
            fi
        else
            STALLED_COUNT=0
        fi
        
        # Nur Fortschritt > 0% loggen (0% z.B. beim Start oder Abschluss weglassen)
        if [ "$PERCENT" -gt 0 ] 2>/dev/null && [ "$PERCENT" -gt "${LAST_PERCENT:--1}" ] 2>/dev/null; then
            notify "Backup läuft: $PERCENT% abgeschlossen" "Time Machine"
            [ -n "$TM_FILES" ] && [ "$TM_FILES" -ge 0 ] 2>/dev/null && LAST_LOGGED_FILES=$TM_FILES
            [ -n "$TM_TOTAL_FILES" ] && [ "$TM_TOTAL_FILES" -ge 0 ] 2>/dev/null && LAST_LOGGED_TOTAL_FILES=$TM_TOTAL_FILES
            [ -n "$TM_BYTES" ] && [ "$TM_BYTES" -ge 0 ] 2>/dev/null && LAST_LOGGED_BYTES=$TM_BYTES
            [ -n "$TM_TOTAL_BYTES" ] && [ "$TM_TOTAL_BYTES" -ge 0 ] 2>/dev/null && LAST_LOGGED_TOTAL_BYTES=$TM_TOTAL_BYTES
            log_tmutil_status "$STATUS"
            # Bei Apple-Zahl: "X von N Dateien" = dieser Lauf (N = APPLE_ESTIMATED_FILES)
            _total_f=${TM_TOTAL_FILES:-?}; _total_f_ui="$_total_f"
            [ -n "$APPLE_ESTIMATED_FILES" ] && [ "$APPLE_ESTIMATED_FILES" -gt 0 ] 2>/dev/null && _total_f=$APPLE_ESTIMATED_FILES && _total_f_ui="${APPLE_ESTIMATED_FILES} (dieser Lauf)"
            if [ -n "$TM_BYTES_HUMAN" ] && [ -n "$TM_TOTAL_HUMAN" ]; then
                log_technical "Backup: $PERCENT% | Phase: $PHASE | $TM_BYTES_HUMAN / $TM_TOTAL_HUMAN | ${TM_FILES:-?} / $_total_f_ui Dateien"
                log_user "Backup Fortschritt: $PERCENT% ($TM_BYTES_HUMAN von $TM_TOTAL_HUMAN, ${TM_FILES:-?} von $_total_f_ui Dateien)"
            else
                log_technical "Backup Fortschritt: $PERCENT% | Phase: $PHASE | ${TM_FILES:-?} / $_total_f_ui Dateien (vorher: ${LAST_PERCENT:-?}%)"
                log_user "Backup Fortschritt: $PERCENT% (${TM_FILES:-?} von $_total_f_ui Dateien)"
            fi
            LAST_PERCENT=$PERCENT
        fi
    fi

    # Warte bis zum nächsten vollen Check – dabei alle QUICK_CHECK_SECONDS: Lauf prüfen + Fortschritt
    # Direkt tmutil | grep (kein $QUICK_STATUS), damit keine "character not in range" durch Sonderzeichen
    # Erst nach 2 aufeinanderfolgenden Quick-Checks ohne "Running = 1" beenden (vermeidet Abbruch bei kurzen tmutil-Schwankungen)
    REMAINING=$CHECK_INTERVAL
    LAST_PROGRESS_PERCENT=${LAST_PERCENT:-0}
    SECS_SINCE_PROGRESS=0
    QUICK_FAIL_COUNT=0
    while [ $REMAINING -gt 0 ]; do
        sleep $QUICK_CHECK_SECONDS
        REMAINING=$((REMAINING - QUICK_CHECK_SECONDS))
        SECS_SINCE_PROGRESS=$((SECS_SINCE_PROGRESS + QUICK_CHECK_SECONDS))
        if tmutil status 2>/dev/null | grep -qF 'Running = 1'; then
            QUICK_FAIL_COUNT=0
        elif [ "$SEEN_RUNNING" -eq 1 ]; then
            QUICK_FAIL_COUNT=$((QUICK_FAIL_COUNT + 1))
            if [ $QUICK_FAIL_COUNT -ge 2 ]; then
                # Warten und mehrfach Phase prüfen – bei schnellem Inkrementallauf setzt backupd Idle oft mit Verzögerung
                log_technical "Quick-Check: Running=0 (2×) – prüfe ob Backup abgeschlossen (Phase Idle)…"
                QUICK_PHASE=""
                for _wait in 5 5 5; do
                    sleep $_wait
                    QUICK_PHASE=$(tmutil status 2>/dev/null | LC_ALL=C tr -cd '\n\t\40-\176' | awk -F= '/BackupPhase/ {gsub(/["; ]/,"",$2); print $2}' | tr -cd 'A-Za-z')
                    if [ "$QUICK_PHASE" = "Idle" ] || [ "$QUICK_PHASE" = "idle" ]; then
                        log_technical "Quick-Check: Phase=$QUICK_PHASE – Backup fertig (nach ${_wait}s), warte auf Abschlussbestätigung (100%)"
                        break
                    fi
                done
                if [ "$QUICK_PHASE" = "Idle" ] || [ "$QUICK_PHASE" = "idle" ]; then
                    break
                fi
                # Sauber fertig vs abgebrochen: Apple-Log sagt, wie viele Dateien dieser Lauf sichern soll
                parse_apple_tm_log_for_run
                if [ "$HAD_PROGRESS" -eq 1 ] && [ -n "$APPLE_ESTIMATED_FILES" ] && [ "$APPLE_ESTIMATED_FILES" -gt 0 ] 2>/dev/null; then
                    # Kopierte Dateien >= erwartete (oder >= 95%) → Lauf fertig, nicht abgebrochen
                    _need=$(( APPLE_ESTIMATED_FILES * 95 / 100 ))
                    if [ -n "$LAST_LOGGED_FILES" ] && [ "$LAST_LOGGED_FILES" -ge "$_need" ] 2>/dev/null; then
                        INCREMENTAL_COMPLETED=1
                        log_technical "Quick-Check: ${LAST_LOGGED_FILES} von ${APPLE_ESTIMATED_FILES} Dateien (laut Apple) – Lauf fertig (nicht abgebrochen)"
                        break
                    fi
                    # Weniger als erwartet kopiert → wirklich abgebrochen
                elif [ "$HAD_PROGRESS" -eq 1 ] && [ -n "$LAST_LOGGED_TOTAL_FILES" ] && [ "$LAST_LOGGED_TOTAL_FILES" -gt 0 ] 2>/dev/null; then
                    # Fallback ohne Apple-Zahl: Heuristik (wenige % = Inkrementallauf fertig)
                    _pct=100
                    [ -n "$LAST_LOGGED_FILES" ] && [ "$LAST_LOGGED_FILES" -ge 0 ] 2>/dev/null && _pct=$(( LAST_LOGGED_FILES * 100 / LAST_LOGGED_TOTAL_FILES ))
                    if [ "$_pct" -lt 50 ] 2>/dev/null; then
                        INCREMENTAL_COMPLETED=1
                        log_technical "Quick-Check: Nur ${LAST_LOGGED_FILES} von ${LAST_LOGGED_TOTAL_FILES} Dateien – werten als Inkrementallauf fertig (nicht abgebrochen)"
                        break
                    fi
                fi
                if [ "$HAD_PROGRESS" -eq 1 ]; then
                    BACKUP_OUTCOME="vom Benutzer abgebrochen"
                    log_technical "Kein laufendes Backup mehr (Quick-Check, 2× bestätigt) – vom Benutzer abgebrochen"
                    log_user "Backup wurde von Ihnen abgebrochen."
                else
                    BACKUP_OUTCOME="von Time Machine übersprungen (z.B. keine Änderungen)"
                    log_technical "Kein laufendes Backup mehr (Quick-Check, 2× bestätigt) – übersprungen"
                    log_user "Backup wurde von Time Machine übersprungen (z.B. keine Änderungen nötig)."
                fi
                notify "Time Machine: ${BACKUP_OUTCOME}" "Time Machine"
                exit 0
            fi
        fi
        # Regelmäßig Fortschritt auslesen (alle PROGRESS_NOTIFY_INTERVAL s), mit Phase/Bytes/Dateien aus tmutil
        if [ "$SECS_SINCE_PROGRESS" -ge "$PROGRESS_NOTIFY_INTERVAL" ]; then
            SECS_SINCE_PROGRESS=0
            QUICK_STATUS=$(tmutil status 2>/dev/null | LC_ALL=C tr -cd '\n\t\40-\176')
            QUICK_PERCENT=$(printf '%s' "$QUICK_STATUS" | awk -F= '/Percent/ && /=/ {gsub(/["; ]/,"",$2); gsub(/,/,".",$2); v=$2+0; if (v>0 && v<=1) p=v*100; else if (v>1 && v<=100) p=v; else p=0; if (p>=0) print int(p)}' | sort -n | tail -1)
            QUICK_PERCENT=$(printf '%s' "${QUICK_PERCENT:-0}" | tr -cd '0-9\-')
            [ -z "$QUICK_PERCENT" ] && QUICK_PERCENT=0
            [ "$QUICK_PERCENT" -lt 0 ] 2>/dev/null && QUICK_PERCENT=0
            [ "$QUICK_PERCENT" -gt 100 ] 2>/dev/null && QUICK_PERCENT=100
            [ "$QUICK_PERCENT" -gt 0 ] 2>/dev/null && HAD_PROGRESS=1
            Q_FILES=$(printf '%s' "$QUICK_STATUS" | awk -F= '/[[:space:]]files[[:space:]]*=[[:space:]]/ && !/totalFiles/ {gsub(/["; ]/,"",$2); print $2+0}' | head -1)
            Q_TOTAL_F=$(printf '%s' "$QUICK_STATUS" | awk -F= '/totalFiles[[:space:]]*=/ {gsub(/["; ]/,"",$2); print $2+0}' | head -1)
            Q_BYTES=$(printf '%s' "$QUICK_STATUS" | awk -F= '/[[:space:]]bytes[[:space:]]*=[[:space:]]/ && !/totalBytes/ {gsub(/["; ]/,"",$2); print $2+0}' | head -1)
            Q_TOTAL=$(printf '%s' "$QUICK_STATUS" | awk -F= '/totalBytes[[:space:]]*=/ {gsub(/["; ]/,"",$2); print $2+0}' | head -1)
            [ -n "$Q_FILES" ] && [ "$Q_FILES" -ge 0 ] 2>/dev/null && LAST_LOGGED_FILES=$Q_FILES
            [ -n "$Q_TOTAL_F" ] && [ "$Q_TOTAL_F" -ge 0 ] 2>/dev/null && LAST_LOGGED_TOTAL_FILES=$Q_TOTAL_F
            # Prozent wie Time-Machine-UI: zuerst aus Bytes (Apple geschätzte Größe), sonst aus Dateien
            if [ -n "$APPLE_ESTIMATED_BYTES" ] && [ "$APPLE_ESTIMATED_BYTES" -gt 0 ] 2>/dev/null && [ -n "$Q_BYTES" ] && [ "$Q_BYTES" -ge 0 ] 2>/dev/null; then
                QUICK_PERCENT=$(( Q_BYTES * 100 / APPLE_ESTIMATED_BYTES ))
                [ "$QUICK_PERCENT" -gt 100 ] 2>/dev/null && QUICK_PERCENT=100
            elif [ -n "$APPLE_ESTIMATED_FILES" ] && [ "$APPLE_ESTIMATED_FILES" -gt 0 ] 2>/dev/null && [ -n "$Q_FILES" ] && [ "$Q_FILES" -ge 0 ] 2>/dev/null; then
                QUICK_PERCENT=$(( Q_FILES * 100 / APPLE_ESTIMATED_FILES ))
                [ "$QUICK_PERCENT" -gt 100 ] 2>/dev/null && QUICK_PERCENT=100
            fi
            # Nur Fortschritt > 0% loggen (0% z.B. MountingDiskImage oder beim Abschluss weglassen)
            if [ -n "$QUICK_PERCENT" ] && [ "$QUICK_PERCENT" -eq "$QUICK_PERCENT" ] 2>/dev/null && [ "$QUICK_PERCENT" -gt 0 ] 2>/dev/null; then
                if [ "$QUICK_PERCENT" -ne "${LAST_PROGRESS_PERCENT:--1}" ] 2>/dev/null; then
                    if ! { [ "$QUICK_PERCENT" -eq 0 ] 2>/dev/null && [ "${LAST_PROGRESS_PERCENT:--1}" -gt 0 ] 2>/dev/null; }; then
                        notify "Backup läuft: ${QUICK_PERCENT}% abgeschlossen" "Time Machine"
                        Q_PHASE=$(printf '%s' "$QUICK_STATUS" | awk -F= '/BackupPhase/ {gsub(/["; ]/,"",$2); print $2}' | tr -cd 'A-Za-z')
                        [ -n "$Q_BYTES" ] && [ "$Q_BYTES" -ge 0 ] 2>/dev/null && LAST_LOGGED_BYTES=$Q_BYTES
                        [ -n "$Q_TOTAL" ] && [ "$Q_TOTAL" -ge 0 ] 2>/dev/null && LAST_LOGGED_TOTAL_BYTES=$Q_TOTAL
                        log_tmutil_status "$QUICK_STATUS"
                        _q_total_f=${Q_TOTAL_F:-?}; [ -n "$APPLE_ESTIMATED_FILES" ] && [ "$APPLE_ESTIMATED_FILES" -gt 0 ] 2>/dev/null && _q_total_f="$APPLE_ESTIMATED_FILES (dieser Lauf)"
                        if [ -n "$Q_BYTES" ] && [ -n "$Q_TOTAL" ] && [ "$Q_BYTES" -ge 0 ] 2>/dev/null; then
                            Q_BH=$(human_bytes "$Q_BYTES"); Q_TH=$(human_bytes "$Q_TOTAL")
                            log_technical "Backup: ${QUICK_PERCENT}% | Phase: $Q_PHASE | $Q_BH / $Q_TH | ${Q_FILES:-?} / $_q_total_f Dateien"
                            log_user "Backup Fortschritt: ${QUICK_PERCENT}% ($Q_BH von $Q_TH, ${Q_FILES:-?} von $_q_total_f Dateien)"
                        else
                            log_technical "Backup Fortschritt: ${QUICK_PERCENT}% | Phase: $Q_PHASE | ${Q_FILES:-?} / $_q_total_f Dateien"
                            log_user "Backup Fortschritt: ${QUICK_PERCENT}% (${Q_FILES:-?} von $_q_total_f Dateien)"
                        fi
                        LAST_PROGRESS_PERCENT=$QUICK_PERCENT
                    fi
                fi
            fi
        fi
    done
    ELAPSED=$((ELAPSED + CHECK_INTERVAL))

done

# --- Erfolgsmeldung ---
notify "Time Machine Backup abgeschlossen!" "Time Machine"
log_both "Time Machine Backup erfolgreich abgeschlossen!"

# Finale Statistik loggen (kurz warten, damit tmutil den neuen Backup-Eintrag sieht)
sleep 3
LATEST_BACKUP=$(tmutil latestbackup 2>/dev/null)
if [ -z "$LATEST_BACKUP" ]; then
    sleep 2
    LATEST_BACKUP=$(tmutil latestbackup 2>/dev/null)
fi
if [ -n "$LATEST_BACKUP" ]; then
    log_technical "Letztes Backup: $LATEST_BACKUP"
    log_user "Backup gespeichert unter: $LATEST_BACKUP"
else
    log_technical "Letztes Backup: (tmutil latestbackup lieferte keinen Pfad – evtl. noch nicht im Katalog)"
    log_user "Backup abgeschlossen. Pfad im Systemkatalog ggf. erst kurz danach sichtbar."
fi

BACKUP_OUTCOME="erfolgreich abgeschlossen"
exit 0
