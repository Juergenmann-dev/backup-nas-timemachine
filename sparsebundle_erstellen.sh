#!/bin/zsh
#
# Legt einmalig ein Time-Machine-Sparsebundle auf dem NAS an.
# Vor dem Ausführen: Konfiguration unten anpassen (NAS-Pfad, Größe, Name).
# NAS muss erreichbar sein (z. B. manuell verbinden oder nach mount_timemachine.sh-Konfiguration).
#

# ========== KONFIGURATION (anpassen) ==========
# Wo das Sparsebundle liegen soll (Pfad auf dem bereits gemounteten NAS).
# Beispiele:
#   "$HOME/.timemachine_nas/TimeMachineBackup"     wenn Sie die gleiche Freigabe wie mount_timemachine.sh nutzen
#   "/Volumes/TimeMachineBackup"                   wenn Sie die Freigabe im Finder verbunden haben
NAS_ORDNER="${HOME}/.timemachine_nas/TimeMachineBackup"
# Unterordner auf dem NAS (leer = direkt in NAS_ORDNER)
SPARSE_UNTERORDNER=""
# Dateiname des Sparsebundles (muss zu SPARSEBUNDLE_NAME in mount_timemachine.sh passen)
SPARSE_NAME="TimeMachine.sparsebundle"
# Logische Größe: so viel „Platz“ sieht Time Machine (z. B. 500g). Auf dem NAS wird nur belegt, was wirklich geschrieben wird.
SPARSE_GROESSE="500g"
# =============================================

if [ -n "$SPARSE_UNTERORDNER" ]; then
    ZIEL_ORDNER="$NAS_ORDNER/$SPARSE_UNTERORDNER"
else
    ZIEL_ORDNER="$NAS_ORDNER"
fi
TARGET="$ZIEL_ORDNER/$SPARSE_NAME"

echo "Sparsebundle wird erstellt: $TARGET"
echo "Logische Größe: $SPARSE_GROESSE (auf dem NAS wächst nur der tatsächlich genutzte Platz)."
echo ""

if [ ! -d "$NAS_ORDNER" ]; then
    echo "FEHLER: NAS-Ordner nicht gefunden: $NAS_ORDNER"
    echo "Bitte zuerst das NAS verbinden (z. B. Freigabe im Finder verbinden oder mount_timemachine.sh-Konfiguration prüfen)."
    exit 1
fi

if [ -n "$SPARSE_UNTERORDNER" ] && [ ! -d "$ZIEL_ORDNER" ]; then
    echo "Erstelle Ordner: $ZIEL_ORDNER"
    mkdir -p "$ZIEL_ORDNER" || { echo "Konnte Ordner nicht anlegen."; exit 1; }
fi

if [ -e "$TARGET" ]; then
    echo "FEHLER: Dort existiert bereits: $TARGET"
    echo "Löschen oder anderen Namen wählen."
    exit 1
fi

echo "Erstelle Sparsebundle (kann einen Moment dauern)..."
hdiutil create -size "$SPARSE_GROESSE" -type SPARSEBUNDLE -fs HFS+J -volname "Time Machine" -layout SPUD -ov "$TARGET"

if [ $? -eq 0 ]; then
    echo ""
    echo "Fertig. Sparsebundle liegt unter: $TARGET"
    echo "Jetzt in mount_timemachine.sh NAS_SUBFOLDER/SPARSEBUNDLE_NAME anpassen (falls nötig) und Skript/LaunchAgent einrichten."
else
    echo "Erstellen fehlgeschlagen."
    exit 1
fi
