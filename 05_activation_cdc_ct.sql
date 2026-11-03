/* =====================================================================
   05_activation_cdc_ct.sql  —  Activation de CDC et de Change Tracking
   (fourni par l'enseignant)

   À exécuter dans la base AdventureWorks (OLTP), APRÈS les deux
   chargements initiaux et AVANT 06a_changements_partie1.sql.
   SQL Server Agent doit être démarré (CDC utilise ses travaux).
   ===================================================================== */

/* ---------- 1. Change Data Capture ---------- */
EXEC sys.sp_cdc_enable_db;

EXEC sys.sp_cdc_enable_table
     @source_schema = N'Production', @source_name = N'Product',
     @role_name = NULL, @supports_net_changes = 1;

EXEC sys.sp_cdc_enable_table
     @source_schema = N'Sales', @source_name = N'SalesOrderHeader',
     @role_name = NULL, @supports_net_changes = 1;

EXEC sys.sp_cdc_enable_table
     @source_schema = N'Sales', @source_name = N'SalesOrderDetail',
     @role_name = NULL, @supports_net_changes = 1;

/* Instances de capture créées : Production_Product, Sales_SalesOrderHeader,
   Sales_SalesOrderDetail  ->  fonctions cdc.fn_cdc_get_all_changes_<instance>
   et cdc.fn_cdc_get_net_changes_<instance> */

/* ---------- 2. Change Tracking ---------- */
ALTER DATABASE CURRENT
      SET CHANGE_TRACKING = ON (CHANGE_RETENTION = 7 DAYS, AUTO_CLEANUP = ON);

/* Recommandé par Microsoft pour lire les changements de façon cohérente */
ALTER DATABASE CURRENT SET ALLOW_SNAPSHOT_ISOLATION ON;

ALTER TABLE Production.Product      ENABLE CHANGE_TRACKING WITH (TRACK_COLUMNS_UPDATED = ON);
ALTER TABLE Sales.SalesOrderHeader  ENABLE CHANGE_TRACKING WITH (TRACK_COLUMNS_UPDATED = ON);
ALTER TABLE Sales.SalesOrderDetail  ENABLE CHANGE_TRACKING WITH (TRACK_COLUMNS_UPDATED = ON);

/* ---------- 3. Vérifications (capture d'écran C06) ---------- */
SELECT SCHEMA_NAME(schema_id) AS SchemaSource, name AS TableSource, is_tracked_by_cdc
FROM   sys.tables
WHERE  name IN (N'Product', N'SalesOrderHeader', N'SalesOrderDetail');

SELECT OBJECT_SCHEMA_NAME(object_id) AS SchemaSource,
       OBJECT_NAME(object_id)        AS TableSource,
       is_track_columns_updated_on
FROM   sys.change_tracking_tables;

SELECT job_type, job_id FROM msdb.dbo.cdc_jobs
WHERE  database_id = DB_ID();   -- travaux « capture » et « cleanup »

/* Points de départ des chargements incrémentaux : à enregistrer
   dans meta.EtatCDC et meta.EtatCT de vos data marts */
SELECT sys.fn_cdc_get_max_lsn()          AS LsnDepart,
       CHANGE_TRACKING_CURRENT_VERSION() AS VersionDepart;
