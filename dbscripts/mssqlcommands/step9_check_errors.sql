-- Check recent replication errors
SELECT TOP 10 id, error_text, time
FROM dbo.MSrepl_errors
ORDER BY time DESC;
GO
