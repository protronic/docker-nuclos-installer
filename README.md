# docker-nuclos-installer

Automatische dockerbasierte Nuclos-Installation auf Basis der offiziellen Docker-Hub-Images von nuccess:

- [nuccess/nuclos-server](https://hub.docker.com/r/nuccess/nuclos-server) – Nuclos Applikationsserver
- [nuccess/nuclos-db](https://hub.docker.com/r/nuccess/nuclos-db) – PostgreSQL-Systemdatenbank für Nuclos

Ausgelegt für den **Parallelbetrieb mit Sage 100 / MS-SQL**: Nuclos läuft in Docker neben dem Sage-100-Server und bindet die Sage-Daten über den PostgreSQL Foreign Data Wrapper `tds_fdw` lesend in seine eigene Datenbank ein.

# !!! A C H T U N G !!! für einen produktiven Betrieb ausschließlich hinter einem Reverseproxyserver wie z.B. nginx (siehe `Beipiel-NGINX-Config.txt`)

## Was ist neu (09/2026)

- **Kein Installer-JAR, kein eigener Nuclos-Build mehr.** Es werden die fertigen, signierten Images `nuccess/nuclos-server` und `nuccess/nuclos-db` von Docker Hub verwendet (die DB bekommt nur einen dünnen lokalen Layer für `tds_fdw`).
- **Upgrade = Image-Tag wechseln** (`upgrade.sh`), die Datenbank-Migration läuft beim Start automatisch (AutoDbSetup).
- **DB-Passwort als Secret-Datei** (`./secrets/db_password`) statt im Klartext in `.env` – Vorgabe der nuccess-Images ab 4.2024.25.
- **Sage 100 / MS-SQL-Anbindung:** Das DB-Image bekommt den Foreign Data Wrapper `tds_fdw`; die Sage-Views erscheinen als Schema `sage` in der Nuclos-DB und stehen Datenquellen/dynamischen Entitäten direkt zur Verfügung. Sage-seitige SQL-Skripte und Nuclet-SQL-Konfiguration liegen in [`sage100/`](sage100/README.md). Der Microsoft-JDBC-Treiber in `./nuclos-extensions/server/` dient Java-Regeln.
- `install-nuc-all.sh` ist veraltet und leitet nur noch auf `install.sh` weiter.

## Architektur / Parallelbetrieb mit Sage 100 und MS-SQL

Sage 100 und der MS-SQL-Server laufen auf einem **eigenen Server**, Nuclos in Docker auf dem Docker-Host daneben:

```
┌───── Sage-100-Server ─────┐              ┌────────────── Docker-Host ──────────────┐
│  Sage 100                 │              │  ┌───────────────────────┐              │
│  MS-SQL Server (1433)     │              │  │ nuccess/nuclos-server │              │
│   Schema "nuclos"         │              │  │ (Port 8080 → Host)    │              │
│   (Views, nur lesend)     │              │  └───────────┬───────────┘              │
│        ▲                  │              │              │ Datenquellen: sage.*     │
│        │  tds_fdw (TDS)   │              │  ┌───────────▼───────────┐              │
│        └──────────────────┼──────────────┼──│ nuclos-db (PostgreSQL)│              │
│                           │              │  │ + tds_fdw → Schema    │              │
└───────────────────────────┘              │  │   "sage" (Fremdtab.)  │              │
                                           │  └───────────────────────┘              │
                                           └─────────────────────────────────────────┘
```

Wichtig zu wissen:

- Die nuccess-Images unterstützen als **Nuclos-Systemdatenbank ausschließlich PostgreSQL**. Datenbankname (`nuclosdb`) und Benutzer (`nuclos`) sind im Image fest vorgegeben; konfigurierbar sind Schema und Passwort. Die Sage-100/MS-SQL-Datenbank kann und soll **nicht** als Systemdatenbank dienen.
- **Nuclos kennt für Datenquellen keine externen JDBC-Verbindungen** – Datenquellen laufen immer gegen die Nuclos-DB. Deshalb holt der PostgreSQL Foreign Data Wrapper [tds_fdw](https://github.com/tds-fdw/tds_fdw) die Sage-Daten in die Nuclos-DB: `install.sh` baut das DB-Image als dünnen Layer auf `nuccess/nuclos-db` mit tds_fdw (`nuclos-db.Dockerfile`) und führt das FDW-Setup (`sage100-fdw.sql`: Foreign Server, User-Mapping, `IMPORT FOREIGN SCHEMA nuclos … INTO sage`) automatisch über `nuclos-db-exchange/` aus. In Nuclos dann z.B. `SELECT kto, matchcode FROM sage.kunden WHERE mandant = 1`.
- **Sage-seitig** legen die Skripte in [`sage100/`](sage100/README.md) den Read-only-Login `nuclos_ro` und ein Schema `nuclos` mit Views auf Adressen, Kunden/Lieferanten, Artikel und Belege an (Spaltenlisten dynamisch aus `INFORMATION_SCHEMA`, passend zur Sage-Version). Nur diese Views werden eingebunden – nie die Rohtabellen, nie schreibend.
- **SQL-Konfigurationen (Nuclos):** SQL, das Nuclos beim Nuclet-Import gegen seine eigene DB ausführt (Reihenfolge, Tags je DB-Typ, Prüfsumme → nur bei Änderung). Damit wandert das Einlesen des Schemas `sage` versioniert mit dem Nuclet von Test nach Prod (`sage100/11-sqlkonfiguration-sage-schema.sql`, Konfiguration → Datenbank → SQL-Konfigurationen).
- **Verbindungstest im Installer:** `install.sh` fragt Sage-Server, Port, Datenbank (Standard `OLReweAbf`) und den SQL-Benutzer für Nuclos (Standard `nuclos_ro`) ab. Optional prüft es mit einem SQL-Login die Anmeldung wirklich (Wegwerf-Container `mcr.microsoft.com/mssql-tools`, nichts wird installiert, Passwort wird nicht gespeichert), listet die Datenbanken auf, erkennt die Sage-100-Struktur und zeigt die **Mandanten** zur Auswahl. Ergebnis landet in `.env` (`SAGE_MSSQL_*`).
- **Netzwerk:** Der Docker-Host muss den Sage-100-Server auf Port 1433 erreichen (Firewall-Freigabe, Namensauflösung); auf dem SQL Server muss TCP/IP aktiviert und SQL-Server-Authentifizierung (Mixed Mode) eingeschaltet sein. Sonderfall: läuft MS-SQL doch auf dem Docker-Host selbst, als Host `host.docker.internal` verwenden (in der erzeugten `docker-compose.yml` bereits eingerichtet).
- **Keine Portkonflikte:** Nuclos belegt einen freien HTTP-Port ab 8080, der PostgreSQL-Container wird nicht am Host veröffentlicht, der Sage-Server bleibt unberührt.

## Installation

➡️ **Schritt-für-Schritt-Anleitung: [QUICKSTART.md](QUICKSTART.md)**

Voraussetzungen: Docker inkl. Compose-Plugin (v2), mind. 4 GB RAM (empfohlen mehr), Internetzugang zu Docker Hub und Maven Central.

```bash
mkdir -p /opt/<mein-nuclos-verzeichnis> && cd /opt/<mein-nuclos-verzeichnis>
# install.sh hierher kopieren, dann:
./install.sh
```

Das Script fragt interaktiv u.a. ab: Container-Präfix, Image-Tags (z.B. `latest` oder festgepinnt `4.2026.28`), DB-Schema, DB-Passwort (Vorschlag wird generiert), RAM, HTTP-Port (freier Port wird vorgeschlagen) und die Sage-100/MS-SQL-Parameter. Mit `./install.sh --no-start` wird nur die Konfiguration erzeugt, ohne die Container zu starten.

Der **erste Start dauert mehrere Minuten** (automatisches Datenbank-Setup): `docker compose logs -f server`

Danach erreichbar unter:

- Webclient: `http://<server-ip>:<port>`
- Startseite (mit Link zum Desktop-Client/Launcher): `http://<server-ip>:<port>/nuclos`
- Standard-Benutzer `nuclos` mit leerem Passwort → sofort ändern!

## Erzeugte Dateien und Verzeichnisse

| Datei / Ordner | Zweck |
|---|---|
| `.env` | Zentrale Konfiguration (Tags, Port, Schema, RAM, Sage-Parameter) |
| `docker-compose.yml` | Compose-Stack (db + server) |
| `nuclos-db.Dockerfile` | Dünner Layer auf `nuccess/nuclos-db`, installiert bei `TDS_FDW=true` den MS-SQL Foreign Data Wrapper |
| `sage100-fdw.sql` | FDW-Setup für die Nuclos-DB (enthält das Sage-Passwort, Rechte 600) |
| `secrets/db_password` | Datenbank-Passwort (Secret-Datei, nicht in `.env`!) |
| `.gitignore` | Wird miterzeugt: Secrets, `.env` und alle Laufzeitdaten sind vom Einchecken ausgeschlossen |
| `sage100/` (im Repo) | SQL-Skripte: Sage-Server (Login, Views), Nuclos-DB (tds_fdw), Nuclet-SQL-Konfiguration, Datenquellen-Beispiele |
| `nuclos-pgdata/` | PostgreSQL-Daten |
| `nuclos-data/` | Dokumente, Suchindex, Logs, Nuclet-Autoimport |
| `nuclos-extensions/server/` | Server-Extensions, u.a. der MS-SQL JDBC-Treiber |
| `nuclos-backups/` | Ablage des Nuclos-DockerBackup-Jobs |
| `nuclos-db-exchange/` | Austauschverzeichnis Server↔DB (Dump-Import/-Export, siehe [nuclos-db-Doku](https://hub.docker.com/r/nuccess/nuclos-db)) |
| `nuclos-control/` | Steuerkanal des Containers (Restart/Install-Marker, Status) – ⚠️ Schreibzugriff = Kontrolle über die Instanz |
| `backup-db.sh` | Datenbank-Backup (`pg_dump`, Custom-Format, 30 Tage Aufbewahrung) |
| `backup-instanz.sh` | Vollbackup (DB-Dump + alle Daten- und Konfigdateien) |
| `restore-instanz.sh` | Vollbackup zurückspielen |
| `upgrade.sh` | Upgrade auf neuen Image-Tag (mit automatischem Backup vorher) |
| `uninstall.sh` | Instanz entfernen (mit Abschlussbackup) |

## Upgrade

```bash
./upgrade.sh
```

Erst Backup, dann neuen Tag aus [nuclos-server/tags](https://hub.docker.com/r/nuccess/nuclos-server/tags) angeben (oder Enter für Re-Pull des aktuellen Tags, z.B. bei `latest`). Das DB-Image wird dabei mit aktueller Basis neu gebaut (`docker compose build --pull db`). Kein Installer-JAR mehr nötig.

## Backup & Restore

- `backup-db.sh` täglich per Cron empfohlen. Wiederherstellung eines Dumps: `docker exec -i <prefix>-db pg_restore -U nuclos -d nuclosdb --clean --if-exists < <datei>.backup`
- `backup-instanz.sh` / `restore-instanz.sh` für Vollbackups (Container werden dabei kurz gestoppt).
- Zusätzlich bietet der `nuclos-db`-Container über `nuclos-db-exchange/` einen dateibasierten Schema-Import/-Export (Details in der [Image-Doku](https://hub.docker.com/r/nuccess/nuclos-db)).

## Mehrere Instanzen (Test/Prod)

Einfach das Script in einem weiteren Verzeichnis mit anderem Container-Präfix und Port erneut ausführen. Jede Instanz bekommt ihren eigenen DB-Container – **Produktiv-, Test- und Entwicklungsumgebung nie im selben DB-Container betreiben** (ein DockerRestore löscht sonst ggf. das Produktivschema, siehe Warnung in der [Image-Doku](https://hub.docker.com/r/nuccess/nuclos-server)).

---

Dieses Script wird ohne jegliche Gewährleistung zur Verfügung gestellt unter MIT.
Kein Backup? Kein Mitleid!
