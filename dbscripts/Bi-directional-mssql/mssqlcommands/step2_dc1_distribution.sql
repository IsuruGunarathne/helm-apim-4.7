USE master;
GO

-- Configure DC1 as its own distributor
EXEC sp_adddistributor
    @distributor = 'apim-4-7-eus1-s',
    @password = 'Dist@2025';
GO

-- Create the distribution database
EXEC sp_adddistributiondb
    @database = 'distribution',
    @security_mode = 1;
GO

-- Register this server as a publisher using the distribution database
EXEC sp_adddistpublisher
    @publisher = 'apim-4-7-eus1-s',
    @distribution_db = 'distribution',
    @security_mode = 1;
GO
