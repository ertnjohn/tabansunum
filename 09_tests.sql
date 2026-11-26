-- 09_tests.sql
-- Etape 6 : Tests de validation des donnees (Data Integrity Tests)

-- TEST 1 : dm.FaitVente correspond exactement a la source (lignes manquantes, quantite ou prix unitaire differents)
-- Resultat attendu : 0 ligne
SELECT f.NumCommande, f.NumLigne, f.Quantite, f.PrixUnitaire, f.Montant, d.LineTotal
FROM dm.FaitVente f
FULL OUTER JOIN AdventureWorks2022.Sales.SalesOrderDetail d
  ON f.NumCommande = d.SalesOrderID
 AND f.NumLigne    = d.SalesOrderDetailID
WHERE f.NumCommande IS NULL
   OR d.SalesOrderID IS NULL
   OR f.Quantite <> d.OrderQty
   OR ABS(CAST(f.PrixUnitaire AS DECIMAL(18,4)) - CAST(d.UnitPrice AS DECIMAL(18,4))) > 0.01;

-- TEST 2a : Chaque produit a exactement UNE SEULE version courante (EstCourant = 1)
-- Resultat attendu : 0 ligne
SELECT ProductID, SUM(CAST(EstCourant AS INT)) AS NbVersionsActives
FROM dm.DimProduit
GROUP BY ProductID
HAVING SUM(CAST(EstCourant AS INT)) <> 1;

-- TEST 2b : Les versions d'un meme produit ne se chevauchent pas dans le temps
-- Resultat attendu : 0 ligne
SELECT p1.ProductID, p1.CleProduit AS Cle1, p2.CleProduit AS Cle2
FROM dm.DimProduit p1
JOIN dm.DimProduit p2 ON p1.ProductID = p2.ProductID AND p1.CleProduit <> p2.CleProduit
WHERE p1.DateDebut < ISNULL(p2.DateFin, '2099-12-31')
  AND ISNULL(p1.DateFin, '2099-12-31') > p2.DateDebut;

-- TEST 3 : Chaque ligne de fait est rattachee a la version de produit valide a la date de sa commande
-- Resultat attendu : 0 ligne
SELECT f.NumCommande, f.NumLigne, d.[Date] AS DateCommande, p.DateDebut, p.DateFin
FROM dm.FaitVente f
JOIN dm.DimProduit p ON f.CleProduit = p.CleProduit
JOIN dm.DimDate d ON f.CleDate = d.CleDate
WHERE d.[Date] < CAST(p.DateDebut AS DATE)
   OR d.[Date] > ISNULL(CAST(p.DateFin AS DATE), '2099-12-31');

-- TEST 4 : Idempotence (la derniere execution sans changement ne modifie aucune ligne)
-- Resultat attendu : 0 ligne
SELECT TOP 1 IdExecution, Methode, LignesInserees, LignesMisesAJour, LignesSupprimees
FROM (
    SELECT TOP 1 * FROM meta.JournalChargement ORDER BY IdExecution DESC
) AS DerniereExec
WHERE LignesInserees <> 0 OR LignesMisesAJour <> 0 OR LignesSupprimees <> 0;

-- TEST 5 : Coherence des volumes entre meta.JournalChargement, dm.FaitVente et dbo.JournalChangements
-- Resultat attendu : Egalite verifiee (EcartFait = 0)
SELECT
    (SELECT COUNT(*) FROM dm.FaitVente)                                         AS NbFaitVente,
    (SELECT COUNT(*) FROM AdventureWorks2022.Sales.SalesOrderDetail)            AS NbSourceDetail,
    (SELECT COUNT(*) FROM dm.FaitVente)
      - (SELECT COUNT(*) FROM AdventureWorks2022.Sales.SalesOrderDetail)        AS EcartFait,
    (SELECT COUNT(*) FROM AdventureWorks2022.dbo.JournalChangements)            AS NbJournalSource,
    (SELECT SUM(LignesInserees + LignesMisesAJour + LignesSupprimees)
     FROM meta.JournalChargement WHERE Methode IN ('CDC', 'CT'))                AS TotalOpsIncrementales;