# Time Machine Backup auf NAS – Installation (Schritt für Schritt)

Diese Anleitung führt Sie **genau** durch die Einrichtung. Bitte **alle Schritte der Reihe nach** durchführen. Nichts überspringen.

---

## Was Sie brauchen

- Einen **Mac** mit macOS.
- Ein **NAS** (Netzwerkfestplatte) mit einer **SMB-Freigabe** (z. B. „TimeMachineBackup“).
- Die **IP-Adresse** oder den **Namen** Ihres NAS (z. B. `10.20.30.12` oder `meinnas.local`).

---

## Warum SMB und nicht AFP?

Wir nutzen bewusst **SMB** (Server Message Block) für die Verbindung zum NAS – **nicht** das ältere **AFP** (Apple Filing Protocol).

**Hintergrund:** Apple hat AFP als veraltet eingestuft und den Ausstieg angekündigt. In **macOS Sequoia 15.5** wurde die Abschaffung des AFP-Clients angekündigt; in einer künftigen macOS-Version wird AFP vollständig entfernt. Bereits seit **macOS 10.9 Mavericks (2013)** setzt Apple standardmäßig auf SMB. Gründe dafür: bessere Leistung und Sicherheit mit modernen SMB-Versionen, weniger Wartungsaufwand und bessere Kompatibilität mit NAS, Windows und Linux. Time Capsules und reine AFP-Backups werden mit dem Ende von AFP nicht mehr nativ mit Time Machine nutzbar sein. Apple stellt stattdessen eine **Time-Machine-SMB-Spezifikation** bereit, damit Backups über SMB-Freigaben laufen.

**Kurz:** Wer heute ein NAS für Time Machine einrichtet, sollte **SMB** verwenden, damit die Einrichtung auch mit künftigen macOS-Versionen funktioniert. Genau dafür ist dieses Skript ausgelegt (SMB-Mount, Sparsebundle auf der Freigabe).

---

## Ihr Benutzername (wird mehrfach gebraucht)

Sie müssen überall Ihren **Mac-Benutzernamen** eintragen. So finden Sie ihn:

1. Oben links auf das **Apfel-Symbol** klicken.
2. **„Systemeinstellungen“** (oder „Systemeinstellungen“) öffnen.
3. **„Benutzer & Gruppen“** (oder „Users & Groups“) öffnen.
4. Unter „Benutzer“ steht Ihr Name, z. B. **max** oder **josh**.

Der **Pfad** zu Ihrem Benutzerordner ist dann: **`/Users/IHRNAME`**  
Beispiel: Wenn Ihr Name **max** ist → `/Users/max`.  
**Merken Sie sich diesen Pfad.** Sie ersetzen damit überall **josh** (oder den bisherigen Namen) durch **Ihren** Namen.

---

# TEIL A: Konfiguration (alles anpassen, bevor Sie weitermachen)

## A1 – Datei „mount_timemachine.sh“ öffnen

1. Öffnen Sie den **Ordner „TimeMachine_Installation“** (dort, wo Sie diese Anleitung her haben).
2. **Rechtsklick** auf die Datei **`mount_timemachine.sh`**.
3. Wählen Sie **„Öffnen mit“** → **„TextEdit“** (oder einen anderen Texteditor).  
   – Falls Ihr Mac fragt „Aus unbekannter Quelle?“ → **„Öffnen“** bestätigen.

---

## A2 – Im Skript den Abschnitt „KONFIGURATION“ finden

1. Drücken Sie **Cmd + F** (Suchen).
2. Geben Sie ein: **KONFIGURATION**
3. Sie landen bei einem Block mit vielen Zeilen wie `CONFIG_HOME=`, `NAS_SERVER=` usw.  
   **Nur diese Zeilen ändern.** Sonst nichts im Skript anfassen.

---

## A3 – Zeile für Zeile anpassen (mount_timemachine.sh)

Ersetzen Sie **jeden** der folgenden Werte so, dass er **zu Ihrem Mac und Ihrem NAS** passt.  
**Tipp:** Suchen Sie mit Cmd+F nach dem Stichwort in Anführungszeichen.

| Was Sie suchen | Was Sie eintragen | Beispiel |
|----------------|-------------------|----------|
| `CONFIG_HOME="/Users/josh"` | Ihren Benutzerpfad | `CONFIG_HOME="/Users/max"` |
| `CONFIG_LOG_BASE="/Users/josh/Documents/..."` | Ihren Benutzerpfad + gleicher Rest | `CONFIG_LOG_BASE="/Users/max/Documents/Timemachine_logs"` |
| `NAS_SERVER="10.20.30.12"` | Die **IP-Adresse** oder den **Namen** Ihres NAS | `NAS_SERVER="192.168.1.100"` oder `NAS_SERVER="meinnas.local"` |
| `NAS_SHARE="TimeMachineBackup"` | Den **Namen der Freigabe** auf dem NAS (so wie er am NAS heißt) | z. B. `NAS_SHARE="TimeMachineBackup"` lassen oder anpassen |
| `NAS_SUBFOLDER=""` | Leer lassen, **wenn** die Backup-Datei direkt in der Freigabe liegt. Sonst den Unterordner-Namen in Anführungszeichen | `NAS_SUBFOLDER=""` oder `NAS_SUBFOLDER="Backups"` |
| `SPARSEBUNDLE_NAME="TimeMachine.sparsebundle"` | Den **genauen Dateinamen** der Backup-Datei auf dem NAS (mit .sparsebundle) | Meist so lassen: `TimeMachine.sparsebundle` |
| `NAS_USER="guest"` | **guest** für Gast-Zugriff, sonst Ihren NAS-Benutzernamen | `NAS_USER="guest"` oder `NAS_USER="admin"` |
| `NAS_PASS=""` | Leer für kein Passwort / Gast; sonst das Passwort in Anführungszeichen | `NAS_PASS=""` oder `NAS_PASS="meinpasswort"` |
| `MOUNTPOINT="/Volumes/TimeMachine"` | Kann so bleiben; nur ändern, wenn Sie einen anderen Laufwerksnamen wollen | Meist **nicht** ändern |

Die **Wartezeiten** (z. B. `NETWORK_WAIT_INTERVAL=5`, `MAX_BACKUP_HOURS=6`) können Sie so lassen. Sie bedeuten u. a.: wie oft zum NAS geprüft wird und wie lange ein Backup maximal dauern darf.

---

## A4 – Datei speichern

- **TextEdit:** Menü **„Ablage“** → **„Speichern“** (oder Cmd + S).
- Schließen Sie die Datei.

---

## A5 – Datei „com.user.timemachine-backup.plist“ öffnen

1. Im gleichen Ordner **TimeMachine_Installation** die Datei **`com.user.timemachine-backup.plist`** mit **TextEdit** (oder einem anderen Editor) öffnen.
2. Drücken Sie **Cmd + F** und suchen Sie nach: **josh**
3. **Jedes** Vorkommen von **`/Users/josh`** ersetzen Sie durch **Ihren** Pfad, z. B. **`/Users/max`**.  
   – Achten Sie darauf, dass Sie **nur** den Benutzernamen ersetzen und der Rest (z. B. `/Library/Logs/...`) gleich bleibt.
4. Datei **speichern** und schließen.

---

## A6 – (Optional) Wrapper und Sparsebundle-Skript

- **timemachine-backup-launch.sh:** Können Sie so lassen. Darin steht z. B. eine Wartezeit von 20 Sekunden vor dem Start; nur bei Bedarf anpassen.
- **sparsebundle_erstellen.sh:** Nur anpassen, wenn Sie das Sparsebundle **selbst** mit diesem Skript anlegen wollen. Dann dort **NAS_ORDNER** und **SPARSE_NAME** so setzen, dass sie zu Ihrem NAS und zum Namen in `mount_timemachine.sh` passen (SPARSEBUNDLE_NAME).

---

# TEIL B: Sparsebundle (nur wenn Sie das Backup-Ziel neu anlegen)

**Überspringen Sie diesen Teil**, wenn auf Ihrem NAS **bereits** eine Datei wie **TimeMachine.sparsebundle** existiert (also Time Machine dort schon eingerichtet war).

Wenn Sie **zum ersten Mal** ein Sparsebundle anlegen:

1. NAS-Freigabe im **Finder** verbinden („Gehe zu“ → „Mit Server verbinden“ → z. B. `smb://10.20.30.12/TimeMachineBackup`).
2. In **sparsebundle_erstellen.sh** die Konfiguration anpassen (NAS_ORDNER = Pfad, wo die Freigabe auf Ihrem Mac erscheint; SPARSE_NAME = gleicher Name wie SPARSEBUNDLE_NAME in mount_timemachine.sh).
3. **Terminal** öffnen (Programme → Dienstprogramme → Terminal).
4. In den Ordner wechseln, in dem **sparsebundle_erstellen.sh** liegt, z. B.:
   ```bash
   cd ~/Desktop/TimeMachine_Installation
   ```
   (Ersetzen Sie den Pfad durch den Ort, an dem Ihr Ordner wirklich liegt.)
5. Skript ausführbar machen und starten:
   ```bash
   chmod +x sparsebundle_erstellen.sh
   ./sparsebundle_erstellen.sh
   ```
6. Warten, bis „Fertig“ erscheint. Danach die Freigabe wieder trennen (Finder: neben dem Laufwerk auf „Auswerfen“ klicken).

**Alternative:** In der Datei **SPARSEBUNDLE_BEFEHL.txt** steht der reine Befehl zum Erzeugen des Sparsebundles; Pfad und Größe müssen Sie darin anpassen und den Befehl im Terminal ausführen.

---

# TEIL C: Skripte nach ~/bin legen

Das Hauptskript **muss** im Ordner **~/bin** liegen, damit es nach einem Neustart zuverlässig startet.

1. **Terminal** öffnen (Programme → Dienstprogramme → Terminal).
2. Diese **vier Zeilen nacheinander** eintippen (oder kopieren und einfügen) und nach jeder Zeile **Enter** drücken:

```bash
mkdir -p ~/bin
cp ~/Desktop/TimeMachine_Installation/mount_timemachine.sh ~/bin/
cp ~/Desktop/TimeMachine_Installation/timemachine-backup-launch.sh ~/bin/
chmod +x ~/bin/mount_timemachine.sh ~/bin/timemachine-backup-launch.sh
```

**Wichtig:** Ersetzen Sie **`~/Desktop/TimeMachine_Installation`** durch den **tatsächlichen Pfad**, in dem Ihr Ordner **TimeMachine_Installation** liegt.  
Beispiele:
- Liegt auf dem Desktop: `~/Desktop/TimeMachine_Installation`
- Liegt in Downloads: `~/Downloads/TimeMachine_Installation`
- Liegt woanders: z. B. `~/Documents/TimeMachine_Installation`

Zum Prüfen: Im Finder zum Ordner gehen, dann die Ordner-Icon in die Titelleiste des Fensters ziehen – oft zeigt der Mac dann den Pfad. **/Users/IHRNAME/...** ersetzen Sie durch **~** im Terminal, also z. B. `~/Desktop/TimeMachine_Installation`.

---

# TEIL D: LaunchAgent einrichten (automatischer Start)

Damit das Backup **beim Anmelden** und **alle 2 Stunden** automatisch startet:

1. **Terminal** öffnen.
2. Plist in den LaunchAgents-Ordner kopieren (Pfad anpassen, wo Ihre **TimeMachine_Installation** liegt):

```bash
cp ~/Desktop/TimeMachine_Installation/com.user.timemachine-backup.plist ~/Library/LaunchAgents/
```

3. Agent laden:

```bash
launchctl load ~/Library/LaunchAgents/com.user.timemachine-backup.plist
```

4. Prüfen, ob er geladen ist:

```bash
launchctl list | grep timemachine
```

Es sollte eine Zeile mit **com.user.timemachine-backup** erscheinen.

5. **Backup sofort einmal starten** (ohne auf Anmeldung oder 2 Stunden zu warten):

```bash
launchctl start com.user.timemachine-backup
```

---

# TEIL E: Time Machine nur mit diesem Skript (empfohlen)

Damit Time Machine **nicht** stündlich von selbst startet, sondern **nur** über dieses Skript (beim Anmelden + alle 2 Stunden):

Im **Terminal** ausführen:

```bash
defaults write com.apple.TimeMachine AutoBackup -bool false
```

Falls Sie später wieder die **normale** stündliche Time-Machine-Automatik wollen:

```bash
defaults write com.apple.TimeMachine AutoBackup -bool true
```

---

# Wo finde ich die Logs?

- **Technische Logs:** Im Ordner, den Sie bei **CONFIG_LOG_BASE** eingetragen haben, Unterordner **Technical**.  
  Beispiel: `/Users/max/Documents/Timemachine_logs/Technical/`
- **Benutzer-Logs:** Gleicher Ordner wie CONFIG_LOG_BASE, Unterordner **Benutzer**.
- **Fehler des automatischen Starts:**  
  `~/Library/Logs/timemachine-backup-stderr.log`  
  (dort steht Ihr Benutzername statt ~).

---

# Kurz-Übersicht: Wichtige Befehle

| Was Sie tun wollen | Befehl (im Terminal ausführen) |
|--------------------|--------------------------------|
| Backup jetzt einmal starten | `launchctl start com.user.timemachine-backup` |
| Agent neu laden (nach Änderung der plist) | `launchctl unload ~/Library/LaunchAgents/com.user.timemachine-backup.plist` und danach `launchctl load ~/Library/LaunchAgents/com.user.timemachine-backup.plist` |
| Alle Backups anzeigen | `tmutil listbackups` |
| Neuestes Backup anzeigen | `tmutil latestbackup` |

---

# Checkliste vor dem Weitergeben

Wenn Sie diesen Ordner **weitergeben**, hat der neue Nutzer alles Nötige, wenn er:

1. In **mount_timemachine.sh** den gesamten **KONFIGURATION**-Block auf **seinen** Benutzer, **sein** NAS und **seine** Freigabe angepasst hat.
2. In **com.user.timemachine-backup.plist** **jedes** `/Users/...` durch **seinen** Benutzerpfad ersetzt hat.
3. Die Schritte **TEIL C** und **TEIL D** mit **seinem** Pfad zu **TimeMachine_Installation** ausführt.

**Original-Dateien** (z. B. Ihr eigenes mount_timemachine.sh außerhalb dieses Ordners) werden von dieser Anleitung **nicht** geändert – es wird nur mit den **Kopien in diesem Installationsordner** gearbeitet.
