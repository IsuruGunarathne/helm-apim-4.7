-- DC2 pushes shared_db to DC1
-- NOTE: subscriber uses IP address (from $DC1_HOST) to avoid Named Pipes issues
EXEC sp_addsubscription
    @publication = 'shared_db_pub',
    @subscriber = '$(DC1_HOST)',
    @destination_db = 'shared_db',
    @subscription_type = 'push',
    @sync_type = 'none',
    @loopback_detection = 'true';
GO

EXEC sp_addpushsubscription_agent
    @publication = 'shared_db_pub',
    @subscriber = '$(DC1_HOST)',
    @subscriber_db = 'shared_db',
    @subscriber_security_mode = 0,
    @subscriber_login = 'repl_dc2',
    @subscriber_password = 'Repl@2025';
GO
