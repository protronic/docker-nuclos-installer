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
| Sage-Datenbankname | Enter (`OLReweAbf`, Sage-Standard) |
| SQL-Benutzer für Nuclos | Enter (`nuclos_ro`, wird mit `sage100/01-*.sql` angelegt) |
| Login / Passwort für Verbindungstest | z.B. `sa` + Passwort – oder Passwort leer lassen = Test überspringen |
| Mandant | Enter (erster gefundener) oder Mandantennummer |
| tds_fdw einrichten? | `J` (DB-Image wird einmalig mit dem MS-SQL Foreign Data Wrapper gebaut) |
| Passwort von `nuclos_ro` (User-Mapping) | Passwort aus `sage100/01-*.sql` – oder Enter und später in `sage100-fdw.sql` eintragen |

Der Installer prüft, ob der Sage-Server erreichbar ist, testet auf Wunsch die SQL-Anmeldung (listet Datenbanken und Mandanten auf), baut das DB-Image, startet die Container und führt das FDW-Setup automatisch aus, sobald die Datenbank bereit ist.

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

Nuclos-Datenquellen laufen immer gegen die Nuclos-eigene PostgreSQL-DB (externe JDBC-Verbindungen gibt es dafür nicht). Deshalb werden die Sage-Daten per Foreign Data Wrapper `tds_fdw` in die Nuclos-DB geholt – in zwei Schritten:

**A. Auf dem Sage-/MS-SQL-Server** (einmalig, macht der Sage-/DB-Admin, am besten **vor** der Installation):

1. TCP/IP im *SQL Server Configuration Manager* aktivieren, Port 1433; SQL-Server-Authentifizierung (Mixed Mode) einschalten; Firewall: Port 1433 für den Docker-Host freigeben
2. In SSMS ausführen: [`sage100/01-nuclos-readonly-login.sql`](sage100/01-nuclos-readonly-login.sql) (Read-only-Login `nuclos_ro`, Passwort im Skript anpassen!) und [`sage100/02-nuclos-views.sql`](sage100/02-nuclos-views.sql) (Schema `nuclos` mit Views auf Adressen, Kunden, Lieferanten, Artikel, Belege)

**B. In der Nuclos-DB** – macht `install.sh` automatisch, wenn „tds_fdw einrichten“ mit `J` und das Passwort von `nuclos_ro` angegeben wurde. Ergebnis prüfen:

```bash
ls nuclos-db-exchange/logs/                                   # Protokoll des FDW-Setups
docker exec -it nuc-db psql -U nuclos -d nuclosdb -c "SELECT count(*) FROM sage.kunden"
```

Ohne Passwort bei der Installation: Passwort in `sage100-fdw.sql` eintragen und `cp sage100-fdw.sql nuclos-db-exchange/` – der DB-Container führt die Datei automatisch aus.

**C. In Nuclos** (Desktop-Client, Konfiguration → Datenquellen): Abfragen aus [`sage100/03-nuclos-datenquellen-beispiele.sql`](sage100/03-nuclos-datenquellen-beispiele.sql) anlegen, z.B.

```sql
SELECT mandant, kto AS kundennummer, matchcode FROM sage.kunden WHERE mandant = 1
```

und darauf dynamische Entitäten aufbauen. Damit das Schema `sage` versioniert mit dem Nuclet wandert: [`sage100/11-sqlkonfiguration-sage-schema.sql`](sage100/11-sqlkonfiguration-sage-schema.sql) als **SQL-Konfiguration** (Konfiguration → Datenbank → SQL-Konfigurationen, Tag `POSTGRESQL`) anlegen. Details: [sage100/README.md](sage100/README.md)

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
| FDW-Setup fehlgeschlagen | Protokoll in `nuclos-db-exchange/logs/` lesen (typisch: Sage-Server nicht erreichbar, Login/Passwort falsch, Skript 02 auf dem Sage-Server noch nicht ausgeführt) – korrigierte `sage100-fdw.sql` erneut nach `nuclos-db-exchange/` kopieren |
| Produktivbetrieb aus dem Internet | Nur hinter Reverse-Proxy! Beispiel: [Beipiel-NGINX-Config.txt](Beipiel-NGINX-Config.txt) |
