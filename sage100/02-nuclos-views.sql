/* =====================================================================
   02 - Views im Schema "nuclos" auf die wichtigsten Sage-100-Tabellen
   ---------------------------------------------------------------------
   Ausführen in der Sage-Datenbank (Standard OLReweAbf, "USE" anpassen)
   mit dbo-/sysadmin-Rechten, NACH Skript 01. Kann jederzeit erneut
   ausgeführt werden (z.B. nach einem Sage-Update) - alle Views werden
   dann neu aufgebaut.

   Die 1:1-Views werden dynamisch mit expliziter Spaltenliste aus
   INFORMATION_SCHEMA erzeugt. Dadurch passen sie zu jeder Sage-100-
   Version (kein SELECT *, keine fest verdrahteten Spaltennamen).
   Tabellen, die es in Ihrer Sage-Version nicht gibt, werden übersprungen.

   View- und Spaltennamen sind KLEINGESCHRIEBEN (kto, matchcode, ...):
   MS-SQL ist ohnehin case-insensitiv, und in der Nuclos-DB (PostgreSQL,
   Einbindung per tds_fdw als Schema "sage") lassen sich die Fremdtabellen
   dann ohne Anführungszeichen abfragen: SELECT kto FROM sage.kunden
   ===================================================================== */

USE [OLReweAbf];
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID(N'nuclos') IS NULL
BEGIN
    EXEC('CREATE SCHEMA [nuclos] AUTHORIZATION [dbo]');
    PRINT 'Schema nuclos angelegt (Login und Rechte: siehe 01-nuclos-readonly-login.sql)';
END
GO

/* ---- Hilfsprozedur: 1:1-View mit expliziter Spaltenliste ------------ */
IF OBJECT_ID(N'nuclos.usp_CreateTableView', N'P') IS NOT NULL
    DROP PROCEDURE nuclos.usp_CreateTableView;
GO
CREATE PROCEDURE nuclos.usp_CreateTableView
    @Table sysname,   -- Sage-Tabelle im Schema dbo, z.B. KHKAdressen
    @View  sysname    -- Name der View im Schema nuclos, z.B. Adressen
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID(N'dbo.' + QUOTENAME(@Table), N'U') IS NULL
    BEGIN
        PRINT 'übersprungen: dbo.' + @Table + ' existiert in dieser Sage-Version nicht';
        RETURN;
    END;

    DECLARE @cols nvarchar(max) = STUFF((
        SELECT ', ' + QUOTENAME(COLUMN_NAME) + ' AS ' + QUOTENAME(LOWER(COLUMN_NAME))
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = N'dbo' AND TABLE_NAME = @Table
        ORDER BY ORDINAL_POSITION
        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, '');

    DECLARE @sql nvarchar(max);
    IF OBJECT_ID(N'nuclos.' + QUOTENAME(@View), N'V') IS NOT NULL
    BEGIN
        SET @sql = N'DROP VIEW nuclos.' + QUOTENAME(@View) + N';';
        EXEC sp_executesql @sql;
    END;

    SET @sql = N'CREATE VIEW nuclos.' + QUOTENAME(@View) + N' AS SELECT ' + @cols
             + N' FROM dbo.' + QUOTENAME(@Table) + N';';
    EXEC sp_executesql @sql;
    PRINT 'View nuclos.' + @View + '  <-  dbo.' + @Table;
END
GO

/* ---- 1:1-Views: Stammdaten und Belege ------------------------------- */
EXEC nuclos.usp_CreateTableView N'KHKMandanten',           N'mandanten';
EXEC nuclos.usp_CreateTableView N'KHKAdressen',            N'adressen';
EXEC nuclos.usp_CreateTableView N'KHKAnsprechpartner',     N'ansprechpartner';
EXEC nuclos.usp_CreateTableView N'KHKKontokorrent',        N'kontokorrent';
EXEC nuclos.usp_CreateTableView N'KHKArtikel',             N'artikel';
EXEC nuclos.usp_CreateTableView N'KHKArtikelvarianten',    N'artikelvarianten';
EXEC nuclos.usp_CreateTableView N'KHKVKBelege',            N'vkbelege';
EXEC nuclos.usp_CreateTableView N'KHKVKBelegePositionen',  N'vkbelegepositionen';
EXEC nuclos.usp_CreateTableView N'KHKEKBelege',            N'ekbelege';
EXEC nuclos.usp_CreateTableView N'KHKEKBelegePositionen',  N'ekbelegepositionen';
EXEC nuclos.usp_CreateTableView N'KHKLagerplatzBuchungen', N'lagerbuchungen';
GO

/* ---- Kombinierte Views Kunden / Lieferanten -------------------------
   Kontokorrent (Kundennummer = Kto, Kontoart KtoArt: 'D' = Debitor/Kunde,
   'K' = Kreditor/Lieferant) verknüpft mit der Adresse (Join über
   Mandant + Adresse). Werte von KtoArt bei Bedarf prüfen mit:
     SELECT DISTINCT KtoArt FROM dbo.KHKKontokorrent
   Spaltennamen, die in beiden Tabellen vorkommen, erhalten aus der
   Adresse den Präfix adr_ (z.B. adr_matchcode).                        */
IF OBJECT_ID(N'nuclos.usp_CreateKontoView', N'P') IS NOT NULL
    DROP PROCEDURE nuclos.usp_CreateKontoView;
GO
CREATE PROCEDURE nuclos.usp_CreateKontoView
    @View   sysname,   -- z.B. Kunden
    @KtoArt nchar(1)   -- 'D' oder 'K'
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID(N'dbo.KHKKontokorrent', N'U') IS NULL
       OR OBJECT_ID(N'dbo.KHKAdressen', N'U') IS NULL
       OR COL_LENGTH(N'dbo.KHKKontokorrent', N'KtoArt')  IS NULL
       OR COL_LENGTH(N'dbo.KHKKontokorrent', N'Adresse') IS NULL
       OR COL_LENGTH(N'dbo.KHKKontokorrent', N'Mandant') IS NULL
       OR COL_LENGTH(N'dbo.KHKAdressen',     N'Adresse') IS NULL
    BEGIN
        PRINT 'übersprungen: nuclos.' + @View
            + ' (KHKKontokorrent/KHKAdressen oder Spalten KtoArt/Adresse/Mandant fehlen)';
        RETURN;
    END;

    -- alle Spalten des Kontokorrents (Alias k) ...
    DECLARE @kcols nvarchar(max) = STUFF((
        SELECT ', k.' + QUOTENAME(COLUMN_NAME) + ' AS ' + QUOTENAME(LOWER(COLUMN_NAME))
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = N'dbo' AND TABLE_NAME = N'KHKKontokorrent'
        ORDER BY ORDINAL_POSITION
        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, '');

    -- ... plus alle Adressspalten (Alias a); Namensdoubletten mit Präfix adr_
    DECLARE @acols nvarchar(max) = STUFF((
        SELECT ', a.' + QUOTENAME(c.COLUMN_NAME) + ' AS '
             + QUOTENAME(LOWER(CASE WHEN EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS k
                                                  WHERE k.TABLE_SCHEMA = N'dbo'
                                                    AND k.TABLE_NAME  = N'KHKKontokorrent'
                                                    AND k.COLUMN_NAME = c.COLUMN_NAME)
                                     THEN 'adr_' + c.COLUMN_NAME
                                     ELSE c.COLUMN_NAME END))
        FROM INFORMATION_SCHEMA.COLUMNS c
        WHERE c.TABLE_SCHEMA = N'dbo' AND c.TABLE_NAME = N'KHKAdressen'
        ORDER BY c.ORDINAL_POSITION
        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, '');

    DECLARE @sql nvarchar(max);
    IF OBJECT_ID(N'nuclos.' + QUOTENAME(@View), N'V') IS NOT NULL
    BEGIN
        SET @sql = N'DROP VIEW nuclos.' + QUOTENAME(@View) + N';';
        EXEC sp_executesql @sql;
    END;

    SET @sql = N'CREATE VIEW nuclos.' + QUOTENAME(@View) + N' AS '
             + N'SELECT ' + @kcols + N', ' + @acols
             + N' FROM dbo.KHKKontokorrent k'
             + N' INNER JOIN dbo.KHKAdressen a ON a.Mandant = k.Mandant AND a.Adresse = k.Adresse'
             + N' WHERE k.KtoArt = ' + QUOTENAME(@KtoArt, '''') + N';';
    EXEC sp_executesql @sql;
    PRINT 'View nuclos.' + @View + '  <-  KHKKontokorrent (KtoArt=' + @KtoArt + ') + KHKAdressen';
END
GO

EXEC nuclos.usp_CreateKontoView N'kunden',      N'D';
EXEC nuclos.usp_CreateKontoView N'lieferanten', N'K';
GO

/* ---- Ergebnis ------------------------------------------------------- */
SELECT s.name AS [Schema], v.name AS [View]
FROM sys.views v
JOIN sys.schemas s ON s.schema_id = v.schema_id
WHERE s.name = N'nuclos'
ORDER BY v.name;
GO
