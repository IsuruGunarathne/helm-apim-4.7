-- Create replication login on DC1
-- DC2's Distribution Agent will use this login to push replicated data here
CREATE LOGIN repl_dc2 WITH PASSWORD = 'Repl@2025';
GO
