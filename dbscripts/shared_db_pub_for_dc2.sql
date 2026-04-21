-- Enabling the replication database
use master
exec sp_replicationdboption @dbname = N'shared_db', @optname = N'publish', @value = N'true'
GO

-- Adding the transactional publication
use [shared_db]
exec sp_addpublication @publication = N'shared_db_pub', @description = N'Peer-to-Peer publication of database ''shared_db'' from Publisher ''apim-4-7-wus2-s''.', @sync_method = N'native', @retention = 0, @allow_push = N'true', @allow_pull = N'true', @allow_anonymous = N'false', @enabled_for_internet = N'false', @snapshot_in_defaultfolder = N'true', @compress_snapshot = N'false', @ftp_port = 21, @ftp_login = N'anonymous', @allow_subscription_copy = N'false', @add_to_active_directory = N'false', @repl_freq = N'continuous', @status = N'active', @independent_agent = N'true', @immediate_sync = N'true', @allow_sync_tran = N'false', @autogen_sync_procs = N'false', @allow_queued_tran = N'false', @allow_dts = N'false', @replicate_ddl = 1, @allow_initialize_from_backup = N'true', @enabled_for_p2p = N'true', @enabled_for_het_sub = N'false', @p2p_conflictdetection = N'true', @p2p_originator_id = 400
GO
exec sp_grant_publication_access @publication = N'shared_db_pub', @login = N'sa'
GO
exec sp_grant_publication_access @publication = N'shared_db_pub', @login = N'apim-4-7-wus2-s\apimadminwest'
GO
exec sp_grant_publication_access @publication = N'shared_db_pub', @login = N'apimadminwest'
GO
exec sp_grant_publication_access @publication = N'shared_db_pub', @login = N'distributor_admin'
GO
exec sp_grant_publication_access @publication = N'shared_db_pub', @login = N'repl_dc1'
GO

-- Adding the transactional articles
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'REG_ASSOCIATION', @source_owner = N'dbo', @source_object = N'REG_ASSOCIATION', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'REG_ASSOCIATION', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_REG_ASSOCIATION335839459]', @del_cmd = N'CALL [d_REG_ASSOCIATION335839459]', @upd_cmd = N'SCALL [u_REG_ASSOCIATION335839459]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'REG_CLUSTER_LOCK', @source_owner = N'dbo', @source_object = N'REG_CLUSTER_LOCK', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'REG_CLUSTER_LOCK', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_REG_CLUSTER_LOCK01487971018]', @del_cmd = N'CALL [d_REG_CLUSTER_LOCK01487971018]', @upd_cmd = N'SCALL [u_REG_CLUSTER_LOCK01487971018]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'REG_COMMENT', @source_owner = N'dbo', @source_object = N'REG_COMMENT', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'REG_COMMENT', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_REG_COMMENT01625424579]', @del_cmd = N'CALL [d_REG_COMMENT01625424579]', @upd_cmd = N'SCALL [u_REG_COMMENT01625424579]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'REG_CONTENT', @source_owner = N'dbo', @source_object = N'REG_CONTENT', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'REG_CONTENT', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_REG_CONTENT595858374]', @del_cmd = N'CALL [d_REG_CONTENT595858374]', @upd_cmd = N'SCALL [u_REG_CONTENT595858374]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'REG_CONTENT_HISTORY', @source_owner = N'dbo', @source_object = N'REG_CONTENT_HISTORY', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'REG_CONTENT_HISTORY', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_REG_CONTENT_HISTORY01628277336]', @del_cmd = N'CALL [d_REG_CONTENT_HISTORY01628277336]', @upd_cmd = N'SCALL [u_REG_CONTENT_HISTORY01628277336]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'REG_LOG', @source_owner = N'dbo', @source_object = N'REG_LOG', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'REG_LOG', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_REG_LOG0220137078]', @del_cmd = N'CALL [d_REG_LOG0220137078]', @upd_cmd = N'SCALL [u_REG_LOG0220137078]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'REG_PATH', @source_owner = N'dbo', @source_object = N'REG_PATH', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'REG_PATH', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_REG_PATH01841519238]', @del_cmd = N'CALL [d_REG_PATH01841519238]', @upd_cmd = N'SCALL [u_REG_PATH01841519238]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'REG_PROPERTY', @source_owner = N'dbo', @source_object = N'REG_PROPERTY', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'REG_PROPERTY', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_REG_PROPERTY0372554300]', @del_cmd = N'CALL [d_REG_PROPERTY0372554300]', @upd_cmd = N'SCALL [u_REG_PROPERTY0372554300]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'REG_RATING', @source_owner = N'dbo', @source_object = N'REG_RATING', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'REG_RATING', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_REG_RATING02018836261]', @del_cmd = N'CALL [d_REG_RATING02018836261]', @upd_cmd = N'SCALL [u_REG_RATING02018836261]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'REG_RESOURCE', @source_owner = N'dbo', @source_object = N'REG_RESOURCE', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'REG_RESOURCE', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_REG_RESOURCE01391827960]', @del_cmd = N'CALL [d_REG_RESOURCE01391827960]', @upd_cmd = N'SCALL [u_REG_RESOURCE01391827960]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'REG_RESOURCE_COMMENT', @source_owner = N'dbo', @source_object = N'REG_RESOURCE_COMMENT', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'REG_RESOURCE_COMMENT', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_REG_RESOURCE_COMMENT016487461]', @del_cmd = N'CALL [d_REG_RESOURCE_COMMENT016487461]', @upd_cmd = N'SCALL [u_REG_RESOURCE_COMMENT016487461]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'REG_RESOURCE_HISTORY', @source_owner = N'dbo', @source_object = N'REG_RESOURCE_HISTORY', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'REG_RESOURCE_HISTORY', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_REG_RESOURCE_HISTORY06081014]', @del_cmd = N'CALL [d_REG_RESOURCE_HISTORY06081014]', @upd_cmd = N'SCALL [u_REG_RESOURCE_HISTORY06081014]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'REG_RESOURCE_PROPERTY', @source_owner = N'dbo', @source_object = N'REG_RESOURCE_PROPERTY', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'REG_RESOURCE_PROPERTY', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_REG_RESOURCE_PROPERTY453673896]', @del_cmd = N'CALL [d_REG_RESOURCE_PROPERTY453673896]', @upd_cmd = N'SCALL [u_REG_RESOURCE_PROPERTY453673896]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'REG_RESOURCE_RATING', @source_owner = N'dbo', @source_object = N'REG_RESOURCE_RATING', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'REG_RESOURCE_RATING', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_REG_RESOURCE_RATING0929306283]', @del_cmd = N'CALL [d_REG_RESOURCE_RATING0929306283]', @upd_cmd = N'SCALL [u_REG_RESOURCE_RATING0929306283]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'REG_RESOURCE_TAG', @source_owner = N'dbo', @source_object = N'REG_RESOURCE_TAG', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'REG_RESOURCE_TAG', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_REG_RESOURCE_TAG436821086]', @del_cmd = N'CALL [d_REG_RESOURCE_TAG436821086]', @upd_cmd = N'SCALL [u_REG_RESOURCE_TAG436821086]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'REG_SNAPSHOT', @source_owner = N'dbo', @source_object = N'REG_SNAPSHOT', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'REG_SNAPSHOT', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_REG_SNAPSHOT2045561160]', @del_cmd = N'CALL [d_REG_SNAPSHOT2045561160]', @upd_cmd = N'SCALL [u_REG_SNAPSHOT2045561160]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'REG_TAG', @source_owner = N'dbo', @source_object = N'REG_TAG', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'REG_TAG', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_REG_TAG1530509570]', @del_cmd = N'CALL [d_REG_TAG1530509570]', @upd_cmd = N'SCALL [u_REG_TAG1530509570]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'UM_ACCOUNT_MAPPING', @source_owner = N'dbo', @source_object = N'UM_ACCOUNT_MAPPING', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'UM_ACCOUNT_MAPPING', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_UM_ACCOUNT_MAPPING0692810916]', @del_cmd = N'CALL [d_UM_ACCOUNT_MAPPING0692810916]', @upd_cmd = N'SCALL [u_UM_ACCOUNT_MAPPING0692810916]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'UM_CLAIM', @source_owner = N'dbo', @source_object = N'UM_CLAIM', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'UM_CLAIM', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_UM_CLAIM01725669874]', @del_cmd = N'CALL [d_UM_CLAIM01725669874]', @upd_cmd = N'SCALL [u_UM_CLAIM01725669874]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'UM_CLAIM_BEHAVIOR', @source_owner = N'dbo', @source_object = N'UM_CLAIM_BEHAVIOR', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'UM_CLAIM_BEHAVIOR', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_UM_CLAIM_BEHAVIOR517472888]', @del_cmd = N'CALL [d_UM_CLAIM_BEHAVIOR517472888]', @upd_cmd = N'SCALL [u_UM_CLAIM_BEHAVIOR517472888]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'UM_DIALECT', @source_owner = N'dbo', @source_object = N'UM_DIALECT', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'UM_DIALECT', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_UM_DIALECT01029984383]', @del_cmd = N'CALL [d_UM_DIALECT01029984383]', @upd_cmd = N'SCALL [u_UM_DIALECT01029984383]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'UM_DOMAIN', @source_owner = N'dbo', @source_object = N'UM_DOMAIN', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'UM_DOMAIN', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_UM_DOMAIN01757510]', @del_cmd = N'CALL [d_UM_DOMAIN01757510]', @upd_cmd = N'SCALL [u_UM_DOMAIN01757510]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'UM_GROUP_UUID_DOMAIN_MAPPER', @source_owner = N'dbo', @source_object = N'UM_GROUP_UUID_DOMAIN_MAPPER', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'UM_GROUP_UUID_DOMAIN_MAPPER', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_UM_GROUP_UUID_DOMAIN_MAPPER060893296]', @del_cmd = N'CALL [d_UM_GROUP_UUID_DOMAIN_MAPPER060893296]', @upd_cmd = N'SCALL [u_UM_GROUP_UUID_DOMAIN_MAPPER060893296]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'UM_HYBRID_GROUP_ROLE', @source_owner = N'dbo', @source_object = N'UM_HYBRID_GROUP_ROLE', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'UM_HYBRID_GROUP_ROLE', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_UM_HYBRID_GROUP_ROLE1152340219]', @del_cmd = N'CALL [d_UM_HYBRID_GROUP_ROLE1152340219]', @upd_cmd = N'SCALL [u_UM_HYBRID_GROUP_ROLE1152340219]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'UM_HYBRID_REMEMBER_ME', @source_owner = N'dbo', @source_object = N'UM_HYBRID_REMEMBER_ME', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'UM_HYBRID_REMEMBER_ME', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_UM_HYBRID_REMEMBER_ME1831466714]', @del_cmd = N'CALL [d_UM_HYBRID_REMEMBER_ME1831466714]', @upd_cmd = N'SCALL [u_UM_HYBRID_REMEMBER_ME1831466714]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'UM_HYBRID_ROLE', @source_owner = N'dbo', @source_object = N'UM_HYBRID_ROLE', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'UM_HYBRID_ROLE', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_UM_HYBRID_ROLE1241900352]', @del_cmd = N'CALL [d_UM_HYBRID_ROLE1241900352]', @upd_cmd = N'SCALL [u_UM_HYBRID_ROLE1241900352]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'UM_HYBRID_USER_ROLE', @source_owner = N'dbo', @source_object = N'UM_HYBRID_USER_ROLE', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'UM_HYBRID_USER_ROLE', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_UM_HYBRID_USER_ROLE01574650617]', @del_cmd = N'CALL [d_UM_HYBRID_USER_ROLE01574650617]', @upd_cmd = N'SCALL [u_UM_HYBRID_USER_ROLE01574650617]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'UM_MODULE', @source_owner = N'dbo', @source_object = N'UM_MODULE', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'UM_MODULE', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_UM_MODULE01415002005]', @del_cmd = N'CALL [d_UM_MODULE01415002005]', @upd_cmd = N'SCALL [u_UM_MODULE01415002005]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'UM_MODULE_ACTIONS', @source_owner = N'dbo', @source_object = N'UM_MODULE_ACTIONS', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'UM_MODULE_ACTIONS', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_UM_MODULE_ACTIONS01055221457]', @del_cmd = N'CALL [d_UM_MODULE_ACTIONS01055221457]', @upd_cmd = N'SCALL [u_UM_MODULE_ACTIONS01055221457]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'UM_ORG', @source_owner = N'dbo', @source_object = N'UM_ORG', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'UM_ORG', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_UM_ORG1092528398]', @del_cmd = N'CALL [d_UM_ORG1092528398]', @upd_cmd = N'SCALL [u_UM_ORG1092528398]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'UM_ORG_ATTRIBUTE', @source_owner = N'dbo', @source_object = N'UM_ORG_ATTRIBUTE', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'UM_ORG_ATTRIBUTE', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_UM_ORG_ATTRIBUTE1970762500]', @del_cmd = N'CALL [d_UM_ORG_ATTRIBUTE1970762500]', @upd_cmd = N'SCALL [u_UM_ORG_ATTRIBUTE1970762500]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'UM_ORG_HIERARCHY', @source_owner = N'dbo', @source_object = N'UM_ORG_HIERARCHY', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'UM_ORG_HIERARCHY', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_UM_ORG_HIERARCHY375613871]', @del_cmd = N'CALL [d_UM_ORG_HIERARCHY375613871]', @upd_cmd = N'SCALL [u_UM_ORG_HIERARCHY375613871]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'UM_ORG_PERMISSION', @source_owner = N'dbo', @source_object = N'UM_ORG_PERMISSION', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'UM_ORG_PERMISSION', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_UM_ORG_PERMISSION01247139875]', @del_cmd = N'CALL [d_UM_ORG_PERMISSION01247139875]', @upd_cmd = N'SCALL [u_UM_ORG_PERMISSION01247139875]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'UM_ORG_ROLE', @source_owner = N'dbo', @source_object = N'UM_ORG_ROLE', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'UM_ORG_ROLE', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_UM_ORG_ROLE01017195300]', @del_cmd = N'CALL [d_UM_ORG_ROLE01017195300]', @upd_cmd = N'SCALL [u_UM_ORG_ROLE01017195300]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'UM_ORG_ROLE_GROUP', @source_owner = N'dbo', @source_object = N'UM_ORG_ROLE_GROUP', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'UM_ORG_ROLE_GROUP', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_UM_ORG_ROLE_GROUP433319917]', @del_cmd = N'CALL [d_UM_ORG_ROLE_GROUP433319917]', @upd_cmd = N'SCALL [u_UM_ORG_ROLE_GROUP433319917]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'UM_ORG_ROLE_PERMISSION', @source_owner = N'dbo', @source_object = N'UM_ORG_ROLE_PERMISSION', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'UM_ORG_ROLE_PERMISSION', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_UM_ORG_ROLE_PERMISSION1134206707]', @del_cmd = N'CALL [d_UM_ORG_ROLE_PERMISSION1134206707]', @upd_cmd = N'SCALL [u_UM_ORG_ROLE_PERMISSION1134206707]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'UM_ORG_ROLE_USER', @source_owner = N'dbo', @source_object = N'UM_ORG_ROLE_USER', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'UM_ORG_ROLE_USER', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_UM_ORG_ROLE_USER568744146]', @del_cmd = N'CALL [d_UM_ORG_ROLE_USER568744146]', @upd_cmd = N'SCALL [u_UM_ORG_ROLE_USER568744146]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'UM_PERMISSION', @source_owner = N'dbo', @source_object = N'UM_PERMISSION', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'UM_PERMISSION', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_UM_PERMISSION04489398]', @del_cmd = N'CALL [d_UM_PERMISSION04489398]', @upd_cmd = N'SCALL [u_UM_PERMISSION04489398]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'UM_PROFILE_CONFIG', @source_owner = N'dbo', @source_object = N'UM_PROFILE_CONFIG', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'UM_PROFILE_CONFIG', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_UM_PROFILE_CONFIG114403591]', @del_cmd = N'CALL [d_UM_PROFILE_CONFIG114403591]', @upd_cmd = N'SCALL [u_UM_PROFILE_CONFIG114403591]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'UM_ROLE', @source_owner = N'dbo', @source_object = N'UM_ROLE', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'UM_ROLE', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_UM_ROLE01166340673]', @del_cmd = N'CALL [d_UM_ROLE01166340673]', @upd_cmd = N'SCALL [u_UM_ROLE01166340673]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'UM_ROLE_PERMISSION', @source_owner = N'dbo', @source_object = N'UM_ROLE_PERMISSION', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'UM_ROLE_PERMISSION', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_UM_ROLE_PERMISSION1012414886]', @del_cmd = N'CALL [d_UM_ROLE_PERMISSION1012414886]', @upd_cmd = N'SCALL [u_UM_ROLE_PERMISSION1012414886]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'UM_SHARED_USER_ROLE', @source_owner = N'dbo', @source_object = N'UM_SHARED_USER_ROLE', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'UM_SHARED_USER_ROLE', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_UM_SHARED_USER_ROLE1612595468]', @del_cmd = N'CALL [d_UM_SHARED_USER_ROLE1612595468]', @upd_cmd = N'SCALL [u_UM_SHARED_USER_ROLE1612595468]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'UM_SYSTEM_ROLE', @source_owner = N'dbo', @source_object = N'UM_SYSTEM_ROLE', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'UM_SYSTEM_ROLE', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_UM_SYSTEM_ROLE291619986]', @del_cmd = N'CALL [d_UM_SYSTEM_ROLE291619986]', @upd_cmd = N'SCALL [u_UM_SYSTEM_ROLE291619986]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'UM_SYSTEM_USER', @source_owner = N'dbo', @source_object = N'UM_SYSTEM_USER', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'UM_SYSTEM_USER', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_UM_SYSTEM_USER1826942898]', @del_cmd = N'CALL [d_UM_SYSTEM_USER1826942898]', @upd_cmd = N'SCALL [u_UM_SYSTEM_USER1826942898]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'UM_SYSTEM_USER_ROLE', @source_owner = N'dbo', @source_object = N'UM_SYSTEM_USER_ROLE', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'UM_SYSTEM_USER_ROLE', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_UM_SYSTEM_USER_ROLE608286777]', @del_cmd = N'CALL [d_UM_SYSTEM_USER_ROLE608286777]', @upd_cmd = N'SCALL [u_UM_SYSTEM_USER_ROLE608286777]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'UM_TENANT', @source_owner = N'dbo', @source_object = N'UM_TENANT', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'UM_TENANT', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_UM_TENANT0859784020]', @del_cmd = N'CALL [d_UM_TENANT0859784020]', @upd_cmd = N'SCALL [u_UM_TENANT0859784020]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'UM_USER', @source_owner = N'dbo', @source_object = N'UM_USER', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'UM_USER', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_UM_USER02042848740]', @del_cmd = N'CALL [d_UM_USER02042848740]', @upd_cmd = N'SCALL [u_UM_USER02042848740]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'UM_USER_ATTRIBUTE', @source_owner = N'dbo', @source_object = N'UM_USER_ATTRIBUTE', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'UM_USER_ATTRIBUTE', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_UM_USER_ATTRIBUTE02124626910]', @del_cmd = N'CALL [d_UM_USER_ATTRIBUTE02124626910]', @upd_cmd = N'SCALL [u_UM_USER_ATTRIBUTE02124626910]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'UM_USER_PERMISSION', @source_owner = N'dbo', @source_object = N'UM_USER_PERMISSION', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'UM_USER_PERMISSION', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_UM_USER_PERMISSION01339717639]', @del_cmd = N'CALL [d_UM_USER_PERMISSION01339717639]', @upd_cmd = N'SCALL [u_UM_USER_PERMISSION01339717639]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'UM_USER_ROLE', @source_owner = N'dbo', @source_object = N'UM_USER_ROLE', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'UM_USER_ROLE', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_UM_USER_ROLE01458995746]', @del_cmd = N'CALL [d_UM_USER_ROLE01458995746]', @upd_cmd = N'SCALL [u_UM_USER_ROLE01458995746]'
GO
use [shared_db]
exec sp_addarticle @publication = N'shared_db_pub', @article = N'UM_UUID_DOMAIN_MAPPER', @source_owner = N'dbo', @source_object = N'UM_UUID_DOMAIN_MAPPER', @type = N'logbased', @description = N'', @creation_script = N'', @pre_creation_cmd = N'drop', @schema_option = 0x0000000008035DDF, @identityrangemanagementoption = N'manual', @destination_table = N'UM_UUID_DOMAIN_MAPPER', @destination_owner = N'dbo', @status = 24, @vertical_partition = N'false', @ins_cmd = N'CALL [i_UM_UUID_DOMAIN_MAPPER814549329]', @del_cmd = N'CALL [d_UM_UUID_DOMAIN_MAPPER814549329]', @upd_cmd = N'SCALL [u_UM_UUID_DOMAIN_MAPPER814549329]'
GO

