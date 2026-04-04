-- Login for DC2 to connect for replication
CREATE LOGIN repl_dc2 WITH PASSWORD = 'Repl@2025';
GO

-- Create database users for the replication login on apim_db and shared_db
-- (Run AFTER Step 4 creates the databases and tables, but listed here for reference)
-- These are needed so the Distribution Agent can write replicated data
USE apim_db;
GO
CREATE USER repl_dc2 FOR LOGIN repl_dc2;
EXEC sp_addrolemember 'db_owner', 'repl_dc2';
GO
USE shared_db;
GO
CREATE USER repl_dc2 FOR LOGIN repl_dc2;
EXEC sp_addrolemember 'db_owner', 'repl_dc2';
GO
