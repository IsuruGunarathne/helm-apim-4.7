-- Check recent replication errors
-- Run against the distribution database on each DC
SELECT TOP 20 id, error_text, time
FROM dbo.MSrepl_errors
ORDER BY time DESC;
GO
