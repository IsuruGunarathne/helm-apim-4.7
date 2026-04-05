-- Clean up test rows (run on either DC — will replicate to the other)
DELETE FROM AM_ALERT_TYPES WHERE ALERT_TYPE_ID IN (998, 999);
GO
