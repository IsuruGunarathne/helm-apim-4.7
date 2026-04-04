-- Start Log Reader Agent for apim_db
EXEC sp_startpublication_snapshot @publication = 'apim_db_pub';
GO
