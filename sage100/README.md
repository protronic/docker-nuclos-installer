# Sage 100 / MS-SQL: Vorbereitung auf dem Sage-Server

Damit Nuclos die Sage-100-Daten sauber und sicher lesen kann, wird auf dem Sage-SQL-Server ein eigener **Read-only-Login** angelegt und ein **Schema `nuclos` mit Views** auf die wichtigsten Sage-Tabellen. Nuclos greift dann ausschließlich über diese Views zu – nie direkt auf die Sage-Rohtabellen, und nie schreibend.

Die Skripte führt der Sage-/Datenbank-Admin einmalig in SQL Server Management Studio (SSMS) oder per `sqlcmd` aus.

| Skript | Wo ausführen | Was passiert |
|---|---|---|
| `01-nuclos-readonly-login.sql` | SQL-Server, als sysadmin | Login `nuclos_ro` (Passwort anpassen!), DB-Benutzer, Schema `nuclos`, `GRANT SELECT` nur auf dieses Schema |
| `02-nuclos-views.sql` | in der Sage-DB (`OLReweAbf`) | Views `nuclos.Adressen`, `Kontokorrent`, `Artikel`, `VKBelege`, … sowie `nuclos.Kunden` / `nuclos.Lieferanten` (Kontokorrent + Adresse). Spaltenlisten werden aus `INFORMATION_SCHEMA` erzeugt, Tabellen, die es in der Sage-Version nicht gibt, werden übersprungen |
| `03-nuclos-datenquellen-beispiele.sql` | nur Vorlage | Beispiel-SELECTs für Nuclos-Datenquellen |

Vor dem Ausführen anpassen: Datenbankname (Standard `OLReweAbf`, in `USE [...]` und `DEFAULT_DATABASE`) und das Passwort in Skript 01.

## Testen

Vom Docker-Host aus, ohne etwas zu installieren (Wegwerf-Container mit `sqlcmd`):

```bash
docker run --rm -it mcr.microsoft.com/mssql-tools /opt/mssql-tools/bin/sqlcmd \
  -S <sage-server>,1433 -U nuclos_ro -P '<passwort>' -d OLReweAbf \
  -Q "SELECT TOP 5 Mandant, Kto, Matchcode FROM nuclos.Kunden"
```

Derselbe Test läuft auch im Installer (`install.sh`), wenn beim Verbindungstest ein Login angegeben wird.

## In Nuclos einrichten

1. Desktop-Client → **Administration → Datenbankverbindungen** → neue Verbindung:
   - Treiber-Klasse: `com.microsoft.sqlserver.jdbc.SQLServerDriver`
   - JDBC-URL: `jdbc:sqlserver://<sage-server>:1433;databaseName=OLReweAbf;encrypt=true;trustServerCertificate=true`
   - Benutzer `nuclos_ro` mit dem Passwort aus Skript 01
   (der JDBC-Treiber liegt bereits in `nuclos-extensions/server/` der Docker-Installation)
2. **Administration → Datenquellen**: Abfragen aus `03-nuclos-datenquellen-beispiele.sql` mit dieser Verbindung anlegen (`Mandant` anpassen).
3. Auf Basis der Datenquellen **dynamische Entitäten** anlegen – die Sage-Daten erscheinen dann in Nuclos (lesend).

## Hinweise

- **Nur lesend.** Rückschreiben nach Sage 100 nur über Sage-eigene Schnittstellen, nie direkt in die Tabellen.
- Nach einem **Sage-Update** Skript 02 erneut ausführen, damit neue Spalten in den Views auftauchen.
- Alle Views enthalten die Spalte `Mandant` – in den Datenquellen immer auf den gewünschten Mandanten filtern (Wert aus der Installation: `SAGE_MSSQL_MANDANT` in `.env`).
- `nuclos.Kunden` / `nuclos.Lieferanten` filtern über `KtoArt` (`'D'` Debitor, `'K'` Kreditor). Bei Abweichungen prüfen mit `SELECT DISTINCT KtoArt FROM dbo.KHKKontokorrent`.
- Der Login hat keinerlei Rechte außerhalb des Schemas `nuclos`; weitere Views einfach im selben Schema anlegen.
