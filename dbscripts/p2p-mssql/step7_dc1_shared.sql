-- DC1 pushes shared_db changes to DC2
-- NOTE: subscriber uses IP address (from $(DC2_HOST)) to avoid Named Pipes issues
EXEC sp_addsubscription
    @publication = 'shared_db_pub',
    @subscriber = '$(DC2_HOST)',
    @destination_db = 'shared_db',
    @subscription_type = 'push',
    @sync_type = 'replication support only',
    @article = 'all',
    @update_mode = 'read only',
    @subscriber_type = 0;
GO

EXEC sp_addpushsubscription_agent
    @publication = 'shared_db_pub',
    @subscriber = '$(DC2_HOST)',
    @subscriber_db = 'shared_db',
    @subscriber_security_mode = 0,
    @subscriber_login = 'repl_dc1',
    @subscriber_password = 'Repl@2025',
    @frequency_type = 64,
    @frequency_interval = 1;
GO
