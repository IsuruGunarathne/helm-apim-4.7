-- DC1 pushes apim_db to DC2
-- NOTE: subscriber uses IP address (from $DC2_HOST) to avoid Named Pipes issues
-- Replace <DC2_IP> with the actual DC2 IP if not using the sqlcmd variable substitution
EXEC sp_addsubscription
    @publication = 'apim_db_pub',
    @subscriber = '$(DC2_HOST)',
    @destination_db = 'apim_db',
    @subscription_type = 'push',
    @sync_type = 'none',
    @loopback_detection = 'true';
GO

EXEC sp_addpushsubscription_agent
    @publication = 'apim_db_pub',
    @subscriber = '$(DC2_HOST)',
    @subscriber_db = 'apim_db',
    @subscriber_security_mode = 0,
    @subscriber_login = 'repl_dc1',
    @subscriber_password = 'Repl@2025';
GO
