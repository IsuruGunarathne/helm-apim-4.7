-- Verify replication agent jobs are running
-- Run on both DC1 and DC2

PRINT '=== Replication Agent Jobs ===';
SELECT name, enabled, date_created, date_modified
FROM msdb.dbo.sysjobs
WHERE category_id IN (
    SELECT category_id FROM msdb.dbo.syscategories
    WHERE name LIKE 'REPL%'
);
GO

PRINT '=== Subscription Status ===';
EXEC distribution.dbo.sp_replmonitorhelpsubscription
    @publisher = @@SERVERNAME,
    @publication_type = 0;
GO

PRINT '=== P2P Originator IDs ===';
SELECT * FROM distribution.dbo.MSpeer_lsns;
GO
