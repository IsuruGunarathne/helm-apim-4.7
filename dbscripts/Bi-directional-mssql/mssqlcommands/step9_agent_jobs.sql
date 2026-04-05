SELECT name, enabled, date_created, date_modified
FROM msdb.dbo.sysjobs
WHERE category_id IN (
    SELECT category_id FROM msdb.dbo.syscategories
    WHERE name LIKE 'REPL%'
);
GO
