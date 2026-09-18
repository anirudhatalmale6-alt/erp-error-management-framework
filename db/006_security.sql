/* =============================================================================
   ERP Error Management Framework
   Script 006 - Least-privilege database security

   The ERP application login gets EXECUTE on the ERM schema and NOTHING
   else: no SELECT, no INSERT, no table rights at all.  A SQL-injection hole
   anywhere in the ERP therefore cannot read the error store, and the error
   store's own procedures are the only way in.

   Edit the two variables below before running.
   ============================================================================= */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @AppUser   SYSNAME = N'erp_app';        -- <-- the ERP's existing database user
DECLARE @AdminRole SYSNAME = N'ERM_admin';  -- support/admin console role

DECLARE @sql NVARCHAR(MAX);

/* ------------------------------------------------- application privileges -- */
IF DATABASE_PRINCIPAL_ID(@AppUser) IS NOT NULL
BEGIN
    SET @sql = N'GRANT EXECUTE ON SCHEMA::ERM TO ' + QUOTENAME(@AppUser) + N';';
    EXEC sp_executesql @sql;

    /* Deny the blanket table rights the app might inherit from db_datareader,
       so a future "GRANT db_datareader" cannot silently open the error store. */
    SET @sql = N'DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::ERM TO ' + QUOTENAME(@AppUser) + N';';
    EXEC sp_executesql @sql;

    PRINT N'Granted EXECUTE on ERM to ' + @AppUser;
END
ELSE
    PRINT N'WARNING: database principal "' + @AppUser + N'" not found - edit @AppUser and re-run.';
GO

/* ------------------------------------------------------- admin/support role */
DECLARE @AdminRole SYSNAME = N'ERM_admin';
DECLARE @sql NVARCHAR(MAX);

IF DATABASE_PRINCIPAL_ID(@AdminRole) IS NULL
BEGIN
    SET @sql = N'CREATE ROLE ' + QUOTENAME(@AdminRole) + N';';
    EXEC sp_executesql @sql;
END

SET @sql = N'GRANT EXECUTE ON SCHEMA::ERM TO ' + QUOTENAME(@AdminRole) + N';
             GRANT SELECT  ON SCHEMA::ERM TO ' + QUOTENAME(@AdminRole) + N';';
EXEC sp_executesql @sql;

/* Configuration is writable by the admin role; the error/ticket tables are not
   - those change only through the procedures, which is what keeps the audit
   trail complete. */
SET @sql = N'
    GRANT INSERT, UPDATE, DELETE ON OBJECT::ERM.ERM_Setting             TO ' + QUOTENAME(@AdminRole) + N';
    GRANT INSERT, UPDATE, DELETE ON OBJECT::ERM.ERM_ErrorCategory       TO ' + QUOTENAME(@AdminRole) + N';
    GRANT INSERT, UPDATE, DELETE ON OBJECT::ERM.ERM_Severity            TO ' + QUOTENAME(@AdminRole) + N';
    GRANT INSERT, UPDATE, DELETE ON OBJECT::ERM.ERM_TicketStatus        TO ' + QUOTENAME(@AdminRole) + N';
    GRANT INSERT, UPDATE, DELETE ON OBJECT::ERM.ERM_TicketStatusTransition TO ' + QUOTENAME(@AdminRole) + N';
    GRANT INSERT, UPDATE, DELETE ON OBJECT::ERM.ERM_TicketQueue         TO ' + QUOTENAME(@AdminRole) + N';
    GRANT INSERT, UPDATE, DELETE ON OBJECT::ERM.ERM_SlaPolicy           TO ' + QUOTENAME(@AdminRole) + N';
    GRANT INSERT, UPDATE, DELETE ON OBJECT::ERM.ERM_AutoTicketRule      TO ' + QUOTENAME(@AdminRole) + N';
    GRANT INSERT, UPDATE, DELETE ON OBJECT::ERM.ERM_RedactionAllowList  TO ' + QUOTENAME(@AdminRole) + N';
    GRANT INSERT, UPDATE, DELETE ON OBJECT::ERM.ERM_RetentionPolicy     TO ' + QUOTENAME(@AdminRole) + N';';
EXEC sp_executesql @sql;

PRINT N'Role ' + @AdminRole + N' configured.  Add your support staff with:';
PRINT N'    ALTER ROLE [ERM_admin] ADD MEMBER [<db user>];';
GO

MERGE ERM.ERM_SchemaVersion AS t
USING (SELECT N'006_security.sql' AS ScriptName) AS s
    ON t.ScriptName = s.ScriptName
WHEN NOT MATCHED THEN
    INSERT (ScriptName, FrameworkVersion) VALUES (s.ScriptName, N'1.0.0');
GO
