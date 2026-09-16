/* =====================================================================
   01 - Read-only-Login "nuclos_ro" und Schema "nuclos" für die
        Nuclos-Anbindung an Sage 100
   ---------------------------------------------------------------------
   Ausführen auf dem Sage-100-SQL-Server (SSMS oder sqlcmd) mit
   sysadmin-Rechten. Vorher anpassen:
     - Datenbankname  (Standard OLReweAbf) -> DEFAULT_DATABASE und "USE"
     - Passwort       (BitteAendern-2026!)  -> gleiches Passwort später in
                                              Nuclos bei der Datenbankverbindung

   Der Login bekommt AUSSCHLIESSLICH Leserechte auf das Schema "nuclos"
   und keinen direkten Zugriff auf die Sage-Rohtabellen (Schema dbo).
   Die Views in "nuclos" (Skript 02) gehören dbo -> über Ownership
   Chaining darf nuclos_ro die Sage-Tabellen ausschließlich über diese
   Views lesen.
   ===================================================================== */

USE [master];
GO
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'nuclos_ro')
BEGIN
    CREATE LOGIN [nuclos_ro]
        WITH PASSWORD         = N'BitteAendern-2026!',
             DEFAULT_DATABASE = [OLReweAbf],
             CHECK_POLICY     = ON,
             CHECK_EXPIRATION = OFF;
    PRINT 'Login nuclos_ro angelegt';
END
ELSE
    PRINT 'Login nuclos_ro existiert bereits (Passwort unverändert)';
GO

USE [OLReweAbf];
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'nuclos_ro')
BEGIN
    CREATE USER [nuclos_ro] FOR LOGIN [nuclos_ro];
    PRINT 'Datenbankbenutzer nuclos_ro in ' + DB_NAME() + ' angelegt';
END
GO

IF SCHEMA_ID(N'nuclos') IS NULL
BEGIN
    EXEC('CREATE SCHEMA [nuclos] AUTHORIZATION [dbo]');
    PRINT 'Schema nuclos angelegt';
END
GO

-- Nur Leserechte, und nur auf das Schema nuclos
GRANT SELECT ON SCHEMA::[nuclos] TO [nuclos_ro];
GO

PRINT 'Fertig: nuclos_ro hat Lesezugriff auf das Schema nuclos in ' + DB_NAME()
    + ' - jetzt 02-nuclos-views.sql ausführen.';
GO
