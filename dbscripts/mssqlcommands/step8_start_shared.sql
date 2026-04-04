-- Start Log Reader Agent for shared_db
EXEC sp_startpublication_snapshot @publication = 'shared_db_pub';
GO
