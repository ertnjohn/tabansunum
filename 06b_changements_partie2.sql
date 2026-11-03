/* =====================================================================
   06b_changements_partie2.sql  —  Changements dans la source, partie 2
   (fourni par l'enseignant — NE PAS MODIFIER)

   À exécuter dans la base AdventureWorks (OLTP), APRÈS :
     - la partie 1 ;
     - les deux chargements incrémentaux de la partie 1 (CDC et CT).

   Changements appliqués, en QUATRE transactions successives :
     7. Prix du produit P : +5 %                    (transaction A)
     8. Une commande de P au prix intermédiaire      (transaction B)
     9. Prix du produit P : encore +5 %              (transaction C)
    10. Nouveau produit N et une commande de N       (transaction D)

   P est le premier produit dont le prix a changé dans la partie 1.

   Point clé du devoir : entre deux chargements, le prix de P change
   DEUX FOIS, et une vente a lieu au prix intermédiaire.
     - cdc.fn_cdc_get_all_changes_... voit les deux changements ;
     - Change Tracking ne voit que l'état final de la ligne.
   Comparez la version de produit à laquelle la vente du changement 8
   est rattachée dans chacun de vos deux data marts.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

/* ---------- 0. Vérifications préalables ---------- */
IF OBJECT_ID(N'dbo.JournalChangements', N'U') IS NULL
   OR NOT EXISTS (SELECT 1 FROM dbo.JournalChangements WHERE Partie = 1)
    THROW 50010, N'Exécutez d''abord la partie 1 (06a_changements_partie1.sql).', 1;

IF EXISTS (SELECT 1 FROM dbo.JournalChangements WHERE Partie = 2)
    THROW 50011, N'La partie 2 a déjà été exécutée.', 1;

DECLARE @P INT = (SELECT MIN(CAST(Cle AS INT))
                  FROM   dbo.JournalChangements
                  WHERE  Partie = 1 AND NumChangement = 1);

/* Modèle d'en-tête de commande : la première commande revendeur */
DECLARE @modele INT = (SELECT MIN(SalesOrderID) FROM Sales.SalesOrderHeader WHERE OnlineOrderFlag = 0);

DECLARE @ancienPrix MONEY, @commande INT;
DECLARE @cmd TABLE (SalesOrderID INT);

/* ---------- 7. Transaction A : prix de P +5 % ---------- */
BEGIN TRANSACTION;

SET @ancienPrix = (SELECT ListPrice FROM Production.Product WHERE ProductID = @P);

UPDATE Production.Product
SET    ListPrice = ROUND(ListPrice * 1.05, 2), ModifiedDate = GETDATE()
WHERE  ProductID = @P;

INSERT INTO dbo.JournalChangements (Partie, NumChangement, TypeChangement, TableSource, Cle, AncienneValeur, NouvelleValeur)
SELECT 2, 7, N'Prix, 1er changement (SCD 2)', N'Production.Product', CONVERT(NVARCHAR(30), @P),
       CONVERT(NVARCHAR(30), @ancienPrix), CONVERT(NVARCHAR(30), ListPrice)
FROM   Production.Product WHERE ProductID = @P;

COMMIT TRANSACTION;

WAITFOR DELAY '00:00:03';

/* ---------- 8. Transaction B : une commande de P au prix intermédiaire ---------- */
BEGIN TRANSACTION;

INSERT INTO Sales.SalesOrderHeader
       (RevisionNumber, OrderDate, DueDate, Status, OnlineOrderFlag,
        CustomerID, SalesPersonID, TerritoryID, BillToAddressID, ShipToAddressID,
        ShipMethodID, SubTotal, TaxAmt, Freight)
OUTPUT inserted.SalesOrderID INTO @cmd (SalesOrderID)
SELECT 0, GETDATE(), DATEADD(DAY, 12, GETDATE()), 1, h.OnlineOrderFlag,
       h.CustomerID, h.SalesPersonID, h.TerritoryID, h.BillToAddressID, h.ShipToAddressID,
       h.ShipMethodID, 0, 0, 0
FROM   Sales.SalesOrderHeader AS h
WHERE  h.SalesOrderID = @modele;

SET @commande = (SELECT MAX(SalesOrderID) FROM @cmd);

INSERT INTO Sales.SalesOrderDetail (SalesOrderID, OrderQty, ProductID, SpecialOfferID, UnitPrice, UnitPriceDiscount)
SELECT @commande, 3, ProductID, 1, ListPrice, 0
FROM   Production.Product WHERE ProductID = @P;

INSERT INTO dbo.JournalChangements (Partie, NumChangement, TypeChangement, TableSource, Cle, AncienneValeur, NouvelleValeur)
SELECT 2, 8, N'Commande au prix intermédiaire', N'Sales.SalesOrderHeader', CONVERT(NVARCHAR(30), @commande),
       NULL, CONCAT(N'produit ', @P, N', prix unitaire ', ListPrice)
FROM   Production.Product WHERE ProductID = @P;

COMMIT TRANSACTION;

WAITFOR DELAY '00:00:03';

/* ---------- 9. Transaction C : prix de P encore +5 % ---------- */
BEGIN TRANSACTION;

SET @ancienPrix = (SELECT ListPrice FROM Production.Product WHERE ProductID = @P);

UPDATE Production.Product
SET    ListPrice = ROUND(ListPrice * 1.05, 2), ModifiedDate = GETDATE()
WHERE  ProductID = @P;

INSERT INTO dbo.JournalChangements (Partie, NumChangement, TypeChangement, TableSource, Cle, AncienneValeur, NouvelleValeur)
SELECT 2, 9, N'Prix, 2e changement (SCD 2)', N'Production.Product', CONVERT(NVARCHAR(30), @P),
       CONVERT(NVARCHAR(30), @ancienPrix), CONVERT(NVARCHAR(30), ListPrice)
FROM   Production.Product WHERE ProductID = @P;

COMMIT TRANSACTION;

WAITFOR DELAY '00:00:03';

/* ---------- 10. Transaction D : nouveau produit N et une commande de N ---------- */
BEGIN TRANSACTION;

DECLARE @nouveau TABLE (ProductID INT);
DECLARE @N INT;

/* Le nouveau produit copie les caractéristiques de P */
INSERT INTO Production.Product
       (Name, ProductNumber, MakeFlag, FinishedGoodsFlag, Color, SafetyStockLevel,
        ReorderPoint, StandardCost, ListPrice, Size, SizeUnitMeasureCode,
        WeightUnitMeasureCode, Weight, DaysToManufacture, ProductLine, Class, Style,
        ProductSubcategoryID, ProductModelID, SellStartDate)
OUTPUT inserted.ProductID INTO @nouveau (ProductID)
SELECT N'Mountain-500 Edition 2026', N'BK-M2026-01', MakeFlag, FinishedGoodsFlag, Color, SafetyStockLevel,
       ReorderPoint, StandardCost, ListPrice, Size, SizeUnitMeasureCode,
       WeightUnitMeasureCode, Weight, DaysToManufacture, ProductLine, Class, Style,
       ProductSubcategoryID, ProductModelID, GETDATE()
FROM   Production.Product
WHERE  ProductID = @P;

SET @N = (SELECT ProductID FROM @nouveau);

/* Le produit doit appartenir à l'offre « No Discount » pour pouvoir être vendu */
INSERT INTO Sales.SpecialOfferProduct (SpecialOfferID, ProductID)
VALUES (1, @N);

DELETE FROM @cmd;

INSERT INTO Sales.SalesOrderHeader
       (RevisionNumber, OrderDate, DueDate, Status, OnlineOrderFlag,
        CustomerID, SalesPersonID, TerritoryID, BillToAddressID, ShipToAddressID,
        ShipMethodID, SubTotal, TaxAmt, Freight)
OUTPUT inserted.SalesOrderID INTO @cmd (SalesOrderID)
SELECT 0, GETDATE(), DATEADD(DAY, 12, GETDATE()), 1, h.OnlineOrderFlag,
       h.CustomerID, h.SalesPersonID, h.TerritoryID, h.BillToAddressID, h.ShipToAddressID,
       h.ShipMethodID, 0, 0, 0
FROM   Sales.SalesOrderHeader AS h
WHERE  h.SalesOrderID = @modele;

SET @commande = (SELECT MAX(SalesOrderID) FROM @cmd);

INSERT INTO Sales.SalesOrderDetail (SalesOrderID, OrderQty, ProductID, SpecialOfferID, UnitPrice, UnitPriceDiscount)
SELECT @commande, 1, ProductID, 1, ListPrice, 0
FROM   Production.Product WHERE ProductID = @N;

INSERT INTO dbo.JournalChangements (Partie, NumChangement, TypeChangement, TableSource, Cle, AncienneValeur, NouvelleValeur)
VALUES (2, 10, N'Nouveau produit', N'Production.Product', CONVERT(NVARCHAR(30), @N),
        NULL, N'Mountain-500 Edition 2026'),
       (2, 10, N'Commande du nouveau produit', N'Sales.SalesOrderHeader', CONVERT(NVARCHAR(30), @commande),
        NULL, CONCAT(N'produit ', @N));

COMMIT TRANSACTION;

SELECT Partie, NumChangement, TypeChangement, TableSource, Cle, AncienneValeur, NouvelleValeur, DateHeure
FROM   dbo.JournalChangements
WHERE  Partie = 2
ORDER BY NumChangement, Cle;
