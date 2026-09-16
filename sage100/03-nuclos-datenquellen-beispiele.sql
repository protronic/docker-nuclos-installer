/* =====================================================================
   03 - Beispiel-Abfragen für Nuclos-Datenquellen auf die Sage-100-Daten
   ---------------------------------------------------------------------
   Die Sage-Views (Schema "nuclos" auf dem Sage-Server, Skript 02) stehen
   über tds_fdw als Schema "sage" in der Nuclos-Datenbank bereit. In Nuclos
   (Konfiguration -> Datenquellen) werden sie wie normale Tabellen abgefragt;
   auf Basis der Datenquellen lassen sich dynamische Entitäten anlegen.

   Alle Views enthalten die Spalte mandant - den Wert aus der Installation
   (.env: SAGE_MSSQL_MANDANT) einsetzen, im Beispiel 1.
   Vollständige Spaltenliste einer Fremdtabelle in der Nuclos-DB:
     SELECT column_name, data_type FROM information_schema.columns
     WHERE table_schema = 'sage' AND table_name = 'kunden' ORDER BY ordinal_position;
   (Dieselben Abfragen laufen mit "nuclos." statt "sage." auch direkt auf dem
    MS-SQL-Server, z.B. zum Testen in SSMS.)
   ===================================================================== */

-- Kunden (Debitoren mit Adresse); kto = Kundennummer
SELECT mandant, kto AS kundennummer, matchcode, adresse
FROM sage.kunden
WHERE mandant = 1;

-- Lieferanten (Kreditoren mit Adresse); kto = Lieferantennummer
SELECT mandant, kto AS lieferantennummer, matchcode, adresse
FROM sage.lieferanten
WHERE mandant = 1;

-- Adressen (alle, unabhängig von Kunde/Lieferant)
SELECT *
FROM sage.adressen
WHERE mandant = 1;

-- Artikel
SELECT *
FROM sage.artikel
WHERE mandant = 1;

-- Verkaufsbelege und Positionen (Verknüpfung in der Regel über belid;
-- Spaltennamen mit der information_schema-Abfrage oben prüfen)
SELECT *
FROM sage.vkbelege
WHERE mandant = 1;

SELECT *
FROM sage.vkbelegepositionen
WHERE mandant = 1;

-- Mandanten (zur Kontrolle)
SELECT DISTINCT mandant
FROM sage.mandanten
ORDER BY mandant;
