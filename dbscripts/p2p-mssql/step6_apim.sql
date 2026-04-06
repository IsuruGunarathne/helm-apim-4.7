-- Add all tables in apim_db as articles to the P2P publication
-- Run this on BOTH DC1 and DC2

DECLARE @table_name NVARCHAR(256);
DECLARE table_cursor CURSOR FOR
    SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES
    WHERE TABLE_TYPE = 'BASE TABLE' AND TABLE_SCHEMA = 'dbo';

OPEN table_cursor;
FETCH NEXT FROM table_cursor INTO @table_name;

WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC sp_addarticle
        @publication = 'apim_db_pub',
        @article = @table_name,
        @source_object = @table_name,
        @type = 'logbased',
        @schema_option = 0x0000000008000001,
        @identityrangemanagementoption = 'manual';
    FETCH NEXT FROM table_cursor INTO @table_name;
END

CLOSE table_cursor;
DEALLOCATE table_cursor;
GO
