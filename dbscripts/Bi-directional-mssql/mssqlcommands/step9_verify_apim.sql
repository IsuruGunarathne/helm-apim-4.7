-- List publications
EXEC sp_helppublication;
GO

-- List articles in the publication
EXEC sp_helparticle @publication = 'apim_db_pub';
GO

-- List subscriptions
EXEC sp_helpsubscription @publication = 'apim_db_pub';
GO
