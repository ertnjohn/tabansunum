\xEF\xBB\xBF/* =====================================================================
   02_metadonnees.sql  -  Metadonnees techniques, dictionnaire, lignage

   A executer APRES 01_schema.sql (AdventureWorks doit etre restauree
   sous le nom AdventureWorks).

   Partie 1 : metadonnees techniques de la source, obtenues PAR REQUETE
              (INFORMATION_SCHEMA et vues sys), jamais saisies a la main.
   Partie 2 : meta.DictionnaireDonnees (metadonnees metier) dans les deux
              data marts + proprietes etendues MS_Description.
   Partie 3 : meta.MappingColonnes (lignage) dans les deux data marts.

   Le script peut etre relance : il vide et remplit a nouveau les tables.
   ===================================================================== */

SET NOCOUNT ON;
GO

/* =====================================================================
   PARTIE 1 - Metadonnees techniques des cinq tables sources
   ===================================================================== */
USE AdventureWorks;
GO

DECLARE @sources TABLE (SchemaSource SYSNAME, TableSource SYSNAME);
INSERT INTO @sources VALUES
    (N'Production', N'Product'),
    (N'Production', N'ProductSubcategory'),
    (N'Production', N'ProductCategory'),
    (N'Sales',      N'SalesOrderHeader'),
    (N'Sales',      N'SalesOrderDetail');

/* 1a. Colonnes et types */
SELECT c.TABLE_SCHEMA            AS SchemaSource,
       c.TABLE_NAME              AS TableSource,
       c.ORDINAL_POSITION        AS Position,
       c.COLUMN_NAME             AS Colonne,
       c.DATA_TYPE               AS TypeDonnees,
       c.CHARACTER_MAXIMUM_LENGTH AS LongueurMax,
       c.NUMERIC_PRECISION       AS Precision,
       c.NUMERIC_SCALE           AS Echelle,
       c.IS_NULLABLE             AS Nullable
FROM   INFORMATION_SCHEMA.COLUMNS AS c
JOIN   @sources AS s ON s.SchemaSource = c.TABLE_SCHEMA AND s.TableSource = c.TABLE_NAME
ORDER BY c.TABLE_SCHEMA, c.TABLE_NAME, c.ORDINAL_POSITION;

/* 1b. Cles primaires et etrangeres */
SELECT tc.TABLE_SCHEMA     AS SchemaSource,
       tc.TABLE_NAME       AS TableSource,
       tc.CONSTRAINT_TYPE  AS TypeCle,
       tc.CONSTRAINT_NAME  AS NomContrainte,
       k.COLUMN_NAME       AS Colonne,
       k.ORDINAL_POSITION  AS Position
FROM   INFORMATION_SCHEMA.TABLE_CONSTRAINTS AS tc
JOIN   INFORMATION_SCHEMA.KEY_COLUMN_USAGE  AS k
       ON  k.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA
       AND k.CONSTRAINT_NAME   = tc.CONSTRAINT_NAME
JOIN   @sources AS s ON s.SchemaSource = tc.TABLE_SCHEMA AND s.TableSource = tc.TABLE_NAME
WHERE  tc.CONSTRAINT_TYPE IN (N'PRIMARY KEY', N'FOREIGN KEY')
ORDER BY tc.TABLE_SCHEMA, tc.TABLE_NAME, tc.CONSTRAINT_TYPE DESC, tc.CONSTRAINT_NAME, k.ORDINAL_POSITION;

/* 1c. Nombre de lignes */
SELECT sc.name     AS SchemaSource,
       t.name      AS TableSource,
       SUM(p.rows) AS NbLignes
FROM   sys.tables     AS t
JOIN   sys.schemas    AS sc ON sc.schema_id = t.schema_id
JOIN   sys.partitions AS p  ON p.object_id = t.object_id AND p.index_id IN (0, 1)
JOIN   @sources       AS s  ON s.SchemaSource = sc.name AND s.TableSource = t.name
GROUP BY sc.name, t.name
ORDER BY sc.name, t.name;
GO


/* =====================================================================
   Contenu commun aux deux data marts (tables temporaires de session)
   ===================================================================== */
USE master;
GO

DROP TABLE IF EXISTS #Dico;
CREATE TABLE #Dico (
    Ordre         INT IDENTITY(1,1),
    SchemaCible   SYSNAME,
    TableCible    SYSNAME,
    ColonneCible  SYSNAME,
    Definition    NVARCHAR(500)
);

INSERT INTO #Dico (SchemaCible, TableCible, ColonneCible, Definition) VALUES
 (N'dm', N'DimDate', N'CleDate',      N'Clé de la date au format AAAAMMJJ (ex. 20250305).'),
 (N'dm', N'DimDate', N'Date',         N'Date calendaire.'),
 (N'dm', N'DimDate', N'Annee',        N'Année civile.'),
 (N'dm', N'DimDate', N'Trimestre',    N'Trimestre civil (1 à 4).'),
 (N'dm', N'DimDate', N'Mois',         N'Numéro du mois (1 à 12).'),
 (N'dm', N'DimDate', N'NomMois',      N'Nom du mois en français.'),
 (N'dm', N'DimDate', N'Jour',         N'Jour du mois (1 à 31).'),
 (N'dm', N'DimDate', N'JourSemaine',  N'Nom du jour de la semaine en français.'),

 (N'dm', N'DimProduit', N'CleProduit',    N'Clé de substitution : identifie une version d’un produit.'),
 (N'dm', N'DimProduit', N'ProductID',     N'Identifiant du produit dans la source (clé métier), commun à toutes ses versions.'),
 (N'dm', N'DimProduit', N'CodeProduit',   N'Code produit (référence catalogue).'),
 (N'dm', N'DimProduit', N'Nom',           N'Nom du produit ; une correction écrase la valeur dans toutes les versions (SCD 1).'),
 (N'dm', N'DimProduit', N'SousCategorie', N'Sous-catégorie valide pendant la période de la version (SCD 2) ; « Inconnu » si absente.'),
 (N'dm', N'DimProduit', N'Categorie',     N'Catégorie de la sous-catégorie ; « Inconnu » si absente.'),
 (N'dm', N'DimProduit', N'PrixCatalogue', N'Prix catalogue valide pendant la période de la version (SCD 2).'),
 (N'dm', N'DimProduit', N'DateDebut',     N'Début de validité de la version.'),
 (N'dm', N'DimProduit', N'DateFin',       N'Fin de validité de la version ; NULL pour la version courante.'),
 (N'dm', N'DimProduit', N'EstCourant',    N'1 si la version est la version courante du produit, 0 sinon.'),

 (N'dm', N'FaitVente', N'NumCommande',  N'Numéro de la commande.'),
 (N'dm', N'FaitVente', N'NumLigne',     N'Numéro de la ligne de commande.'),
 (N'dm', N'FaitVente', N'CleDate',      N'Date de la commande (référence à DimDate).'),
 (N'dm', N'FaitVente', N'CleProduit',   N'Version du produit valide à la date de la commande (référence à DimProduit).'),
 (N'dm', N'FaitVente', N'Quantite',     N'Quantité commandée.'),
 (N'dm', N'FaitVente', N'PrixUnitaire', N'Prix unitaire appliqué lors de la vente.'),
 (N'dm', N'FaitVente', N'Montant',      N'Montant de la ligne de vente = quantité × prix unitaire.');

DROP TABLE IF EXISTS #Map;
CREATE TABLE #Map (
    Ordre            INT IDENTITY(1,1),
    TableCible       NVARCHAR(128),
    ColonneCible     NVARCHAR(128),
    TablesSources    NVARCHAR(400),
    ColonnesSources  NVARCHAR(400),
    RegleCDC         NVARCHAR(1000),    -- regle pour DM_Ventes_CDC (ETL + CDC)
    RegleCT          NVARCHAR(1000)     -- regle pour DM_Ventes_CT  (ELT + CT)
);

INSERT INTO #Map (TableCible, ColonneCible, TablesSources, ColonnesSources, RegleCDC, RegleCT) VALUES
 (N'dm.DimDate', N'CleDate',     NULL, NULL, N'Générée (Python) : année × 10000 + mois × 100 + jour', NULL),
 (N'dm.DimDate', N'Date',        NULL, NULL, N'Générée (Python) : un jour par ligne du 2010-01-01 au 2030-12-31', NULL),
 (N'dm.DimDate', N'Annee',       NULL, NULL, N'Générée (Python) : année de Date', NULL),
 (N'dm.DimDate', N'Trimestre',   NULL, NULL, N'Générée (Python) : (mois - 1) / 3 + 1', NULL),
 (N'dm.DimDate', N'Mois',        NULL, NULL, N'Générée (Python) : mois de Date', NULL),
 (N'dm.DimDate', N'NomMois',     NULL, NULL, N'Générée (Python) : nom du mois en français', NULL),
 (N'dm.DimDate', N'Jour',        NULL, NULL, N'Générée (Python) : jour de Date', NULL),
 (N'dm.DimDate', N'JourSemaine', NULL, NULL, N'Générée (Python) : nom du jour en français', NULL),

 (N'dm.DimProduit', N'CleProduit',    NULL, NULL, N'IDENTITY : nouvelle valeur pour chaque version', NULL),
 (N'dm.DimProduit', N'ProductID',     N'Production.Product', N'ProductID',     N'Copie directe (clé métier)', NULL),
 (N'dm.DimProduit', N'CodeProduit',   N'Production.Product', N'ProductNumber', N'Copie directe', NULL),
 (N'dm.DimProduit', N'Nom',           N'Production.Product', N'Name',          N'Copie directe ; SCD 1 : une correction met à jour toutes les versions', NULL),
 (N'dm.DimProduit', N'SousCategorie', N'Production.Product, Production.ProductSubcategory', N'ProductSubcategoryID, Name',
                                      N'Jointure externe sur ProductSubcategoryID ; « Inconnu » si absente ; SCD 2 : un changement ouvre une nouvelle version', NULL),
 (N'dm.DimProduit', N'Categorie',     N'Production.ProductSubcategory, Production.ProductCategory', N'ProductCategoryID, Name',
                                      N'Jointure externe sur ProductCategoryID ; « Inconnu » si absente', NULL),
 (N'dm.DimProduit', N'PrixCatalogue', N'Production.Product', N'ListPrice',     N'Copie directe ; SCD 2 : un changement ouvre une nouvelle version', NULL),
 (N'dm.DimProduit', N'DateDebut',     NULL, NULL,
                                      N'Chargement initial : 2010-01-01 ; incrémental : heure réelle du changement (sys.fn_cdc_map_lsn_to_time)',
                                      N'Chargement initial : 2010-01-01 ; incrémental : date du chargement (heure du changement non disponible avec Change Tracking)'),
 (N'dm.DimProduit', N'DateFin',       NULL, NULL, N'NULL pour la version courante ; à la clôture : DateDebut de la nouvelle version', NULL),
 (N'dm.DimProduit', N'EstCourant',    NULL, NULL, N'1 pour la version courante, 0 après clôture', NULL),

 (N'dm.FaitVente', N'NumCommande',  N'Sales.SalesOrderDetail', N'SalesOrderID',       N'Copie directe', NULL),
 (N'dm.FaitVente', N'NumLigne',     N'Sales.SalesOrderDetail', N'SalesOrderDetailID', N'Copie directe', NULL),
 (N'dm.FaitVente', N'CleDate',      N'Sales.SalesOrderHeader', N'OrderDate',          N'année × 10000 + mois × 100 + jour de OrderDate', NULL),
 (N'dm.FaitVente', N'CleProduit',   N'Sales.SalesOrderDetail, Sales.SalesOrderHeader, dm.DimProduit', N'ProductID, OrderDate',
                                    N'Version de DimProduit avec le même ProductID et DateDebut <= OrderDate < DateFin (ou DateFin NULL)', NULL),
 (N'dm.FaitVente', N'Quantite',     N'Sales.SalesOrderDetail', N'OrderQty',           N'Copie directe ; mise à jour si la ligne source est modifiée', NULL),
 (N'dm.FaitVente', N'PrixUnitaire', N'Sales.SalesOrderDetail', N'UnitPrice',          N'Copie directe', NULL),
 (N'dm.FaitVente', N'Montant',      N'Sales.SalesOrderDetail', N'OrderQty, UnitPrice', N'OrderQty × UnitPrice', NULL);

/* Meme regle dans les deux bases sauf indication contraire */
UPDATE #Map SET RegleCT = RegleCDC WHERE RegleCT IS NULL;
GO


/* =====================================================================
   PARTIE 2 - Dictionnaire de donnees (metadonnees metier)
   ===================================================================== */
DELETE FROM DM_Ventes_CDC.meta.DictionnaireDonnees;
INSERT INTO DM_Ventes_CDC.meta.DictionnaireDonnees (TableCible, ColonneCible, Definition)
SELECT SchemaCible + N'.' + TableCible, ColonneCible, Definition FROM #Dico ORDER BY Ordre;

DELETE FROM DM_Ventes_CT.meta.DictionnaireDonnees;
INSERT INTO DM_Ventes_CT.meta.DictionnaireDonnees (TableCible, ColonneCible, Definition)
SELECT SchemaCible + N'.' + TableCible, ColonneCible, Definition FROM #Dico ORDER BY Ordre;
GO

/* Proprietes etendues MS_Description sur chaque colonne cible.
   Le meme code est execute dans chacune des deux bases. */
DECLARE @sql NVARCHAR(MAX) = N'
DECLARE @s SYSNAME, @t SYSNAME, @c SYSNAME, @d NVARCHAR(500);
DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT SchemaCible, TableCible, ColonneCible, Definition FROM #Dico ORDER BY Ordre;
OPEN cur;
FETCH NEXT FROM cur INTO @s, @t, @c, @d;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF EXISTS (SELECT 1
               FROM sys.extended_properties AS ep
               JOIN sys.columns AS col ON col.object_id = ep.major_id AND col.column_id = ep.minor_id
               WHERE ep.class = 1
                 AND ep.name = N''MS_Description''
                 AND ep.major_id = OBJECT_ID(QUOTENAME(@s) + N''.'' + QUOTENAME(@t))
                 AND col.name = @c)
        EXEC sys.sp_updateextendedproperty
             @name = N''MS_Description'', @value = @d,
             @level0type = N''SCHEMA'', @level0name = @s,
             @level1type = N''TABLE'',  @level1name = @t,
             @level2type = N''COLUMN'', @level2name = @c;
    ELSE
        EXEC sys.sp_addextendedproperty
             @name = N''MS_Description'', @value = @d,
             @level0type = N''SCHEMA'', @level0name = @s,
             @level1type = N''TABLE'',  @level1name = @t,
             @level2type = N''COLUMN'', @level2name = @c;
    FETCH NEXT FROM cur INTO @s, @t, @c, @d;
END;
CLOSE cur;
DEALLOCATE cur;';

EXEC DM_Ventes_CDC.sys.sp_executesql @sql;
EXEC DM_Ventes_CT.sys.sp_executesql @sql;
GO


/* =====================================================================
   PARTIE 3 - Lignage (meta.MappingColonnes)
   ===================================================================== */

/* DM_Ventes_CDC : ETL, la source est directement AdventureWorks */
TRUNCATE TABLE DM_Ventes_CDC.meta.MappingColonnes;
INSERT INTO DM_Ventes_CDC.meta.MappingColonnes (TableCible, ColonneCible, TablesSources, ColonnesSources, RegleTransformation)
SELECT TableCible, ColonneCible, TablesSources, ColonnesSources, RegleCDC
FROM   #Map ORDER BY Ordre;

/* DM_Ventes_CT : ELT, dm est alimente a partir de stg ... */
TRUNCATE TABLE DM_Ventes_CT.meta.MappingColonnes;
INSERT INTO DM_Ventes_CT.meta.MappingColonnes (TableCible, ColonneCible, TablesSources, ColonnesSources, RegleTransformation)
SELECT TableCible, ColonneCible,
       REPLACE(REPLACE(TablesSources, N'Production.', N'stg.'), N'Sales.', N'stg.'),
       ColonnesSources, RegleCT
FROM   #Map ORDER BY Ordre;

/* ... et stg est une copie brute d'AdventureWorks */
INSERT INTO DM_Ventes_CT.meta.MappingColonnes (TableCible, ColonneCible, TablesSources, ColonnesSources, RegleTransformation)
SELECT N'stg.' + c.TABLE_NAME,
       c.COLUMN_NAME,
       CASE WHEN c.TABLE_NAME LIKE N'Sales%' THEN N'Sales.' ELSE N'Production.' END + c.TABLE_NAME,
       c.COLUMN_NAME,
       N'Copie brute sans transformation (04_elt.py)'
FROM   DM_Ventes_CT.INFORMATION_SCHEMA.COLUMNS AS c
WHERE  c.TABLE_SCHEMA = N'stg'
ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION;
GO

DROP TABLE IF EXISTS #Dico;
DROP TABLE IF EXISTS #Map;
GO


/* =====================================================================
   Verifications (capture C03)
   ===================================================================== */
SELECT N'DM_Ventes_CDC' AS Base,
       (SELECT COUNT(*) FROM DM_Ventes_CDC.meta.DictionnaireDonnees) AS NbDefinitions,
       (SELECT COUNT(*) FROM DM_Ventes_CDC.meta.MappingColonnes)     AS NbMappings
UNION ALL
SELECT N'DM_Ventes_CT',
       (SELECT COUNT(*) FROM DM_Ventes_CT.meta.DictionnaireDonnees),
       (SELECT COUNT(*) FROM DM_Ventes_CT.meta.MappingColonnes);

SELECT TableCible, ColonneCible, TablesSources, ColonnesSources, RegleTransformation
FROM   DM_Ventes_CDC.meta.MappingColonnes
ORDER BY IdMapping;

SELECT TOP (10) TableCible, ColonneCible, Definition
FROM   DM_Ventes_CDC.meta.DictionnaireDonnees
WHERE  TableCible = N'dm.DimProduit';

/* Proprietes etendues effectivement posees sur dm.DimProduit */
USE DM_Ventes_CDC;
SELECT objname AS Colonne, value AS Description
FROM   sys.fn_listextendedproperty(N'MS_Description', N'SCHEMA', N'dm', N'TABLE', N'DimProduit', N'COLUMN', DEFAULT);
GO
