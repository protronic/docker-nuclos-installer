/* =====================================================================
   03 - Beispiel-Abfragen für Nuclos-Datenquellen auf die Sage-100-Views
   ---------------------------------------------------------------------
   Verwendung in Nuclos (Desktop-Client): Administration -> Datenquellen,
   als Datenbankverbindung die externe Verbindung zur Sage-DB (Login
   nuclos_ro) wählen und eine der Abfragen als SQL hinterlegen. Auf Basis
   der Datenquelle lassen sich dynamische Entitäten anlegen.

   Alle Views enthalten die Spalte Mandant - den Wert aus der Installation
   (.env: SAGE_MSSQL_MANDANT) einsetzen, im Beispiel 1.
   Vollständige Spaltenliste einer View anzeigen:
     SELECT COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS
     WHERE TABLE_SCHEMA = 'nuclos' AND TABLE_NAME = 'Kunden' ORDER BY ORDINAL_POSITION;
   ===================================================================== */

-- Kunden (Debitoren mit Adresse); Kto = Kundennummer
SELECT Mandant, Kto AS Kundennummer, Matchcode, Adresse
FROM nuclos.Kunden
WHERE Mandant = 1;

-- Lieferanten (Kreditoren mit Adresse); Kto = Lieferantennummer
SELECT Mandant, Kto AS Lieferantennummer, Matchcode, Adresse
FROM nuclos.Lieferanten
WHERE Mandant = 1;

-- Adressen (alle, unabhängig von Kunde/Lieferant)
SELECT *
FROM nuclos.Adressen
WHERE Mandant = 1;

-- Artikel
SELECT *
FROM nuclos.Artikel
WHERE Mandant = 1;

-- Verkaufsbelege und Positionen (Verknüpfung in der Regel über BelID;
-- Spaltennamen mit der INFORMATION_SCHEMA-Abfrage oben prüfen)
SELECT *
FROM nuclos.VKBelege
WHERE Mandant = 1;

SELECT *
FROM nuclos.VKBelegePositionen
WHERE Mandant = 1;

-- Mandanten (zur Kontrolle)
SELECT DISTINCT Mandant
FROM nuclos.Mandanten
ORDER BY Mandant;
