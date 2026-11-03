/* =====================================================================
   06a_changements_partie1.sql  —  Changements dans la source, partie 1
   (fourni par l'enseignant — NE PAS MODIFIER)

   À exécuter dans la base AdventureWorks (OLTP), APRÈS :
     - le chargement initial des deux data marts (ETL et ELT) ;
     - l'activation de CDC et de Change Tracking sur les trois tables
       Production.Product, Sales.SalesOrderHeader et Sales.SalesOrderDetail ;
     - l'initialisation de meta.EtatCDC et meta.EtatCT.

   Changements appliqués (une seule transaction) :
     1. Prix catalogue +10 % pour 3 produits de la catégorie Bikes   (SCD 2)
     2. Correction du nom d'un produit                              (SCD 1)
     3. Changement de sous-catégorie d'un produit : Jerseys -> Vests (SCD 2)
     4. 5 nouvelles commandes de 5 lignes chacune
     5. Correction de la quantité d'une ligne de commande existante
     6. Suppression d'une ligne de commande existante

   Remarque : les déclencheurs d'AdventureWorks recalculent le sous-total
   des en-têtes de commande. CDC et Change Tracking verront donc aussi des
   mises à jour dans Sales.SalesOrderHeader : c'est normal.

   Le journal des changements est écrit dans dbo.JournalChangements.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

/* ---------- 0. Vérifications préalables ---------- */
IF OBJECT_ID(N'Sales.SalesOrderHeader', N'U') IS NULL
    THROW 50000, N'Exécutez ce script dans la base AdventureWorks (OLTP).', 1;

IF EXISTS (SELECT 1
           FROM (VALUES (N'Production.Product'),
                        (N'Sales.SalesOrderHeader'),
                        (N'Sales.SalesOrderDetail')) AS t(nom)
           LEFT JOIN sys.tables AS st
                  ON st.object_id = OBJECT_ID(t.nom)
           LEFT JOIN sys.change_tracking_tables AS ct
                  ON ct.object_id = OBJECT_ID(t.nom)
           WHERE ISNULL(st.is_tracked_by_cdc, 0) = 0
              OR ct.object_id IS NULL)
    THROW 50001, N'CDC et Change Tracking doivent être activés sur les trois tables AVANT ce script.', 1;

IF OBJECT_ID(N'dbo.JournalChangements', N'U') IS NULL
    CREATE TABLE dbo.JournalChangements (
        Partie          INT           NOT NULL,
        NumChangement   INT           NOT NULL,
        TypeChangement  NVARCHAR(40)  NOT NULL,
        TableSource     NVARCHAR(60)  NOT NULL,
        Cle             NVARCHAR(30)  NOT NULL,
        AncienneValeur  NVARCHAR(100) NULL,
        NouvelleValeur  NVARCHAR(100) NULL,
        DateHeure       DATETIME2(3)  NOT NULL DEFAULT SYSDATETIME()
    );

IF EXISTS (SELECT 1 FROM dbo.JournalChangements WHERE Partie = 1)
    THROW 50002, N'La partie 1 a déjà été exécutée.', 1;

BEGIN TRANSACTION;

DECLARE @maintenant      DATETIME = GETDATE();
DECLARE @derniereAncienne INT     = (SELECT MAX(SalesOrderID) FROM Sales.SalesOrderHeader);

DECLARE @scJerseys INT = (SELECT ProductSubcategoryID FROM Production.ProductSubcategory WHERE Name = N'Jerseys');
DECLARE @scVests   INT = (SELECT ProductSubcategoryID FROM Production.ProductSubcategory WHERE Name = N'Vests');

IF @scJerseys IS NULL OR @scVests IS NULL
    THROW 50003, N'Sous-catégories Jerseys ou Vests introuvables.', 1;

/* Produits vendables : prix > 0, présents dans l'offre « No Discount » (SpecialOfferID = 1),
   déjà vendus et encore commercialisés */
DECLARE @vendables TABLE (ProductID INT PRIMARY KEY);

INSERT INTO @vendables (ProductID)
SELECT p.ProductID
FROM   Production.Product AS p
WHERE  p.ListPrice > 0
  AND  p.SellEndDate IS NULL
  AND  EXISTS (SELECT 1 FROM Sales.SpecialOfferProduct AS sop
               WHERE sop.ProductID = p.ProductID AND sop.SpecialOfferID = 1)
  AND  EXISTS (SELECT 1 FROM Sales.SalesOrderDetail AS d
               WHERE d.ProductID = p.ProductID);

/* ---------- 1. Prix +10 % pour 3 produits Bikes (SCD 2) ---------- */
DECLARE @prix TABLE (ProductID INT PRIMARY KEY, AncienPrix MONEY);

INSERT INTO @prix (ProductID, AncienPrix)
SELECT TOP (3) p.ProductID, p.ListPrice
FROM   Production.Product AS p
JOIN   @vendables AS v ON v.ProductID = p.ProductID
JOIN   Production.ProductSubcategory AS sc ON sc.ProductSubcategoryID = p.ProductSubcategoryID
JOIN   Production.ProductCategory    AS c  ON c.ProductCategoryID     = sc.ProductCategoryID
WHERE  c.Name = N'Bikes'
ORDER BY p.ProductID;

IF (SELECT COUNT(*) FROM @prix) <> 3
    THROW 50004, N'Changement 1 : moins de 3 produits Bikes trouvés.', 1;

UPDATE p
SET    p.ListPrice    = ROUND(p.ListPrice * 1.10, 2),
       p.ModifiedDate = @maintenant
FROM   Production.Product AS p
JOIN   @prix AS x ON x.ProductID = p.ProductID;

INSERT INTO dbo.JournalChangements (Partie, NumChangement, TypeChangement, TableSource, Cle, AncienneValeur, NouvelleValeur)
SELECT 1, 1, N'Prix (SCD 2)', N'Production.Product', CONVERT(NVARCHAR(30), p.ProductID),
       CONVERT(NVARCHAR(30), x.AncienPrix), CONVERT(NVARCHAR(30), p.ListPrice)
FROM   Production.Product AS p
JOIN   @prix AS x ON x.ProductID = p.ProductID;

/* ---------- 2. Correction du nom d'un produit (SCD 1) ---------- */
DECLARE @prodNom INT, @ancienNom NVARCHAR(50);

SELECT TOP (1) @prodNom = p.ProductID, @ancienNom = p.Name
FROM   Production.Product AS p
JOIN   @vendables AS v ON v.ProductID = p.ProductID
JOIN   Production.ProductSubcategory AS sc ON sc.ProductSubcategoryID = p.ProductSubcategoryID
JOIN   Production.ProductCategory    AS c  ON c.ProductCategoryID     = sc.ProductCategoryID
WHERE  c.Name = N'Accessories'
  AND  LEN(p.Name) <= 38
ORDER BY p.ProductID;

IF @prodNom IS NULL
    THROW 50005, N'Changement 2 : aucun produit Accessories trouvé.', 1;

UPDATE Production.Product
SET    Name         = CONCAT(Name, N' (corrigé)'),
       ModifiedDate = @maintenant
WHERE  ProductID = @prodNom;

INSERT INTO dbo.JournalChangements (Partie, NumChangement, TypeChangement, TableSource, Cle, AncienneValeur, NouvelleValeur)
SELECT 1, 2, N'Nom (SCD 1)', N'Production.Product', CONVERT(NVARCHAR(30), @prodNom),
       @ancienNom, Name
FROM   Production.Product WHERE ProductID = @prodNom;

/* ---------- 3. Changement de sous-catégorie : Jerseys -> Vests (SCD 2) ---------- */
DECLARE @prodSousCat INT;

SELECT TOP (1) @prodSousCat = p.ProductID
FROM   Production.Product AS p
JOIN   @vendables AS v ON v.ProductID = p.ProductID
WHERE  p.ProductSubcategoryID = @scJerseys
ORDER BY p.ProductID;

IF @prodSousCat IS NULL
    THROW 50006, N'Changement 3 : aucun produit Jerseys trouvé.', 1;

UPDATE Production.Product
SET    ProductSubcategoryID = @scVests,
       ModifiedDate         = @maintenant
WHERE  ProductID = @prodSousCat;

INSERT INTO dbo.JournalChangements (Partie, NumChangement, TypeChangement, TableSource, Cle, AncienneValeur, NouvelleValeur)
VALUES (1, 3, N'Sous-catégorie (SCD 2)', N'Production.Product', CONVERT(NVARCHAR(30), @prodSousCat),
        N'Jerseys', N'Vests');

/* ---------- 4. 5 nouvelles commandes de 5 lignes ---------- */
DECLARE @commandes TABLE (SalesOrderID INT PRIMARY KEY);

INSERT INTO Sales.SalesOrderHeader
       (RevisionNumber, OrderDate, DueDate, Status, OnlineOrderFlag,
        CustomerID, SalesPersonID, TerritoryID, BillToAddressID, ShipToAddressID,
        ShipMethodID, SubTotal, TaxAmt, Freight)
OUTPUT inserted.SalesOrderID INTO @commandes (SalesOrderID)
SELECT TOP (5) 0, @maintenant, DATEADD(DAY, 12, @maintenant), 1, h.OnlineOrderFlag,
       h.CustomerID, h.SalesPersonID, h.TerritoryID, h.BillToAddressID, h.ShipToAddressID,
       h.ShipMethodID, 0, 0, 0
FROM   Sales.SalesOrderHeader AS h
WHERE  h.OnlineOrderFlag = 0
ORDER BY h.SalesOrderID;

INSERT INTO Sales.SalesOrderDetail (SalesOrderID, OrderQty, ProductID, SpecialOfferID, UnitPrice, UnitPriceDiscount)
SELECT c.SalesOrderID, 2, p.ProductID, 1, p.ListPrice, 0
FROM   @commandes AS c
CROSS JOIN (SELECT ProductID FROM @prix
            UNION ALL SELECT @prodNom
            UNION ALL SELECT @prodSousCat) AS x
JOIN   Production.Product AS p ON p.ProductID = x.ProductID;

INSERT INTO dbo.JournalChangements (Partie, NumChangement, TypeChangement, TableSource, Cle, AncienneValeur, NouvelleValeur)
SELECT 1, 4, N'Nouvelle commande', N'Sales.SalesOrderHeader', CONVERT(NVARCHAR(30), SalesOrderID),
       NULL, N'5 lignes'
FROM   @commandes;

/* ---------- 5. Correction de quantité sur une ligne existante ---------- */
DECLARE @ligneQte INT, @ancienneQte SMALLINT;

SELECT TOP (1) @ligneQte = d.SalesOrderDetailID, @ancienneQte = d.OrderQty
FROM   Sales.SalesOrderDetail AS d
WHERE  d.SalesOrderID <= @derniereAncienne
  AND  (SELECT COUNT(*) FROM Sales.SalesOrderDetail AS d2 WHERE d2.SalesOrderID = d.SalesOrderID) >= 2
ORDER BY d.SalesOrderDetailID;

UPDATE Sales.SalesOrderDetail
SET    OrderQty     = OrderQty + 1,
       ModifiedDate = @maintenant
WHERE  SalesOrderDetailID = @ligneQte;

INSERT INTO dbo.JournalChangements (Partie, NumChangement, TypeChangement, TableSource, Cle, AncienneValeur, NouvelleValeur)
VALUES (1, 5, N'Correction de quantité', N'Sales.SalesOrderDetail', CONVERT(NVARCHAR(30), @ligneQte),
        CONVERT(NVARCHAR(30), @ancienneQte), CONVERT(NVARCHAR(30), @ancienneQte + 1));

/* ---------- 6. Suppression d'une ligne existante ---------- */
DECLARE @ligneSupp INT, @commandeSupp INT;

SELECT TOP (1) @ligneSupp = d.SalesOrderDetailID, @commandeSupp = d.SalesOrderID
FROM   Sales.SalesOrderDetail AS d
WHERE  d.SalesOrderID <= @derniereAncienne
  AND  d.SalesOrderDetailID <> @ligneQte
  AND  (SELECT COUNT(*) FROM Sales.SalesOrderDetail AS d2 WHERE d2.SalesOrderID = d.SalesOrderID) >= 2
ORDER BY d.SalesOrderDetailID DESC;

DELETE FROM Sales.SalesOrderDetail
WHERE  SalesOrderDetailID = @ligneSupp;

INSERT INTO dbo.JournalChangements (Partie, NumChangement, TypeChangement, TableSource, Cle, AncienneValeur, NouvelleValeur)
VALUES (1, 6, N'Suppression de ligne', N'Sales.SalesOrderDetail', CONVERT(NVARCHAR(30), @ligneSupp),
        CONCAT(N'commande ', @commandeSupp), NULL);

COMMIT TRANSACTION;

SELECT Partie, NumChangement, TypeChangement, TableSource, Cle, AncienneValeur, NouvelleValeur, DateHeure
FROM   dbo.JournalChangements
WHERE  Partie = 1
ORDER BY NumChangement, Cle;
