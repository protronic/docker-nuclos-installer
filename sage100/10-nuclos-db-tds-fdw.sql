-- =====================================================================
-- 10 - Nuclos-DB (PostgreSQL): Sage-100-Views per tds_fdw einbinden
-- ---------------------------------------------------------------------
-- Vorlage - install.sh erzeugt daraus die ausgefüllte Datei sage100-fdw.sql
-- und führt sie automatisch aus. Manuell: Platzhalter ersetzen und die Datei
-- nach nuclos-db-exchange/ kopieren. Der nuclos-db-Container führt jede
-- *.sql dort als Superuser "nuclos" auf "nuclosdb" aus, löscht sie danach
-- und schreibt ein Protokoll nach nuclos-db-exchange/logs/.
-- Voraussetzung: DB-Image mit tds_fdw (TDS_FDW=true in .env, nuclos-db.Dockerfile)
-- =====================================================================
CREATE EXTENSION IF NOT EXISTS tds_fdw;

DROP SERVER IF EXISTS sage100 CASCADE;
CREATE SERVER sage100 FOREIGN DATA WRAPPER tds_fdw
  OPTIONS (servername '<SAGE-SERVER>', port '1433', database 'OLReweAbf',
           tds_version '7.4', msg_handler 'notice');

-- Zugangsdaten des Read-only-Logins aus 01-nuclos-readonly-login.sql
-- (werden im PostgreSQL-Katalog gespeichert, nur für Superuser lesbar)
CREATE USER MAPPING FOR PUBLIC SERVER sage100
  OPTIONS (username 'nuclos_ro', password '<PASSWORT>');

-- Views aus dem Schema "nuclos" des Sage-Servers (02-nuclos-views.sql)
-- als Fremdtabellen ins Schema "sage" der Nuclos-DB übernehmen.
-- ACHTUNG: DROP ... CASCADE entfernt auch eigene Nuclos-Datenbankobjekte,
-- die auf sage.* aufbauen - diese danach neu anlegen.
DROP SCHEMA IF EXISTS sage CASCADE;
CREATE SCHEMA sage;
IMPORT FOREIGN SCHEMA nuclos FROM SERVER sage100 INTO sage;

-- Kontrolle
SELECT foreign_table_name FROM information_schema.foreign_tables
 WHERE foreign_table_schema = 'sage' ORDER BY 1;
SELECT count(*) AS anzahl_kunden FROM sage.kunden;
