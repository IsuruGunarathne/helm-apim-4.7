-- DC2 pushes apim_db to DC1
-- NOTE: subscriber uses IP address (from $DC1_HOST) to avoid Named Pipes issues
EXEC sp_addsubscription
    @publication = 'apim_db_pub',
    @subscriber = '$(DC1_HOST)',
    @destination_db = 'apim_db',
    @subscription_type = 'push',
    @sync_type = 'none',
    @loopback_detection = 'true';
GO

EXEC sp_addpushsubscription_agent
    @publication = 'apim_db_pub',
    @subscriber = '$(DC1_HOST)',
    @subscriber_db = 'apim_db',
    @subscriber_security_mode = 0,
    @subscriber_login = 'repl_dc2',
    @subscriber_password = 'Repl@2025';
GO
