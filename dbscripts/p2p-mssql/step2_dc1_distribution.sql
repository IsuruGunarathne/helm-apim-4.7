USE master;
GO

-- Configure DC1 as its own distributor
-- NOTE: Use the server's actual hostname (check with SELECT @@SERVERNAME)
-- Windows may truncate hostnames longer than 15 characters
EXEC sp_adddistributor
    @distributor = '$(SERVER_NAME)',
    @password = 'Dist@2025';
GO

-- Create the distribution database
EXEC sp_adddistributiondb
    @database = 'distribution',
    @security_mode = 1;
GO

-- Register this server as a publisher using the distribution database
EXEC sp_adddistpublisher
    @publisher = '$(SERVER_NAME)',
    @distribution_db = 'distribution',
    @security_mode = 1;
GO
