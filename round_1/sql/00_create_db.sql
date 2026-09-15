/* =====================================================================
   DATA VORTEX :: Round 1 Phase 2
   00 - Database creation
   Target: SQL Server 2019+ / Azure SQL. Run in SSMS.
   ===================================================================== */

IF DB_ID('DataVortex') IS NULL
    CREATE DATABASE DataVortex;
GO

USE DataVortex;
GO

/* Case- and accent-sensitive collation.
   The corpus contains repaired accented characters (Cafe vs Cafe) and
   brand names that differ only by case. A CI/AI collation would silently
   merge them and understate the distinct-value counts. */
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'stg')
    EXEC('CREATE SCHEMA stg');
GO

PRINT 'DataVortex ready.';
GO
