/* =====================================================================
   05b_init_etat.sql  —  Initialisation des points de départ CDC et CT
   À exécuter dans AdventureWorks2022 après 05_activation_cdc_ct.sql
   et avant 06a_changements_partie1.sql.
   ===================================================================== */

USE AdventureWorks2022;
GO

WAITFOR DELAY '00:00:02';

DECLARE @lsn_prod   BINARY(10) = ISNULL(sys.fn_cdc_get_min_lsn('Production_Product'), sys.fn_cdc_get_max_lsn());
DECLARE @lsn_header BINARY(10) = ISNULL(sys.fn_cdc_get_min_lsn('Sales_SalesOrderHeader'), sys.fn_cdc_get_max_lsn());
DECLARE @lsn_detail BINARY(10) = ISNULL(sys.fn_cdc_get_min_lsn('Sales_SalesOrderDetail'), sys.fn_cdc_get_max_lsn());
DECLARE @ver        BIGINT     = CHANGE_TRACKING_CURRENT_VERSION();

DELETE FROM DM_Ventes_CDC.meta.EtatCDC;
INSERT INTO DM_Ventes_CDC.meta.EtatCDC (TableSource, DernierLSN)
VALUES (N'Product',          @lsn_prod),
       (N'SalesOrderHeader', @lsn_header),
       (N'SalesOrderDetail', @lsn_detail);

DELETE FROM DM_Ventes_CT.meta.EtatCT;
INSERT INTO DM_Ventes_CT.meta.EtatCT (TableSource, DerniereVersion)
VALUES (N'Product',          @ver),
       (N'SalesOrderHeader', @ver),
       (N'SalesOrderDetail', @ver);

SELECT * FROM DM_Ventes_CDC.meta.EtatCDC;
SELECT * FROM DM_Ventes_CT.meta.EtatCT;