EXEC sp_addsubscription
    @publication = 'apim_db_pub',
    @subscriber = 'apim-4-7-wus2-s',
    @destination_db = 'apim_db',
    @subscription_type = 'push',
    @sync_type = 'none',
    @loopback_detection = 'true';
GO

EXEC sp_addpushsubscription_agent
    @publication = 'apim_db_pub',
    @subscriber = 'apim-4-7-wus2-s',
    @subscriber_db = 'apim_db',
    @subscriber_security_mode = 0,
    @subscriber_login = 'repl_dc1',
    @subscriber_password = 'Repl@2025';
GO
