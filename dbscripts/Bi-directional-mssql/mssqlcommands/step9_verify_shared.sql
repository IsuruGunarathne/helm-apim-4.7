EXEC sp_helppublication;
GO

EXEC sp_helparticle @publication = 'shared_db_pub';
GO

EXEC sp_helpsubscription @publication = 'shared_db_pub';
GO
