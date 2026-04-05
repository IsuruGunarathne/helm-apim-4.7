-- Create database users for replication login (repl_dc1) on DC2
-- DC1's Distribution Agent uses repl_dc1 to push replicated data to DC2
-- Run this AFTER databases and tables are created (Step 3-4)

USE apim_db;
GO
CREATE USER repl_dc1 FOR LOGIN repl_dc1;
EXEC sp_addrolemember 'db_owner', 'repl_dc1';
GO

USE shared_db;
GO
CREATE USER repl_dc1 FOR LOGIN repl_dc1;
EXEC sp_addrolemember 'db_owner', 'repl_dc1';
GO
