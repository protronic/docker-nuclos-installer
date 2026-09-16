-- =====================================================================
-- 11 - Nuclos SQL-Konfiguration (Nuclet): Sage-Fremdtabellen neu einlesen
-- ---------------------------------------------------------------------
-- Inhalt für eine SQL-Konfiguration im Nuclet
-- (Nuclos Desktop-Client: Konfiguration -> Datenbank -> SQL-Konfigurationen):
--   Name:        Sage 100 Schema einlesen
--   Reihenfolge: 10
--   Tags:        POSTGRESQL
--   Nach Import: ja  (läuft nach dem Schema-Update des Nuclet-Imports)
--   SQL:         der Block unten
--
-- Nuclos führt SQL-Konfigurationen beim Nuclet-Import gegen die eigene
-- Datenbank aus - nur wenn sich das SQL geändert hat (Prüfsumme), in der
-- angegebenen Reihenfolge und nur bei passendem Tag (der DB-Typ, hier
-- POSTGRESQL, ist automatisch gesetzt). Ergebnis und Fehler des letzten
-- Laufs stehen im Datensatz der SQL-Konfiguration.
--
-- Server und User-Mapping (Datei 10 / sage100-fdw.sql) gehören NICHT ins
-- Nuclet: sie enthalten Umgebungsdaten und das Passwort. Das Nuclet liest
-- nur das Schema neu ein, z.B. nachdem 02-nuclos-views.sql auf dem
-- Sage-Server erneut ausgeführt wurde (neue Spalten/Views).
-- ACHTUNG: DROP ... CASCADE entfernt auch Datenbankobjekte, die auf sage.*
-- aufbauen - diese als weitere SQL-Konfiguration mit höherer Reihenfolge
-- anlegen, dann werden sie im selben Import direkt wieder erzeugt.
-- =====================================================================
DROP SCHEMA IF EXISTS sage CASCADE;
CREATE SCHEMA sage;
IMPORT FOREIGN SCHEMA nuclos FROM SERVER sage100 INTO sage;
