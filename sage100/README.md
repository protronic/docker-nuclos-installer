# Sage 100 / MS-SQL: Anbindung an Nuclos

Nuclos kennt für Datenquellen **keine externen JDBC-Verbindungen** – Datenquellen laufen immer gegen die Nuclos-eigene Datenbank (PostgreSQL). Die Sage-100-Daten werden deshalb in **zwei Schritten** eingebunden:

1. **Auf dem Sage-Server** (MS-SQL): ein Read-only-Login und ein Schema `nuclos` mit Views auf die wichtigsten Sage-Tabellen (Skripte 01/02). Nuclos greift nie direkt auf die Sage-Rohtabellen zu und nie schreibend.
2. **In der Nuclos-DB** (PostgreSQL): der Foreign Data Wrapper [tds_fdw](https://github.com/tds-fdw/tds_fdw) bindet diese Views als Fremdtabellen im Schema `sage` ein (Skript 10, von `install.sh` automatisch ausgeführt). Datenquellen und dynamische Entitäten in Nuclos nutzen dann einfach `sage.kunden`, `sage.artikel`, … – auch im Join mit Nuclos-eigenen Tabellen.

Dauerhaft lässt sich Schritt 2 als **SQL-Konfiguration** im Nuclet pflegen (Skript 11) – das ist der Nuclos-Mechanismus für SQL, das beim Nuclet-Import gegen die Nuclos-DB läuft (siehe Nuclos-Wiki „SQL Konfigurationen“).

| Skript | Wo ausführen | Was passiert |
|---|---|---|
| `01-nuclos-readonly-login.sql` | Sage-SQL-Server, SSMS als sysadmin | Login `nuclos_ro` (Passwort anpassen!), DB-Benutzer, Schema `nuclos`, `GRANT SELECT` nur auf dieses Schema |
| `02-nuclos-views.sql` | Sage-SQL-Server, in der Sage-DB (`OLReweAbf`) | Views `nuclos.adressen`, `kontokorrent`, `artikel`, `vkbelege`, … sowie `nuclos.kunden` / `nuclos.lieferanten` (Kontokorrent + Adresse). Spaltenlisten werden aus `INFORMATION_SCHEMA` erzeugt (kleingeschrieben, damit PostgreSQL sie ohne Anführungszeichen abfragen kann); Tabellen, die es in der Sage-Version nicht gibt, werden übersprungen |
| `03-nuclos-datenquellen-beispiele.sql` | nur Vorlage | Beispiel-SELECTs für Nuclos-Datenquellen auf `sage.*` |
| `10-nuclos-db-tds-fdw.sql` | Nuclos-DB (automatisch via `install.sh` → `sage100-fdw.sql` → `nuclos-db-exchange/`) | `CREATE EXTENSION tds_fdw`, Foreign Server `sage100`, User-Mapping, `IMPORT FOREIGN SCHEMA nuclos … INTO sage` |
| `11-sqlkonfiguration-sage-schema.sql` | Nuclos: Konfiguration → Datenbank → SQL-Konfigurationen | Schema `sage` neu einlesen, versioniert im Nuclet (Tag `POSTGRESQL`) |

Vor dem Ausführen anpassen: Datenbankname (Standard `OLReweAbf`) und das Passwort in Skript 01.

## Ablauf

1. Skript 01 und 02 in SSMS auf dem Sage-Server ausführen (einmalig, DB-Admin). Nach Sage-Updates Skript 02 erneut ausführen, damit neue Spalten in den Views erscheinen.
2. `install.sh` mit „tds_fdw einrichten? J“ und dem Passwort von `nuclos_ro` laufen lassen – das DB-Image wird mit tds_fdw gebaut und `sage100-fdw.sql` nach dem Start automatisch ausgeführt (Protokoll: `nuclos-db-exchange/logs/`). Bei einer bestehenden Installation: `TDS_FDW="true"` in `.env`, `./upgrade.sh`, dann `cp sage100-fdw.sql nuclos-db-exchange/`.
3. Prüfen: `docker exec -it <prefix>-db psql -U nuclos -d nuclosdb -c "SELECT count(*) FROM sage.kunden"`
4. In Nuclos (Konfiguration → Datenquellen) Abfragen aus Skript 03 anlegen (`mandant` anpassen) und darauf dynamische Entitäten aufbauen.
5. Optional: Skript 11 als SQL-Konfiguration ins Nuclet aufnehmen, damit das Schema `sage` bei jedem Nuclet-Import (Test → Prod) mit übernommen wird.

## Test vom Docker-Host (ohne Installation)

```bash
docker run --rm -it mcr.microsoft.com/mssql-tools /opt/mssql-tools/bin/sqlcmd \
  -S <sage-server>,1433 -U nuclos_ro -P '<passwort>' -d OLReweAbf \
  -Q "SELECT TOP 5 mandant, kto, matchcode FROM nuclos.kunden"
```

Denselben Test (plus Datenbank- und Mandantenliste) macht `install.sh`, wenn beim Verbindungstest ein Login angegeben wird.

## Hinweise

- **Nur lesend.** Rückschreiben nach Sage 100 nur über Sage-eigene Schnittstellen. Für Java-Regeln (Server-Code) liegt der Microsoft-JDBC-Treiber in `nuclos-extensions/server/` bereit.
- Alle Views enthalten `mandant` – in den Datenquellen immer auf den gewünschten Mandanten filtern (`SAGE_MSSQL_MANDANT` in `.env`).
- `kunden` / `lieferanten` filtern über `KtoArt` (`'D'` Debitor, `'K'` Kreditor). Bei Abweichungen prüfen mit `SELECT DISTINCT KtoArt FROM dbo.KHKKontokorrent`.
- Das Sage-Passwort steht im User-Mapping der Nuclos-DB (nur für Superuser lesbar) und in `sage100-fdw.sql` (Rechte 600, per `.gitignore` ausgeschlossen); `install.sh` entfernt es nach der Ausführung aus dem Protokoll in `nuclos-db-exchange/logs/`.
- Der Login `nuclos_ro` hat keinerlei Rechte außerhalb des Schemas `nuclos`; weitere Views einfach dort anlegen und Skript 11 ausführen.
