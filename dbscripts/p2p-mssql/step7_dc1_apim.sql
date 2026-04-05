-- DC1 pushes apim_db changes to DC2
-- NOTE: subscriber uses IP address (from $(DC2_HOST)) to avoid Named Pipes issues
EXEC sp_addsubscription
    @publication = 'apim_db_pub',
    @subscriber = '$(DC2_HOST)',
    @destination_db = 'apim_db',
    @subscription_type = 'push',
    @sync_type = 'replication support only',
    @article = 'all',
    @update_mode = 'read only',
    @subscriber_type = 0;
GO

EXEC sp_addpushsubscription_agent
    @publication = 'apim_db_pub',
    @subscriber = '$(DC2_HOST)',
    @subscriber_db = 'apim_db',
    @subscriber_security_mode = 0,
    @subscriber_login = 'repl_dc1',
    @subscriber_password = 'Repl@2025',
    @frequency_type = 64,
    @frequency_interval = 1;
GO
