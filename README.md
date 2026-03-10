# Time Machine Backup auf NAS (SMB)

Skript-Setup für **Time-Machine-Backups auf ein NAS** über **SMB** (nicht AFP). Startet automatisch beim Anmelden und alle 2 Stunden. **Einmal einrichten – den Rest erledigt das Skript.** Auch Backups, die Sie per „Jetzt sichern“ starten, werden in derselben Log-Struktur erfasst.

---

## Was macht das Projekt?

- Verbindet Ihr **NAS** per **SMB** (Server Message Block).
- Mountet ein **Sparsebundle** (die Time-Machine-Backup-Datei) auf dem Mac.
- Startet **Time Machine** und überwacht den Fortschritt.
- Schreibt **Logs** (technisch + benutzerfreundlich) in eine klare Ordnerstruktur: **Jahr → Monat → KW → Tag**.
- Läuft per **LaunchAgent** beim Login und alle 2 Stunden; ein **Watcher** erkennt „Jetzt sichern“ und loggt ebenfalls.
- **Timeouts** für Mount-Befehle verhindern, dass der Mac bei NAS-Ausfall hängen bleibt.

**Warum SMB?** Apple hat AFP (Apple Filing Protocol) als veraltet angekündigt und stellt es in zukünftigen macOS-Versionen ein. SMB ist der empfohlene Weg für Time Machine auf dem Netzwerk – siehe [INSTALL.md](INSTALL.md#warum-smb-und-nicht-afp).

---

## Voraussetzungen

- **macOS** (getestet mit aktuellen Versionen)
- **NAS** mit **SMB-Freigabe** (z. B. TimeMachineBackup)
- IP oder Hostname des NAS

---

## Schnellstart

1. **Repository klonen** oder als ZIP herunterladen.
2. **[INSTALL.md](INSTALL.md)** öffnen und **Schritt für Schritt** durchgehen (Konfiguration anpassen, Skripte nach `~/bin`, LaunchAgents einrichten).
3. In **mount_timemachine.sh** im Abschnitt **KONFIGURATION** Ihren Benutzer, NAS-Adresse, Freigabe und Log-Pfad eintragen.
4. In beiden Plist-Dateien alle `/Users/...`-Pfade durch Ihren Benutzerpfad ersetzen.
5. Beide LaunchAgents laden (siehe [Nützliche Befehle](#nützliche-befehle)).

Ausführliche Anleitung: **[INSTALL.md](INSTALL.md)**.

---

## Inhalte des Repositories

| Datei | Beschreibung |
|-------|--------------|
| **mount_timemachine.sh** | Hauptskript: NAS verbinden, Sparsebundle mounten, Time Machine starten & überwachen (inkl. Timeouts, Log-Struktur) |
| **timemachine-backup-launch.sh** | Wrapper mit 20 s Verzögerung (für LaunchAgent) |
| **timemachine-backup-watcher.sh** | Erkennt Backups, die vom System gestartet wurden (z. B. „Jetzt sichern“), und schreibt dieselbe Log-Struktur |
| **timemachine-backup-now.sh** | Manuelles „Backup jetzt“ mit gleichem Ablauf und Logs (optional) |
| **timemachine-launchctl-reload.sh** | LaunchAgents entladen und mit `bootstrap` neu laden (für neueres macOS) |
| **sparsebundle_erstellen.sh** | Legt einmalig das Sparsebundle auf dem NAS an |
| **SPARSEBUNDLE_BEFEHL.txt** | Reiner `hdiutil create`-Befehl zum manuellen Anlegen |
| **com.user.timemachine-backup.plist** | LaunchAgent: Backup beim Login + alle 2 h |
| **com.user.timemachine-backup-watcher.plist** | LaunchAgent: Watcher alle 10 s (loggt „Jetzt sichern“) |
| **INSTALL.md** | Detaillierte Installationsanleitung (Schritt für Schritt) |
| **README.md** | Diese Datei |

### Log-Ordnerstruktur

Logs liegen unter `~/Documents/Timemachine_logs/` (oder dem in der Konfiguration gesetzten Pfad), unterteilt in:

- **Technical/** und **Benutzer/** (technische Details vs. verständliche Meldungen)
- **Jahr (YYYY)** → **Monat (YYYY-MM)** → **KW (Kalenderwoche)** → **Tag (YYYY-MM-DD)**

Beispiel: `Timemachine_logs/Technical/2026/2026-03/KW10/2026-03-06/`. Bestehende Ordner und Log-Dateien werden nicht überschrieben.

---

## Konfiguration (Überblick)

In **mount_timemachine.sh** im Block **KONFIGURATION** können Sie anpassen:

- **LOG_BASE** – Basisordner für Logs (darin: Technical/ und Benutzer/, unterteilt in Jahr/Monat/KW/Tag)
- **NAS_SERVER**, **NAS_SHARE**, **NAS_SUBFOLDER** – NAS und Freigabe
- **SPARSEBUNDLE_NAME**, **NAS_USER**, **NAS_PASS**, **MOUNTPOINT**
- **SMB_MOUNT_TIMEOUT**, **HDIUTIL_ATTACH_TIMEOUT** – Timeouts (Sekunden), damit blockierende Mounts den Mac nicht einfrieren
- **Wartezeiten:** z. B. `NETWORK_WAIT_INTERVAL`, `MAX_BACKUP_HOURS`, `CHECK_INTERVAL` usw.

Alles Weitere steht in [INSTALL.md](INSTALL.md).

---

## Nützliche Befehle

```bash
# Plists kopieren und LaunchAgents einrichten (einmalig)
cp ~/bin/com.user.timemachine-backup.plist ~/Library/LaunchAgents/
cp ~/bin/com.user.timemachine-backup-watcher.plist ~/Library/LaunchAgents/

# LaunchAgents laden (neueres macOS: bootstrap; bei „Load failed: 5“ zuerst entladen)
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.timemachine-backup.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.timemachine-backup-watcher.plist

# Oder alles in einem Schritt: entladen, kopieren, neu laden
~/bin/timemachine-launchctl-reload.sh

# Backup jetzt starten (geplanter Lauf mit vollem Ablauf)
launchctl start com.user.timemachine-backup

# Optional: Backup sofort ohne 20 s Verzögerung
~/bin/timemachine-backup-now.sh

# Prüfen, ob beide Agents geladen sind
launchctl list | grep timemachine

# LaunchAgents entladen (z. B. vor Neuinstallation)
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.user.timemachine-backup.plist
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.user.timemachine-backup-watcher.plist

# Backups anzeigen
tmutil listbackups
tmutil latestbackup
```

---

## Lizenz

[MIT](LICENSE) – siehe Datei **LICENSE** im Repository.
