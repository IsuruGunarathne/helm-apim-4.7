-- Check P2P conflict tables
-- P2P replication creates conflict_<schema>_<table> tables when conflicts are detected
-- Run against the replicated database (apim_db or shared_db)

PRINT '=== Conflict Tables ===';
SELECT name FROM sys.tables WHERE name LIKE 'conflict[_]%' ORDER BY name;
GO

-- To view conflicts in a specific table, run:
-- SELECT * FROM conflict_dbo_<table_name> ORDER BY __$last_conflict_time DESC;
--
-- Columns in conflict tables:
--   __$originator_id     — the node that made the change
--   __$last_conflict_time — when the conflict was detected
--   All columns from the original table (the losing row's data)

PRINT '=== Conflict Count Per Table ===';
DECLARE @sql NVARCHAR(MAX) = '';
SELECT @sql = @sql + 'SELECT ''' + name + ''' AS conflict_table, COUNT(*) AS conflicts FROM ' + QUOTENAME(name) + ' UNION ALL '
FROM sys.tables WHERE name LIKE 'conflict[_]%';

IF LEN(@sql) > 0
BEGIN
    SET @sql = LEFT(@sql, LEN(@sql) - 10); -- remove trailing UNION ALL
    EXEC sp_executesql @sql;
END
ELSE
    PRINT 'No conflict tables found (no conflicts have occurred).';
GO
