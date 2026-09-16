# Quickstart – Nuclos in Docker (parallel zu Sage 100 / MS-SQL)

In 10 Minuten von null zur laufenden Nuclos-Instanz. Details und Hintergründe: [README.md](README.md)

## 1. Voraussetzungen

- Linux-Server mit **Docker** inkl. **Compose-Plugin v2** (`docker compose version`)
- mind. **4 GB RAM** frei (Server + Datenbank)
- Internetzugang zu Docker Hub und Maven Central
- Für die Sage-100-Anbindung: Hostname/IP des Sage-100-Servers, MS-SQL-Port (Standard 1433) dort per Firewall vom Docker-Host aus erreichbar

## 2. Installieren

```bash
sudo mkdir -p /opt/nuclos && cd /opt/nuclos
sudo curl -fLO https://raw.githubusercontent.com/protronic/docker-nuclos-installer/main/install.sh
sudo chmod +x install.sh
sudo ./install.sh
```

Das Script fragt alles interaktiv ab – **Enter übernimmt jeweils den Vorschlag**:

| Frage | Empfehlung |
|---|---|
| Container-Präfix | Enter (`nuc`) |
| Nuclos-Server Tag | Enter (`latest`) oder feste Version, z.B. `4.2026.28` |
| Nuclos-DB Tag | Enter (`17.6`) |
| DB-Schema | Enter (`nuclos`) |
| DB-Passwort | Enter (generiertes Passwort wird angezeigt und in `secrets/db_password` gespeichert) |
| RAM Server / DB | Enter (4 / 2 GB) |
| Zeitzone / Locale | Enter |
| HTTP-Port | Enter (freier Port wird vorgeschlagen, z.B. 8080) |
| Sage 100 / MS-SQL vorbereiten? | `J` |
| MS-SQL Host | Hostname/IP des **Sage-100-Servers** |
| MS-SQL Port | Enter (1433) |
| Sage-Datenbankname | Name der Sage-100-Datenbank |

Der Installer prüft direkt, ob der Sage-Server auf dem MS-SQL-Port erreichbar ist, lädt den MS-SQL-JDBC-Treiber und startet die Container.

## 3. Ersten Start abwarten

Der **erste Start dauert einige Minuten** (automatisches Datenbank-Setup):

```bash
docker compose logs -f server     # Strg+C beendet nur die Anzeige
```

Fertig, sobald der Tomcat-Start durchgelaufen ist bzw. `docker compose ps` den Server als *healthy* zeigt.

## 4. Anmelden

- Webclient: `http://<docker-host>:<port>`
- Startseite mit Link zum Desktop-Client (Nuclos Launcher): `http://<docker-host>:<port>/nuclos`
- Benutzer **`nuclos`** mit **leerem Passwort** → **sofort ein Passwort setzen!**

## 5. Sage 100 anbinden

Vorbereitung auf dem Sage-/MS-SQL-Server (einmalig, macht der Sage-/DB-Admin):

1. TCP/IP im *SQL Server Configuration Manager* aktivieren, Port 1433
2. SQL-Server-Authentifizierung (Mixed Mode) und eigenen SQL-Login anlegen, empfohlen **nur lesend** (`db_datareader`) auf die Sage-Datenbank
3. Firewall: Port 1433 für den Docker-Host freigeben

Dann in Nuclos (Desktop-Client) unter **Administration → Datenbankverbindungen** eine neue Verbindung anlegen – die Werte gibt der Installer am Ende fertig aus:

```
Treiber-Klasse: com.microsoft.sqlserver.jdbc.SQLServerDriver
JDBC-URL:       jdbc:sqlserver://<sage-server>:1433;databaseName=<SageDB>;encrypt=true;trustServerCertificate=true
Benutzer:       <SQL-Login mit Lesezugriff>
```

Der Treiber liegt schon in `nuclos-extensions/server/` und wird beim Serverstart automatisch geladen. Danach stehen die Sage-Daten z.B. für Datenquellen und dynamische Entitäten zur Verfügung.

## 6. Die wichtigsten Befehle

Alle Befehle im Installationsverzeichnis (z.B. `/opt/nuclos`) ausführen:

```bash
docker compose ps                 # Status
docker compose logs -f server     # Server-Logs
docker compose down               # Stoppen
docker compose up -d              # Starten
./backup-db.sh                    # Datenbank-Backup (für Cron geeignet)
./backup-instanz.sh               # Vollbackup (stoppt Container kurz)
./upgrade.sh                      # Update auf neuen Image-Tag (mit Backup vorher)
```

Tägliches DB-Backup per Cron (2:00 Uhr):

```cron
0 2 * * * cd /opt/nuclos && ./backup-db.sh >> logs/backup.log 2>&1
```

## Wenn etwas hakt

| Problem | Lösung |
|---|---|
| Webclient lädt nicht direkt nach der Installation | Erster Start dauert mehrere Minuten → `docker compose logs -f server` abwarten |
| Port schon belegt | `install.sh` erneut ausführen und anderen Port wählen, oder `NUCLOS_PORT` in `.env` ändern und `docker compose up -d` |
| Sage-Server nicht erreichbar | Vom Docker-Host testen: `bash -c 'exec 3<>/dev/tcp/<sage-server>/1433' && echo OK` – schlägt das fehl: Firewall/TCP-IP/Namensauflösung prüfen |
| DB-Passwort ändern | `secrets/db_password` editieren, dann `docker compose down && docker compose up -d` (wird beim Start automatisch übernommen) |
| Produktivbetrieb aus dem Internet | Nur hinter Reverse-Proxy! Beispiel: [Beipiel-NGINX-Config.txt](Beipiel-NGINX-Config.txt) |
