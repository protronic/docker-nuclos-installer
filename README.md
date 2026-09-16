# docker-nuclos-installer

Automatische dockerbasierte Nuclos-Installation auf Basis der offiziellen Docker-Hub-Images von nuccess:

- [nuccess/nuclos-server](https://hub.docker.com/r/nuccess/nuclos-server) – Nuclos Applikationsserver
- [nuccess/nuclos-db](https://hub.docker.com/r/nuccess/nuclos-db) – PostgreSQL-Systemdatenbank für Nuclos

Ausgelegt für den **Parallelbetrieb mit Sage 100 / MS-SQL**: Nuclos läuft in Docker neben Sage 100 auf demselben (oder einem benachbarten) Server und bindet die Sage-100-Datenbank als externe Datenbankverbindung (JDBC) ein.

# !!! A C H T U N G !!! für einen produktiven Betrieb ausschließlich hinter einem Reverseproxyserver wie z.B. nginx (siehe `Beipiel-NGINX-Config.txt`)

## Was ist neu (09/2026)

- **Kein Installer-JAR, kein lokaler Image-Build mehr.** Es werden die fertigen, signierten Images `nuccess/nuclos-server` und `nuccess/nuclos-db` von Docker Hub verwendet.
- **Upgrade = Image-Tag wechseln** (`upgrade.sh`), die Datenbank-Migration läuft beim Start automatisch (AutoDbSetup).
- **DB-Passwort als Secret-Datei** (`./secrets/db_password`) statt im Klartext in `.env` – Vorgabe der nuccess-Images ab 4.2024.25.
- **Sage 100 / MS-SQL-Anbindung vorbereitet:** Der Microsoft-JDBC-Treiber wird automatisch nach `./nuclos-extensions/server/` geladen und beim Serverstart in den Nuclos-Classpath übernommen.
- `install-nuc-all.sh` ist veraltet und leitet nur noch auf `install.sh` weiter.

## Architektur / Parallelbetrieb mit Sage 100 und MS-SQL

Sage 100 und der MS-SQL-Server laufen auf einem **eigenen Server**, Nuclos in Docker auf dem Docker-Host daneben:

```
┌───── Sage-100-Server ─────┐             ┌────────────── Docker-Host ──────────────┐
│                           │             │                                         │
│  Sage 100                 │    JDBC     │  ┌───────────────────────┐              │
│  MS-SQL Server (1433) ◀───┼─────────────┼──│ nuccess/nuclos-server │              │
│                           │ (nur lesend │  │ (Port 8080 → Host)    │              │
└───────────────────────────┘  empfohlen) │  └───────────┬───────────┘              │
                                          │              ▼                          │
                                          │  ┌───────────────────────┐              │
                                          │  │ nuccess/nuclos-db     │              │
                                          │  │ (PostgreSQL, intern)  │              │
                                          │  └───────────────────────┘              │
                                          └─────────────────────────────────────────┘
```

Wichtig zu wissen:

- Die nuccess-Images unterstützen als **Nuclos-Systemdatenbank ausschließlich PostgreSQL**. Datenbankname (`nuclosdb`) und Benutzer (`nuclos`) sind im Image fest vorgegeben; konfigurierbar sind Schema und Passwort. Die Sage-100/MS-SQL-Datenbank kann und soll **nicht** als Systemdatenbank dienen.
- Die **Sage-100-Daten** werden in Nuclos über eine **externe Datenbankverbindung** eingebunden (Administration → Datenbankverbindungen) und stehen dann z.B. für Datenquellen und dynamische Entitäten zur Verfügung:
  - Treiber-Klasse: `com.microsoft.sqlserver.jdbc.SQLServerDriver`
  - JDBC-URL: `jdbc:sqlserver://<sage-server>:1433;databaseName=<SageDB>;encrypt=true;trustServerCertificate=true`
- **Netzwerk:** Der Docker-Host muss den Sage-100-Server auf Port 1433 erreichen (Firewall-Freigabe, Namensauflösung). `install.sh` prüft die Erreichbarkeit direkt bei der Installation. Sonderfall: läuft MS-SQL doch auf dem Docker-Host selbst, als Host `host.docker.internal` verwenden (in der erzeugten `docker-compose.yml` bereits eingerichtet).
- Voraussetzungen auf dem MS-SQL-Server: TCP/IP aktiviert (SQL Server Configuration Manager), Port 1433 in der Firewall freigegeben, SQL-Server-Authentifizierung (Mixed Mode) mit eigenem Login – **nur lesend**.
- **Sage-seitige Vorbereitung (empfohlen):** Die SQL-Skripte im Ordner [`sage100/`](sage100/README.md) legen den Read-only-Login `nuclos_ro` und ein Schema `nuclos` mit Views auf Adressen, Kunden/Lieferanten, Artikel und Belege an (Spaltenlisten werden dynamisch aus `INFORMATION_SCHEMA` erzeugt, passend zur jeweiligen Sage-Version). Nuclos liest ausschließlich über diese Views. Dazu Beispiel-Abfragen für Nuclos-Datenquellen.
- **Verbindungstest im Installer:** `install.sh` fragt Sage-Server, Port, Datenbank (Standard `OLReweAbf`) und den SQL-Benutzer für Nuclos (Standard `nuclos_ro`) ab. Optional prüft es mit einem SQL-Login die Anmeldung wirklich (Wegwerf-Container `mcr.microsoft.com/mssql-tools`, nichts wird installiert, Passwort wird nicht gespeichert), listet die Datenbanken auf, erkennt die Sage-100-Struktur und zeigt die **Mandanten** zur Auswahl. Ergebnis landet in `.env` (`SAGE_MSSQL_*`) und in der Zusammenfassung am Ende.
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
| `secrets/db_password` | Datenbank-Passwort (Secret-Datei, nicht in `.env`!) |
| `.gitignore` | Wird miterzeugt: Secrets, `.env` und alle Laufzeitdaten sind vom Einchecken ausgeschlossen |
| `sage100/` (im Repo) | SQL-Skripte für den Sage-Server: Read-only-Login, Schema `nuclos` mit Views, Datenquellen-Beispiele |
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

Erst Backup, dann neuen Tag aus [nuclos-server/tags](https://hub.docker.com/r/nuccess/nuclos-server/tags) angeben (oder Enter für Re-Pull des aktuellen Tags, z.B. bei `latest`). Kein Installer-JAR mehr nötig.

## Backup & Restore

- `backup-db.sh` täglich per Cron empfohlen. Wiederherstellung eines Dumps: `docker exec -i <prefix>-db pg_restore -U nuclos -d nuclosdb --clean --if-exists < <datei>.backup`
- `backup-instanz.sh` / `restore-instanz.sh` für Vollbackups (Container werden dabei kurz gestoppt).
- Zusätzlich bietet der `nuclos-db`-Container über `nuclos-db-exchange/` einen dateibasierten Schema-Import/-Export (Details in der [Image-Doku](https://hub.docker.com/r/nuccess/nuclos-db)).

## Mehrere Instanzen (Test/Prod)

Einfach das Script in einem weiteren Verzeichnis mit anderem Container-Präfix und Port erneut ausführen. Jede Instanz bekommt ihren eigenen DB-Container – **Produktiv-, Test- und Entwicklungsumgebung nie im selben DB-Container betreiben** (ein DockerRestore löscht sonst ggf. das Produktivschema, siehe Warnung in der [Image-Doku](https://hub.docker.com/r/nuccess/nuclos-server)).

---

Dieses Script wird ohne jegliche Gewährleistung zur Verfügung gestellt unter MIT.
Kein Backup? Kein Mitleid!
