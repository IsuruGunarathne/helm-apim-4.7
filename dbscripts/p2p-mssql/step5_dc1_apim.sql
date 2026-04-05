-- Enable publishing on apim_db
EXEC sp_replicationdboption
    @dbname = 'apim_db',
    @optname = 'publish',
    @value = 'true';
GO

-- Create P2P publication for apim_db on DC1 (originator_id = 1)
EXEC sp_addpublication
    @publication = 'apim_db_pub',
    @enabled_for_p2p = 'true',
    @p2p_conflictdetection = 'true',
    @p2p_originator_id = 1,
    @p2p_continue_onconflict = 'true',
    @p2p_conflictdetection_policy = 'lastwriter',
    @allow_initialize_from_backup = 'true',
    @allow_push = 'true',
    @allow_pull = 'true',
    @allow_anonymous = 'false',
    @independent_agent = 'true',
    @immediate_sync = 'true',
    @repl_freq = 'continuous',
    @status = 'active',
    @replicate_ddl = 1,
    @retention = 0;
GO
