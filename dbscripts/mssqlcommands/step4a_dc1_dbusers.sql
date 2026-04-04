-- Create database users for replication login (repl_dc2) on DC1
-- DC2's Distribution Agent uses repl_dc2 to push replicated data to DC1
-- Run this AFTER databases and tables are created (Step 3-4)

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
