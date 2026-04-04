EXEC sp_replicationdboption
    @dbname = 'apim_db',
    @optname = 'publish',
    @value = 'true';
GO

EXEC sp_addpublication
    @publication = 'apim_db_pub',
    @status = 'active',
    @allow_push = 'true',
    @allow_pull = 'true',
    @independent_agent = 'true',
    @immediate_sync = 'false',
    @replicate_ddl = 0,
    @allow_initialize_from_backup = 'true';
GO
