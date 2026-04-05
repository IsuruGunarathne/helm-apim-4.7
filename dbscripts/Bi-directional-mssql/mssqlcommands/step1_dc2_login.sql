-- Create replication login on DC2
-- DC1's Distribution Agent will use this login to push replicated data here
CREATE LOGIN repl_dc1 WITH PASSWORD = 'Repl@2025';
GO
